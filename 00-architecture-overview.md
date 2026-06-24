# LAMURI Car Hire — System Architecture Overview

## Design Philosophy: Configuration Over Code

The brief calls for a system where **admins customize everything** — payout models,
tax rules, branch structures, currencies, fee schedules, automation rules — **without
a developer touching code**. This dictates the core architectural pattern used
throughout:

> **Rules, formulas, and structures live in database tables and are interpreted by
> generic engines at runtime.** Code implements *capabilities* (e.g. "compute a
> payout using a formula tree"); admins configure *behavior* (e.g. "investors get
> 65% of net revenue, paid monthly, minimum KES 15,000").

This shows up in five places:

| Area | Hardcoded approach (rejected) | Configuration-driven approach (used) |
|---|---|---|
| Investor payouts | `payout = revenue * 0.65` in code | `payout_formula` table holds formula type + parameters per contract; one **Payout Calculation Engine** evaluates any formula |
| Tax | VAT rate hardcoded at 16% | `tax_rule` table with rate, applicability, effective dates, per-branch/country override |
| Branches/currency | Single `branch` assumed | Every money-bearing row carries `branch_id` and `currency_code`; `exchange_rate` table converts for consolidated reporting |
| Automation | If/else in service classes | `automation_rule` table: trigger → conditions → actions, evaluated by a **Rule Engine** |
| Document templates | Static PDF | `document_template` table holds a Handlebars-style template per document type per branch; merge engine fills it |

## Tech Stack

- **Backend:** NestJS (Node.js, TypeScript) — modular, dependency-injection friendly,
  good fit for a rule/engine-based architecture (each engine is a Nest provider).
- **Database:** PostgreSQL — JSONB for flexible config (formula parameters, rule
  conditions) while keeping relational integrity for core entities.
- **Queue/Jobs:** BullMQ (Redis-backed) — for SMS sending, payout runs, statement
  generation, scheduled dispatch reminders.
- **ORM:** Prisma or TypeORM (examples below use TypeORM-style entities; Prisma schema
  equivalent is straightforward since the schema is relational).
- **Caching:** Redis — exchange rates, tax rules, active rule sets.
- **File storage:** S3-compatible (for ID scans, vehicle photos, signed agreements).

## High-Level Module Map

```
┌─────────────────────────────────────────────────────────────────────┐
│                          LAMURI CORE PLATFORM                        │
├───────────────┬───────────────┬───────────────┬─────────────────────┤
│  IDENTITY &   │   FLEET &     │   RENTAL &    │   INVESTOR &        │
│  ACCESS       │   VEHICLE     │   BOOKING     │   OWNERSHIP         │
│  - Users      │   - Vehicles  │   - Bookings   │   - Investors       │
│  - Roles      │   - Owners    │   - Agreements │   - Contracts       │
│  - Branches   │   - Docs/Insur│   - Dispatch   │   - Payout Engine   │
│  - Permissions│   - Maint.    │   - Returns    │   - Payout Runs     │
├───────────────┼───────────────┼───────────────┼─────────────────────┤
│  CRM & LEADS  │  FINANCE &    │  COMMS         │  CONFIG &           │
│  - Leads      │  ACCOUNTING   │  - SMS (AT)    │  AUTOMATION         │
│  - Pipeline   │  - Invoices   │  - Email       │  - Rule Engine      │
│  - Follow-ups │  - Payments   │  - Templates   │  - Tax Rules        │
│  - Campaigns  │  - Tax Engine │  - Print/PDF   │  - Numbering        │
│               │  - Ledger     │                │  - Audit Log        │
└───────────────┴───────────────┴───────────────┴─────────────────────┘
```

## Multi-Branch / Multi-Currency Model

- `branch` is a first-class entity. Every vehicle, booking, invoice, payment, and
  staff assignment belongs to a branch.
- `branch.currency_code` sets the branch's operating currency (default KES).
- A `country` and `tax_jurisdiction` table allow each branch to apply different tax
  rules (VAT %, withholding tax, excise duty on car hire where applicable) — needed
  for the "Kenya now, other countries later" trajectory.
- Consolidated reporting converts via `exchange_rate` (date-stamped, source/target
  currency) at the time of report generation. Ledger entries always store original
  transaction currency **and** a converted base-currency amount for group reporting.

## Engines (the customizable "brains")

1. **Payout Calculation Engine** — evaluates an investor's contract formula against
   a period's revenue/cost data. See `02-investor-payout-engine.md`.
2. **Tax Engine** — resolves applicable tax rules for a transaction by branch,
   jurisdiction, customer type, and date; computes VAT/withholding/excise.
3. **Rule Engine (Automation)** — trigger/condition/action evaluator for reminders,
   escalations, SMS/email sends, late fees, status transitions. See
   `04-automation-rules-engine.md`.
4. **Document Merge Engine** — fills templates (agreements, invoices, receipts,
   statements) with transaction data and renders to PDF.
5. **Numbering Engine** — generates sequential, branch-aware, gapless document
   numbers (invoice #, receipt #, agreement #) per local tax authority rules (KRA
   requires sequential, non-reusable invoice numbers).

## Roles Modeled (Staff)

The schema supports arbitrary roles via `role` + `permission` + `role_permission`
(RBAC), but the business roles LAMURI is expected to need out of the box are seeded:

- **Super Admin** — full system config, all branches.
- **Branch Manager** — full operational control of one branch.
- **Fleet/Dispatch Officer** — vehicle assignment, handover/return inspections.
- **Reservations/Customer Service** — bookings, lead follow-up, customer comms.
- **Accountant/Finance Officer** — invoicing, payments, tax filing exports, payout
  approval.
- **Mechanic/Workshop Supervisor** — maintenance checklists, service scheduling.
- **Investor (portal-only role)** — read-only access to their own vehicles,
  statements, payout history. Not "staff" but uses the same auth system.
- **Sales/CRM Agent** — leads pipeline, campaigns.

Roles are editable; permissions are granular (resource + action), so admins can
create new roles or adjust existing ones from a UI screen — no code change needed.

## Document Set Produced By The System

| Document | Trigger | Engine |
|---|---|---|
| Rental Agreement | Booking confirmed | Document Merge Engine |
| Invoice | Booking charge raised / recurring lease cycle | Finance + Numbering Engine |
| Receipt | Payment received | Finance + Numbering Engine |
| Statement (customer) | On demand / monthly | Finance Engine |
| Statement (investor) | Payout run completed | Payout Engine |
| Handover/Return Inspection Form | Dispatch / Return | Vehicle Engine |
| Maintenance Checklist | Service due/completed | Maintenance Engine |
| Credit Note | Refund/adjustment | Finance Engine |

## Files In This Design Package

1. `00-architecture-overview.md` — this file
2. `01-database-schema.sql` — full PostgreSQL schema with comments
3. `01-er-relationships.md` — entity relationship narrative + key cardinalities
4. `02-investor-payout-engine.md` — payout formula model + calculation engine logic
5. `03-rental-agreement-template.md` — clause-by-clause agreement template (merge-ready)
6. `04-automation-rules-engine.md` — rule engine design + seeded rule library
7. `05-mpesa-integration-spec.md` — M-Pesa Daraja integration (STK Push, C2B, B2C for payouts)
8. `06-africastalking-sms-spec.md` — Africa's Talking SMS integration + message templates
9. `ui-specs/` — screen-by-screen UI specifications for key modules
