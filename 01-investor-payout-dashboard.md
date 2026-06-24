# UI Spec — Investor Payout Dashboard

Audience: **Accountant / Branch Manager** (approval & disbursement) and
**Investor Portal** (read-only view of their own data, different screen
documented at the end).

## Screen 1: Payout Run Queue (Staff view)

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Investor Payouts                                    Branch: [Nairobi ▾] │
│  ┌────────────┬────────────┬────────────┬────────────┐                   │
│  │ Calculated │  Approved  │   Paid     │  Failed     │  ← status tabs   │
│  │    (12)    │    (3)     │   (148)    │   (1)       │                  │
│  └────────────┴────────────┴────────────┴────────────┘                   │
│                                                                            │
│  Period: [May 2026 ▾]    Search: [____________]   [Run Payouts Now ▶]    │
│                                                                            │
│  ┌──────────────────────────────────────────────────────────────────┐    │
│  │ ☐ │ Investor      │ Vehicle      │ Gross Rev │ Net Payout │ Status│   │
│  ├───┼───────────────┼──────────────┼───────────┼────────────┼───────┤   │
│  │ ☐ │ Jane Wanjiru  │ KDA 123A SUV │ 78,000    │ 33,012.50  │ CALC. │   │
│  │ ☐ │ Peter Otieno  │ KCB 456B Van │ 0         │ 25,000.00  │ CALC. │   │
│  │ ☐ │ Mary Achieng  │ KDF 789C Eco │ 102,500   │ 68,425.00  │ CALC. │   │
│  └──────────────────────────────────────────────────────────────────┘    │
│                                                                            │
│  [Approve Selected]   [Export to CSV]   12 rows · KES 412,300 total       │
└──────────────────────────────────────────────────────────────────────────┘
```

### Behavior
- **Status tabs** filter `investor_payout_run.status`. Badge counts update live.
- **"Run Payouts Now"** triggers an on-demand execution of `PayoutRunService.runDuePayouts()`
  scoped to the selected branch/period — for when an admin wants to force a
  recalculation before the nightly cron (e.g. month-end close).
- **Row click** opens the Payout Detail drawer (below).
- **Approve Selected** (bulk action) — only enabled when every selected row
  has `status = CALCULATED`. Disabled with tooltip "Select only calculated
  payouts" otherwise. Triggers a confirm dialog showing total KES amount
  before committing (since this is money leaving the business).
- Rows where `gross_revenue = 0` show a small ⚠ icon next to the amount —
  hovering shows "Zero bookings this period — payout is from guarantee/fixed
  formula" so the approver isn't surprised.
- A row with `status = FAILED` shows a red banner inline with "Retry
  Disbursement" and "View Error" actions instead of a checkbox.

## Screen 2: Payout Detail Drawer (slides in from right on row click)

```
┌─────────────────────────────────────────────┐
│  ✕  Payout Detail — Jane Wanjiru / KDA 123A  │
├─────────────────────────────────────────────┤
│  Period: 1 May 2026 – 31 May 2026            │
│  Contract: IC-NBO-0042 (Standard 70/30 Net)  │
│  Status: ● CALCULATED                        │
│                                               │
│  ── Calculation Breakdown ──────────────────  │
│  Gross Revenue                  KES 78,000.00│
│  – Maintenance (investor-billed) KES 6,000.00│
│  – Insurance (investor-billed)   KES 2,500.00│
│  ───────────────────────────────────────────  │
│  Net Base                       KES 69,500.00│
│  Investor Share (70%)           KES 48,650.00│
│  – Management Fee (0%)               KES 0.00│
│  – Withholding Tax (5%)          KES 2,432.50│
│  ═══════════════════════════════════════════  │
│  NET PAYOUT                     KES 46,217.50│
│                                               │
│  [▾ View step-by-step trace]                 │
│                                               │
│  Payout Method: M-Pesa B2C → 0712 345 678    │
│                                               │
│  [Edit Deductions]  [Approve]  [Dispute]     │
└─────────────────────────────────────────────┘
```

### Behavior
- "View step-by-step trace" expands `calculation_trace.calculation_steps`
  verbatim — this is the transparency mechanism for dispute resolution.
- **Edit Deductions** — only visible to Accountant/Branch Manager, only
  enabled while `status = CALCULATED`. Opens a small form to add a manual
  adjustment line (e.g. a damage cost the maintenance module hadn't
  captured yet); on save, re-runs the calculation and updates the trace
  with an `"adjustment"` entry, preserving the original auto-calculated
  values for audit (never silently overwritten).
- **Approve** — single-row equivalent of the bulk action; requires
  re-confirmation if `PAYOUT_APPROVAL_REQUIRED` setting is true.
- **Dispute** — sets `status = 'DISPUTED'`, requires a reason (free text),
  removes it from any future bulk-approve batch until resolved, and creates
  a `staff_task` for follow-up.

## Screen 3: New Investor Contract (form)

```
┌──────────────────────────────────────────────────────────────────────┐
│  New Investor Contract                                                │
├──────────────────────────────────────────────────────────────────────┤
│  Investor *        [Search/select existing — or + Add New Investor]   │
│  Vehicle *         [Search by reg no — only shows unattached vehicles] │
│  Branch *          [Nairobi ▾]                                        │
│                                                                         │
│  ── Payout Formula ──────────────────────────────────────────────────  │
│  Formula Template   [Standard 70/30 Net Revenue Share        ▾]       │
│                      ┌─────────────────────────────────────────────┐  │
│                      │ Preview: Investor receives 70% of net       │  │
│                      │ revenue (after maintenance/insurance         │  │
│                      │ deductions) per period.                      │  │
│                      └─────────────────────────────────────────────┘  │
│  ☐ Override this investor's parameters                                │
│      Investor Share %:  [70    ]   ← only editable if box checked     │
│                                                                         │
│  Payout Frequency    ◉ Monthly   ○ Weekly                             │
│  Payout Day          [1st of month ▾]                                 │
│                                                                         │
│  Deduct Maintenance  [✓]    Deduct Insurance  [✓]                     │
│  Management Fee %    [0    ]                                          │
│                                                                         │
│  Contract Start Date [01/07/2026]    Contract End Date [_________]     │
│                                                                         │
│  [Cancel]                                       [Save as Draft] [Activate] │
└──────────────────────────────────────────────────────────────────────┘
```

### Behavior & validation
- **Vehicle** dropdown only lists vehicles with `ownership_type = 'INVESTOR_OWNED'`
  and no currently `ACTIVE` contract (server-side check also enforced —
  prevents the "two overlapping contracts" data integrity issue called out
  in the engine doc's edge cases).
- **Formula Template** dropdown is populated from `payout_formula_template`
  — this is exactly where "admin customizable payout model" becomes real:
  an admin manages the template list itself in a separate settings screen
  (Screen 4 below); this form only *selects and optionally overrides*.
  Changing the template re-renders the live preview text by interpolating
  `formula_params` into a human-readable sentence per `formula_type`.
- **Override checkbox** reveals only the parameter fields relevant to the
  selected `formula_type` (dynamic form — e.g. selecting
  "Tiered Revenue Share" reveals a repeatable tier-rows editor instead of a
  single percent field).
- **Save as Draft** → `status = 'DRAFT'`, doesn't yet block the vehicle from
  other contracts. **Activate** → `status = 'ACTIVE'`, locks the vehicle.

## Screen 4: Payout Formula Templates (Admin Settings)

```
┌──────────────────────────────────────────────────────────────────────┐
│  Payout Formula Templates                          [+ New Template]   │
├──────────────────────────────────────────────────────────────────────┤
│  Name                         │ Type              │ Used by │ Active │
├────────────────────────────────┼───────────────────┼─────────┼────────┤
│  Standard 70/30 Net Share      │ Revenue Share     │   34    │  ✓     │
│  Fixed Monthly - KES 60,000    │ Fixed Periodic    │    8    │  ✓     │
│  Hybrid: 25k Guaranteed + 50%  │ Hybrid Min Guar.   │    5    │  ✓     │
│  Tiered Revenue Share           │ Tiered            │    2    │  ✓     │
│  Per-Booking Flat Fee           │ Per Booking       │    0    │  ✓     │
└──────────────────────────────────────────────────────────────────────┘
```

### "+ New Template" form (dynamic by formula_type)

```
┌──────────────────────────────────────────────────────────────┐
│  New Payout Formula Template                                  │
├──────────────────────────────────────────────────────────────┤
│  Name *            [_____________________________]            │
│  Formula Type *    [Select type ▾]                             │
│                       Fixed Periodic Amount                    │
│                       Revenue Share (% of revenue)              │
│                       Hybrid: Guarantee + Share                  │
│                       Tiered Revenue Share                       │
│                       Per-Booking / Per-Day Flat Fee              │
│                                                                  │
│  ── shown when "Revenue Share" selected ──                      │
│  Investor Share %    [____]                                     │
│  Base                ◉ Net (after deductions)  ○ Gross          │
│                                                                  │
│  ── shown when "Tiered Revenue Share" selected ──                │
│  Base                ◉ Net  ○ Gross                              │
│  Tiers:                                                          │
│    Up to [50,000  ] → [60]%        [✕ remove]                    │
│    Up to [100,000 ] → [70]%        [✕ remove]                    │
│    Above that       → [80]%        (last tier, no upper bound)   │
│    [+ Add Tier]                                                  │
│                                                                  │
│  Description (shown to staff when selecting) [____________]      │
│                                                                  │
│  [Cancel]                          [Save Template]                │
└──────────────────────────────────────────────────────────────┘
```

This form is the literal UI for "admin-customizable payout model" — the
formula type list itself is fixed (5 supported shapes from the engine), but
every numeric parameter, and how many tiers exist, is free-form admin input
stored straight into `payout_formula_template.formula_params` JSONB.

## Screen 5: Investor Portal (read-only, investor's own login)

```
┌──────────────────────────────────────────────────────────────────────┐
│  My Vehicles                                       Jane Wanjiru ▾     │
├──────────────────────────────────────────────────────────────────────┤
│  KDA 123A — Toyota RAV4 (SUV)               Status: ● Rented          │
│  Contract: Standard 70/30 Net Share · Monthly                         │
│                                                                         │
│  Latest Payout: KES 46,217.50  (May 2026)  [View Statement PDF]       │
│                                                                         │
│  ── Payout History ──────────────────────────────────────────────────  │
│  Period       │ Gross Rev │ Deductions │ Net Payout │ Status │ PDF    │
│  May 2026     │ 78,000    │ 8,500      │ 46,217.50  │ Paid   │ [↓]    │
│  Apr 2026     │ 65,000    │ 3,200      │ 41,202.50  │ Paid   │ [↓]    │
│  Mar 2026     │ 0         │ 0          │ 17,500.00  │ Paid   │ [↓]    │
└──────────────────────────────────────────────────────────────────────┘
```

- Investor sees **only their own** vehicles/payouts (row-level scoping via
  `investor_user_id` in every query — never client-side filtering).
- No edit capability anywhere on this screen — strictly `READ` permission.
- "View Statement PDF" opens the `generated_document` linked via
  `investor_payout_run.statement_document_id`.
