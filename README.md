# LAMURI Car Hire — Full System Design Package

A configuration-driven car rental management system: customers, investor
(vehicle owner) leasing, staff RBAC, fleet/dispatch/maintenance/insurance,
CRM & leads, automated accounting/tax, SMS (Africa's Talking), M-Pesa
payments & payouts, and document generation (agreements, invoices,
receipts, statements) — all tunable by an admin without code changes.

**Stack:** NestJS (TypeScript) + PostgreSQL + Redis/BullMQ.
**Scope:** Multi-branch, multi-currency, Kenya-first with room to expand.

## How to read this package

Start with `docs/00-architecture-overview.md` for the philosophy and module
map, then the schema, then the engines/specs in whatever order matches what
you're building first.

```
lamuri/
├── docs/
│   └── 00-architecture-overview.md       ← START HERE: design philosophy, module map, roles
│
├── schema/
│   ├── 01-database-schema.sql            ← full PostgreSQL DDL, 59 tables, 10 sections
│   ├── 02-seed-data.sql                  ← default roles/permissions/tax rules/COA/templates
│   └── 03-er-relationships.md            ← narrative guide to cardinalities & design decisions
│
├── engines/
│   ├── 02-investor-payout-engine.md      ← the 5 payout formula types + calculation algorithm
│   └── 04-automation-rules-engine.md     ← trigger/condition/action engine + seed rule library
│
├── templates/
│   └── 07-rental-agreement-template.md   ← full clause-by-clause merge-ready agreement
│
├── integrations/
│   ├── 05-mpesa-integration-spec.md      ← STK Push, C2B, B2C (Daraja API) with code
│   └── 06-africastalking-sms-spec.md     ← SMS send, delivery reports, campaigns
│
└── ui-specs/
    ├── 01-investor-payout-dashboard.md   ← payout queue, detail drawer, formula template admin, investor portal
    ├── 02-booking-dispatch-return.md     ← booking board, new booking form, dispatch/return inspection
    ├── 03-automation-rules-builder.md    ← no-code rule editor + execution log
    └── 04-vehicle-maintenance-crm.md     ← vehicle detail/maintenance, CRM leads pipeline & campaigns
```

## What makes this "admin-customizable" in practice

| You asked for... | Where it lives | How an admin changes it |
|---|---|---|
| Customizable investor payout model | `payout_formula_template` table, 5 formula types | UI Screen 4 in payout dashboard — no code |
| Weekly/monthly customer leasing | `booking.rental_mode` + `booking_installment` | Built into booking form; rate plans configurable |
| Staff roles & responsibilities | `role` / `permission` / `role_permission` (RBAC) | Settings → Roles screen (not separately specced, but same pattern as automation rules screen) |
| Vehicle dispatch/service/insurance/maintenance | Sections 3 & schema tables `vehicle_inspection`, `maintenance_record`, `insurance_policy` | Vehicle Detail screen tabs |
| Leads & CRM | `lead`, `lead_pipeline_stage`, `campaign` | CRM pipeline screen; pipeline stages themselves are editable rows |
| SMS sending | Africa's Talking spec + `message_template` + `sms_log` | Message wording editable per template; rules decide when to send |
| Automated accounting & tax | `chart_of_account` + `journal_entry` (double-entry) + `tax_rule` | Tax rates/rules editable with effective-date versioning |
| Email, print, receipts, invoices, statements | `document_template` + `generated_document` + Numbering Engine | Template body HTML editable per branch/version |
| Multi-branch, multi-currency | `branch`, `currency`, `exchange_rate` on every money table | New branch = new row, not new deploy |

## Suggested build order for an engineering team

1. **Schema + seed data** (`schema/`) — stand up Postgres, run migrations.
2. **Identity/RBAC + Branch/Settings** — log in, manage users, configure
   `system_setting`.
3. **Fleet module** — vehicles, documents, insurance (no money flow yet).
4. **Booking + Dispatch/Return** — the core operational loop.
5. **Finance** — invoices, payments, M-Pesa STK/C2B (customer money in).
6. **Investor contracts + Payout Engine** — M-Pesa B2C (money out).
7. **Automation Rule Engine** — wire up the seeded rule library; SMS/email
   sending depends on this being live.
8. **CRM/Leads + Campaigns** — typically lowest urgency operationally, but
   highest revenue-growth value once the core loop is stable.
9. **Reporting & accounting exports** (P&L by branch, tax filing exports,
   investor statements) — layer on top of the journal_entry ledger once
   enough real transactions exist to validate against.

## Known follow-ups not yet detailed in this pass

- Full RBAC "Manage Roles" screen spec (pattern established by the
  automation rules builder — same dynamic permission-grid approach).
- Reporting/dashboard screens (P&L, fleet utilization, branch comparison).
- Customer self-service portal (booking online, viewing invoices) — the
  investor portal pattern in `ui-specs/01` extends directly to this.
- Bank-transfer payout export format (mentioned as a fallback to M-Pesa B2C
  in the payout engine, format itself not yet specified — depends on which
  Kenyan bank's bulk-payment file format the investor's bank requires).
- WhatsApp Business API as a third comms channel (same `message_template`
  /rule-engine pattern would extend to it).

Ask for any of these next, or for a deep dive turning any one module above
into actual NestJS controller/service/entity code rather than spec-level
pseudocode.
