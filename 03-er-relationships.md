# Entity Relationships — Narrative Guide

This explains *why* the schema is shaped the way it is, and the key
cardinalities a developer needs to know before writing queries or ORM
entities. Read alongside `01-database-schema.sql`.

## 1. Everything hangs off `branch`

`branch` is the multi-tenancy boundary for *operations* (not for security —
a Super Admin sees all branches; a Branch Manager is scoped to one via
`user_role.branch_id`). Almost every transactional table carries `branch_id`
directly, even when it could theoretically be derived through a join (e.g.
`invoice.branch_id` could be inferred from `invoice.booking_id → booking.branch_id`)
— this is intentional **denormalization for reporting speed**: branch-level
P&L, tax filing exports, and dashboards filter on a single indexed column
instead of multi-table joins.

## 2. One `app_user` table, multiple "hats"

Rather than separate `staff`, `customer`, `investor` tables with duplicated
name/phone/email columns, there's **one identity table** (`app_user`) and
**profile extension tables** (`staff_profile`, `customer_profile`,
`investor_profile`) that 1:1 extend it based on `user_type`.

Why: a single phone number is the universal lookup key for SMS/OTP login,
and in practice a person can wear more than one hat (an investor who is
also a corporate customer; a staff member who is also a shareholder/investor).
This model supports that without duplicate identities. `user_type` is the
*primary* hat for login/menu purposes; profile table presence is the source
of truth for *capabilities*.

## 3. Investor side vs Customer side — two distinct lease concepts

The brief mentions "leasing model with weekly and monthly payments" once,
but it actually means **two different relationships**:

| | Who pays whom | Modeled by |
|---|---|---|
| **Investor leasing** | LAMURI pays the vehicle owner | `investor_contract` + `investor_payout_run` |
| **Customer leasing** | The renter pays LAMURI, on a weekly/monthly schedule instead of one lump sum | `booking` (rental_mode = WEEKLY/MONTHLY) + `booking_installment` |

These are independent and can combine: an investor-owned vehicle can be
rented to a customer on a monthly lease. Revenue from that customer lease
flows into `investor_payout_run.gross_revenue` for that vehicle's contract
period — see the Payout Engine doc for exactly how bookings map to payout
periods.

## 4. `vehicle.ownership_type` decides whether a payout pipeline exists

`vehicle.ownership_type = 'INVESTOR_OWNED'` is the flag the Payout Engine
uses to know a vehicle needs to be matched against an active
`investor_contract`. `'COMPANY_OWNED'` vehicles skip the payout pipeline
entirely — their revenue just posts straight to company revenue accounts
with no investor deduction step.

A vehicle can change hands (investor sells out, company buys it outright,
or vice versa) — that's why `investor_contract` has its own
`contract_start_date`/`contract_end_date` rather than living as static
columns on `vehicle`. History of past contracts is preserved.

## 5. Booking → Installment → Invoice → Payment chain

```
booking (1) ──< booking_installment (many, only for WEEKLY/MONTHLY rental_mode)
                      │
                      ▼
                  invoice (1:1 per installment, or 1:1 per booking for DAILY mode)
                      │
                      ▼
                  payment (many — supports partial payments)
```

For a `DAILY` booking, there's typically one invoice covering the whole stay
(no `booking_installment` rows needed — `invoice.booking_installment_id` is
NULL and `invoice.booking_id` is set directly).

For `WEEKLY`/`MONTHLY` rental_mode, the system pre-generates
`booking_installment` rows for the full lease term at booking confirmation
time (e.g. a 6-month lease → 6 monthly installment rows), then raises one
`invoice` per installment a configurable number of days before its `due_date`
(see Automation Rules doc, rule `INVOICE_GENERATION_LEASE_CYCLE`).

A `payment` can be partial (`amount < invoice.total_amount`); `invoice.status`
moves DRAFT → SENT → PARTIAL → PAID as payments land. Multiple payments per
invoice are supported (customer pays in two M-Pesa transactions).

## 6. Maintenance & Insurance feed BOTH operations and the Payout Engine

`maintenance_record.billed_to` and `insurance_policy.billed_to` (values
`'COMPANY'` or `'INVESTOR'`) are the bridge between fleet operations and
finance. When an investor's contract has `deduct_maintenance = TRUE`, the
Payout Engine sums `maintenance_record` rows for that vehicle in the period
where `billed_to = 'INVESTOR'` and subtracts them from gross revenue before
computing the investor's share. Company-billed maintenance never touches
investor payouts.

## 7. Dispatch & Return are just two rows in `vehicle_inspection`

Rather than separate `dispatch_record` and `return_record` tables (which
would duplicate ~15 identical columns), `vehicle_inspection` holds both,
distinguished by `inspection_type IN ('DISPATCH','RETURN')`. A booking
normally has exactly one of each, queryable as:

```sql
SELECT * FROM vehicle_inspection
WHERE booking_id = :id AND inspection_type = 'DISPATCH';
```

Damage found on RETURN that wasn't on DISPATCH is what triggers
`booking_extra_charge (charge_type = 'DAMAGE')` and potentially
`insurance_claim`.

## 8. Accounting is real double-entry, generated automatically

`journal_entry` + `journal_entry_line` implement standard double-entry
bookkeeping (every entry's debits = credits — enforced at the application
layer when posting, since cross-row balance can't be a single-row CHECK
constraint). Every revenue-generating or expense event in the system
(`invoice` issued, `payment` received, `investor_payout_run` paid,
`expense` recorded) triggers the **Finance Posting Service** to write a
journal entry automatically against the seeded `chart_of_account`. Admins
never hand-journal routine transactions; they only post adjusting entries
manually when truly needed.

## 9. Tax is resolved, not hardcoded

`invoice.tax_rule_id_snapshot` stores *which* `tax_rule` row was applied at
invoice time — even if the admin changes the VAT rate next year, historical
invoices remain correct and auditable. The Tax Engine resolution order is:

1. Find `tax_rule` rows where `applies_to` matches the transaction type
   (or `'ALL'`), `jurisdiction_id` matches the branch's jurisdiction, and
   `effective_from <= transaction_date <= effective_to (or open-ended)`.
2. Filter by `customer_type_filter` if set (NULL = applies to everyone).
3. If multiple rules match (e.g. VAT + a local levy), apply all — multiple
   `invoice_line_item.tax_rate_percent` can stack additively unless flagged
   otherwise.

## 10. Automation rules don't touch code — they touch JSONB

`automation_rule.conditions_json` and `actions_json` are evaluated by a
generic rule engine (see `04-automation-rules-engine.md`). Adding "also
notify the branch manager by email when a lease is 7 days overdue" is a
single INSERT, not a deploy.

## Cardinality Quick Reference

| Relationship | Cardinality |
|---|---|
| branch → vehicle | 1:many |
| vehicle → investor_contract | 1:many (over time, only one ACTIVE at once) |
| investor_contract → investor_payout_run | 1:many |
| customer (app_user) → booking | 1:many |
| booking → booking_installment | 1:many (0 for DAILY mode) |
| booking → rental_agreement | 1:1 |
| booking → vehicle_inspection | 1:2 (DISPATCH + RETURN) |
| invoice → payment | 1:many |
| invoice → invoice_line_item | 1:many |
| lead → lead_activity | 1:many |
| lead → booking | 1:0..1 (converted lead links via `lead.converted_customer_user_id` then customer books normally; `booking.lead_id` traces it back) |
| automation_rule → automation_rule_execution_log | 1:many |
| document_template → generated_document | 1:many |
