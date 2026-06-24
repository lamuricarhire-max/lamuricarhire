# Investor Payout Calculation Engine

## Goal

One engine evaluates **any** payout formula an admin configures, without
code changes per investor. The formula's *shape* is fixed (5 types), but its
*parameters* are data (`payout_formula_template.formula_params` /
`investor_contract.formula_override_params`).

## Step 0 — Period resolution

For a given `investor_contract`, the engine first determines the period to
calculate:

```
period_start, period_end = next un-paid period for this contract
    based on contract.payout_frequency (WEEKLY | MONTHLY)
    and contract.payout_day_of_period
```

- WEEKLY: periods run Mon–Sun (or admin-configured week start); 
  `payout_day_of_period` = which weekday the payout is *disbursed* (e.g. 5 = Friday,
  paying out the week that just ended).
- MONTHLY: periods run calendar-month; `payout_day_of_period` = day-of-month
  disbursed (e.g. 3rd of the following month).

The engine never recalculates a period that already has a row in
`investor_payout_run` with status `PAID` — it's a closed book. A
`CALCULATED` (not yet approved/paid) run *can* be recalculated and overwritten
if revenue data changes before approval.

## Step 1 — Gather revenue & cost data for the period

```sql
-- Gross revenue: all invoice line items for bookings of this vehicle
-- where the invoice's coverage period overlaps [period_start, period_end]
SELECT COALESCE(SUM(ili.line_total), 0) AS gross_revenue
FROM invoice_line_item ili
JOIN invoice i ON i.id = ili.invoice_id
JOIN booking b ON b.id = i.booking_id
WHERE b.vehicle_id = :vehicle_id
  AND i.status IN ('PAID','PARTIAL','SENT')   -- recognize on invoice, not on cash receipt (accrual)
  AND i.issue_date BETWEEN :period_start AND :period_end;

-- Deductions: maintenance billed to investor
SELECT COALESCE(SUM(cost_amount), 0) AS maintenance_deduction
FROM maintenance_record
WHERE vehicle_id = :vehicle_id AND billed_to = 'INVESTOR'
  AND completed_date BETWEEN :period_start AND :period_end;

-- Deductions: insurance premium billed to investor (pro-rated if policy
-- period doesn't align exactly with payout period — see note below)
SELECT COALESCE(SUM(premium_amount), 0) AS insurance_deduction
FROM insurance_policy
WHERE vehicle_id = :vehicle_id AND billed_to = 'INVESTOR'
  AND start_date <= :period_end AND end_date >= :period_start;
```

> **Pro-ration note:** if an annual insurance premium is billed to the
> investor, the engine pro-rates it across payout periods rather than
> deducting the full premium in one period:
> `prorated = premium_amount * (days_in_period_overlap / total_policy_days)`.
> This is itself a `system_setting` toggle (`INSURANCE_PRORATION_ENABLED`)
> in case an admin prefers to deduct it as a lump sum on the invoice date.

`base` revenue used in formulas is either:
- `GROSS` = revenue above, untouched, or
- `NET` = `GROSS - maintenance_deduction - insurance_deduction` (only the
  deductions enabled on the contract: `deduct_maintenance`, `deduct_insurance`)

## Step 2 — Apply the formula

Pseudocode for the generic evaluator (`PayoutFormulaEvaluator.evaluate()`):

```typescript
interface PayoutContext {
  grossRevenue: number;
  maintenanceDeduction: number;
  insuranceDeduction: number;
  contract: InvestorContract;
}

function computeNetBase(ctx: PayoutContext, base: 'GROSS' | 'NET'): number {
  if (base === 'GROSS') return ctx.grossRevenue;
  let net = ctx.grossRevenue;
  if (ctx.contract.deduct_maintenance) net -= ctx.maintenanceDeduction;
  if (ctx.contract.deduct_insurance) net -= ctx.insuranceDeduction;
  return Math.max(net, 0);
}

function evaluateFormula(formulaType: string, params: any, ctx: PayoutContext, periodDays: number, bookedDays: number): number {
  switch (formulaType) {

    case 'FIXED_PERIODIC':
      // Owner gets a flat amount regardless of bookings/revenue.
      return params.amount;

    case 'REVENUE_SHARE': {
      const base = computeNetBase(ctx, params.base);
      return base * (params.investor_share_percent / 100);
    }

    case 'HYBRID_MIN_GUARANTEE': {
      const base = computeNetBase(ctx, params.base);
      const shareAmount = base * (params.investor_share_percent / 100);
      return Math.max(params.guaranteed_amount, shareAmount);
    }

    case 'TIERED_REVENUE_SHARE': {
      // Progressive bands, like a tax bracket: each tier's percent applies
      // only to the slice of `base` that falls within that tier.
      const base = computeNetBase(ctx, params.base);
      let remaining = base;
      let payout = 0;
      let lowerBound = 0;
      for (const tier of params.tiers) {
        const upper = tier.upto === null ? Infinity : tier.upto;
        const sliceWidth = Math.min(remaining, upper - lowerBound);
        if (sliceWidth <= 0) break;
        payout += sliceWidth * (tier.percent / 100);
        remaining -= sliceWidth;
        lowerBound = upper;
        if (remaining <= 0) break;
      }
      return payout;
    }

    case 'PER_BOOKING_FEE':
      // bookedDays = count of days the vehicle was actually out on a
      // booking during the period (from vehicle_inspection / booking dates)
      return (params.fee_per_day * bookedDays) + (params.fee_per_booking * countBookingsInPeriod());

    default:
      throw new Error(`Unknown formula_type: ${formulaType}`);
  }
}
```

`investor_contract.formula_override_params`, if present, is deep-merged over
the template's `formula_params` before evaluation — so most contracts just
reference a shared template, but any contract can deviate (e.g. same
"Standard 70/30" template but this one investor negotiated 75%).

## Step 3 — Management fee & tax

```typescript
const baseForFee = computeNetBase(ctx, 'NET'); // management fee always off net, regardless of formula base
const managementFeeAmount = contract.deduct_commission
  ? baseForFee * (contract.management_fee_percent / 100)
  : 0;

let payoutBeforeTax = formulaResult - managementFeeAmount;

const withholdingRule = TaxEngine.resolve({
  appliesTo: 'INVESTOR_PAYOUT',
  branchId: contract.branch_id,
  date: periodEnd,
});
const withholdingTaxAmount = withholdingRule
  ? payoutBeforeTax * (withholdingRule.rate_percent / 100)
  : 0;

const netPayoutAmount = payoutBeforeTax - withholdingTaxAmount;
```

> Management fee can be modeled two ways depending on how the admin sets up
> the contract: (a) as a deduction here (`management_fee_percent` on top of a
> revenue-share formula), or (b) baked directly into a lower
> `investor_share_percent` in the formula itself. Both are supported; the
> system doesn't force one approach, but the UI should warn if both are set
> non-zero on a `REVENUE_SHARE` contract to avoid double-counting confusion.

## Step 4 — Persist with full audit trail

Every run writes a `calculation_trace` JSONB blob — this is what makes the
investor statement defensible and disputes resolvable without re-deriving
the math from scratch:

```json
{
  "formula_type": "HYBRID_MIN_GUARANTEE",
  "formula_params": { "guaranteed_amount": 25000, "investor_share_percent": 50, "base": "NET" },
  "period": { "start": "2026-05-01", "end": "2026-05-31" },
  "inputs": {
    "gross_revenue": 78000,
    "maintenance_deduction": 6000,
    "insurance_deduction": 2500,
    "net_base": 69500
  },
  "calculation_steps": [
    "net_base = 78000 - 6000 - 2500 = 69500",
    "share_amount = 69500 * 50% = 34750",
    "guaranteed_amount = 25000",
    "formula_result = max(25000, 34750) = 34750",
    "management_fee = 69500 * 0% = 0",
    "payout_before_tax = 34750",
    "withholding_tax = 34750 * 5% = 1737.50",
    "net_payout = 34750 - 1737.50 = 33012.50"
  ],
  "engine_version": "1.2.0"
}
```

This is stored verbatim on `investor_payout_run.calculation_trace` and is
what the **investor statement document** renders in a "How this was
calculated" section — transparency reduces payout disputes significantly in
practice.

## Step 5 — Approval & disbursement workflow

```
CALCULATED ──(if PAYOUT_APPROVAL_REQUIRED setting=true)──> awaiting Branch Manager / Accountant approval
   │                                                              │
   │ (if approval not required)                                  ▼
   └──────────────────────────────────────────────────────────► APPROVED
                                                                    │
                                                  Disbursement job picks it up
                                                                    │
                                          ┌─────────────────────────┴───────────────┐
                                          ▼                                         ▼
                              preferred_payout_method                    preferred_payout_method
                                = MPESA_B2C                                = BANK_TRANSFER
                                          │                                         │
                              M-Pesa B2C API call                        Exported to bank batch file
                              (see 05-mpesa-integration-spec.md)          (CSV/EFT format for manual upload)
                                          │                                         │
                                          ▼                                         ▼
                                status = PAID, payment_reference set, SMS + statement email sent
```

If the M-Pesa B2C call fails (insufficient float, wrong number, network
timeout), `status` moves to `FAILED` and a `staff_task` is auto-created for
the Accountant (see automation rule `PAYOUT_DISBURSEMENT_FAILED`) — it never
silently disappears.

## Batch run job (NestJS scheduler)

```typescript
@Injectable()
export class PayoutRunService {
  constructor(
    private readonly contractRepo: Repository<InvestorContract>,
    private readonly evaluator: PayoutFormulaEvaluator,
    private readonly taxEngine: TaxEngineService,
    private readonly revenueQuery: RevenueAggregationService,
  ) {}

  // Runs daily; only contracts whose payout_day_of_period matches "today"
  // (and whose current period has fully elapsed) actually produce a run.
  @Cron('0 2 * * *') // 02:00 server time daily
  async runDuePayouts(): Promise<void> {
    const dueContracts = await this.contractRepo.find({
      where: { status: 'ACTIVE' },
    });

    for (const contract of dueContracts) {
      if (!this.isPayoutDueToday(contract)) continue;

      const { periodStart, periodEnd } = this.resolvePeriod(contract);
      const alreadyRun = await this.payoutRunExists(contract.id, periodStart, periodEnd);
      if (alreadyRun) continue;

      const revenueData = await this.revenueQuery.getForVehiclePeriod(
        contract.vehicleId, periodStart, periodEnd,
      );

      const formulaParams = deepMerge(
        contract.payoutFormulaTemplate.formulaParams,
        contract.formulaOverrideParams ?? {},
      );

      const formulaResult = this.evaluator.evaluate(
        contract.payoutFormulaTemplate.formulaType,
        formulaParams,
        revenueData,
        contract,
      );

      const netBase = computeNetBase(revenueData, formulaParams.base, contract);
      const managementFee = contract.deductCommission
        ? netBase * (contract.managementFeePercent / 100) : 0;

      const payoutBeforeTax = formulaResult - managementFee;
      const withholdingRule = await this.taxEngine.resolve({
        appliesTo: 'INVESTOR_PAYOUT', branchId: contract.branchId, date: periodEnd,
      });
      const withholdingTax = withholdingRule
        ? payoutBeforeTax * (withholdingRule.ratePercent / 100) : 0;

      await this.createPayoutRun({
        contractId: contract.id,
        periodStart, periodEnd,
        grossRevenue: revenueData.grossRevenue,
        deductionsTotal: revenueData.maintenanceDeduction + revenueData.insuranceDeduction,
        managementFeeAmount: managementFee,
        withholdingTaxAmount: withholdingTax,
        netPayoutAmount: payoutBeforeTax - withholdingTax,
        calculationTrace: this.buildTrace(/* ... */),
        status: 'CALCULATED',
      });
      // → triggers automation_rule "PAYOUT_CALCULATED_NOTIFY" (SMS to investor: "your payout is being processed")
    }
  }
}
```

## Edge cases the engine must handle

| Case | Handling |
|---|---|
| Vehicle had zero bookings in the period | `gross_revenue = 0`. `FIXED_PERIODIC` and `HYBRID_MIN_GUARANTEE` still pay (guarantee/fixed amount); `REVENUE_SHARE` pays 0. Flagged in UI as "zero-revenue period" for manager visibility. |
| Contract starts/ends mid-period | Period is clipped to the overlap of `[contract_start_date, contract_end_date]` and `[period_start, period_end]`; `FIXED_PERIODIC` amount is pro-rated by days unless `system_setting PRORATE_FIXED_PAYOUTS = false`. |
| Vehicle had negative net (maintenance > revenue) | `computeNetBase` floors at 0 — investor never owes LAMURI money through the automated engine; a negative balance is carried forward as a note in `calculation_trace` and surfaced to the Branch Manager for manual reconciliation (e.g. against next period). |
| Two contracts overlap for same vehicle (data error) | Engine refuses to run and raises a `staff_task` — this must never silently pick one; it's a data integrity issue requiring human resolution. |
| Investor disputes a payout | `investor_payout_run.status = 'DISPUTED'` settable from the UI; freezes that run from being included in any "approve all" batch action until resolved. |
