# UI Spec — Automation Rules Builder

Audience: **Super Admin / Branch Manager** (the screen that makes
"admin-customizable automation" tangible — no-code rule creation).

## Screen 1: Rule List

```
┌────────────────────────────────────────────────────────────────────────┐
│  Automation Rules                                  [+ New Rule]        │
│  Branch: [All Branches ▾]   Status: [All ▾]   Search: [___________]    │
├────────────────────────────────────────────────────────────────────────┤
│ Pri │ Name                                  │ Trigger          │ Active│
├─────┼───────────────────────────────────────┼───────────────────┼───────┤
│  10 │ Booking confirmed — send SMS + agreement │ Booking Confirmed│  ✓   │
│  20 │ Lease installment due reminder (3 days) │ Installment Due  │  ✓   │
│  30 │ Lease installment overdue — first notice│ Installment Overdue│ ✓  │
│  40 │ Escalate — lease 7+ days overdue        │ Installment Overdue│ ✓  │
│  50 │ Vehicle document expiring in 30 days    │ Document Expiring│  ✓   │
│ 100 │ Custom: Mombasa 5-day grace period       │ Installment Overdue│ ✓  │
│ 110 │ [Disabled] Old lead reminder rule       │ Lead No Contact   │  ✗  │
└────────────────────────────────────────────────────────────────────────┘
```

- **Priority** column is editable inline (drag-to-reorder or type a number)
  — controls evaluation order when multiple rules share a trigger.
- Toggling **Active** is a single click, no confirmation needed (reversible,
  non-destructive — history is preserved either way).
- Row click opens the Rule Editor.

## Screen 2: Rule Editor

```
┌──────────────────────────────────────────────────────────────────────┐
│  Edit Rule: Lease installment overdue — first notice                  │
├──────────────────────────────────────────────────────────────────────┤
│  Rule Name *        [Lease installment overdue — first notice____]    │
│  Applies to Branch  [All Branches ▾]                                  │
│  Priority            [30]                                              │
│  Active              [✓]                                               │
│                                                                          │
│  ── 1. TRIGGER ─────────────────────────────────────────────────────   │
│  When                [Lease Installment Overdue ▾]                     │
│  Timing               ◉ As soon as overdue                             │
│                        ○ After [__] days overdue                       │
│  Repeat               ☑ Repeat every [2] days while still overdue      │
│                                                                          │
│  ── 2. CONDITIONS (all must be true) ──────────────────────────────     │
│  ┌────────────────────────────────────────────────────────────────┐   │
│  │ [Installment Status ▾] [is not ▾] [Paid ▾]            [✕]      │   │
│  └────────────────────────────────────────────────────────────────┘   │
│  [+ Add Condition]   [+ Add OR Group]                                  │
│                                                                          │
│  ── 3. ACTIONS (run in order) ──────────────────────────────────────   │
│  ┌────────────────────────────────────────────────────────────────┐   │
│  │ 1. [Send SMS ▾]  Template: [Installment Overdue SMS ▾]   [✕]   │   │
│  │    To: [Customer's phone ▾]                                     │   │
│  │    Preview: "Hi {{first_name}}, payment of {{currency}}..."     │   │
│  ├────────────────────────────────────────────────────────────────┤   │
│  │ 2. [Apply Late Fee ▾]  Rate from setting: [LATE_FEE_PERCENT ▾]  │   │
│  ├────────────────────────────────────────────────────────────────┤   │
│  │ 3. [Change Status ▾]  Set [Installment Status ▾] to [Overdue ▾]│   │
│  └────────────────────────────────────────────────────────────────┘   │
│  [+ Add Action]                                                        │
│                                                                          │
│  [Cancel]                  [Test Run (preview, no actions sent)] [Save]│
└──────────────────────────────────────────────────────────────────────┘
```

### Behavior
- **Trigger** dropdown lists the fixed set of `trigger_event` values the
  engine supports (these correspond to real code-level hooks — admins
  choose *when*, not invent new triggers).
- **Timing** ("As soon as" vs "After N days") and **Repeat** write into
  `trigger_offset_json` (`{value: N, repeat_interval_days: M}`).
- **Conditions** builder: each row is `field` (dropdown scoped to the
  trigger's entity — e.g. for "Installment Overdue" it offers
  `booking_installment.*`, `booking.*`, `customer.*` fields),
  `operator` (dropdown filtered to valid ops for the field's data type —
  e.g. text fields don't show `>`/`<`), and `value` (free text, dropdown,
  or date picker depending on field type). "+ Add OR Group" nests a
  sub-array per the engine's OR-within-AND semantics.
- **Actions** builder: each row's second/third controls change based on the
  selected action type (`Send SMS` → template + recipient dropdowns;
  `Create Task` → title template + assignee role; `Apply Late Fee` → which
  system_setting to read the percentage from, so admins aren't hardcoding a
  number here either — keeping it consistent with the one used elsewhere).
  A live **Preview** renders the template against a sample/most-recent real
  record so the admin sees actual resulting text, not just the raw template.
- **Test Run** executes condition evaluation against real current data and
  shows "Would have matched: 3 installments" with a list, **without**
  actually sending SMS/emails or changing any status — critical for admins
  to trust a rule before activating it broadly.
- **Save** validates: at least one action, at least one condition or an
  explicit "no conditions — always fire" acknowledgment checkbox (prevents
  accidentally creating a rule with no filter that spams everyone).

## Screen 3: Execution Log (debugging / transparency)

```
┌──────────────────────────────────────────────────────────────────────┐
│  Execution Log — "Lease installment overdue — first notice"           │
├──────────────────────────────────────────────────────────────────────┤
│  Date/Time          │ Entity              │ Matched │ Actions Taken   │
├──────────────────────┼──────────────────────┼─────────┼─────────────────┤
│ 24 Jun 2026, 02:00   │ Installment #4 (BK-00045)│ ✓  │ SMS sent, fee applied │
│ 24 Jun 2026, 02:00   │ Installment #2 (BK-00091)│ ✗  │ —  (already paid)   │
│ 23 Jun 2026, 02:00   │ Installment #4 (BK-00045)│ ✓  │ SMS sent, fee applied │
└──────────────────────────────────────────────────────────────────────┘
```

- Lets an admin verify a rule is actually firing as expected (or
  troubleshoot a "why didn't this customer get an SMS" support question) by
  filtering directly to the entity in question.

## Why this screen design satisfies "admin-customizable automation"

Every editable control here maps 1:1 to a JSONB field on `automation_rule`
— there is no code path where adding a new reminder cadence, recipient, or
condition requires touching the NestJS codebase. The only way new
*capability* enters the system (a genuinely new trigger event, a genuinely
new action type like "send WhatsApp message") is a developer addition — but
everything an operations team would realistically want to tune week-to-week
(timing, wording, thresholds, who gets notified, which branch it applies to)
lives entirely in this screen.
