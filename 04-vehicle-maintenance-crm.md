# UI Spec — Vehicle Detail / Maintenance & CRM Leads Pipeline

## Part A: Vehicle Detail Screen

Audience: **Fleet/Dispatch Officer**, **Workshop Supervisor**, **Branch Manager**.

```
┌──────────────────────────────────────────────────────────────────────┐
│  KDA 123A — Toyota RAV4 (2022)                  Status: ● Rented      │
│  [Vehicles] [Bookings] [Maintenance] [Insurance] [Documents] [History] │
├──────────────────────────────────────────────────────────────────────┤
│  Ownership: Investor-Owned (Jane Wanjiru — IC-NBO-0042)                │
│  Category: SUV   Odometer: 84,545 km   Fuel: Petrol   Trans: Auto     │
│  Daily Rate: KES 7,500   Currency: KES   Home Branch: Nairobi CBD     │
│                                                                          │
│  ── Maintenance Tab (active) ──────────────────────────────────────     │
│  Next Service Due: at 90,000 km (5,455 km remaining) or 15 Aug 2026     │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ Date       │ Type       │ Vendor        │ Cost      │ Billed To  │  │
│  ├────────────┼────────────┼───────────────┼───────────┼────────────┤  │
│  │ 12 May 2026│ Scheduled  │ Toyota Kenya  │ 12,000.00 │ Investor   │  │
│  │ 03 Mar 2026│ Tire       │ Yana Tyres    │  8,500.00 │ Company    │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│  [+ Log Maintenance]                                                    │
└──────────────────────────────────────────────────────────────────────┘
```

### "+ Log Maintenance" form

```
┌──────────────────────────────────────────────────────────────┐
│  Log Maintenance — KDA 123A                                   │
├──────────────────────────────────────────────────────────────┤
│  Service Type *      [Scheduled ▾]                             │
│  Schedule Template    [Standard Service - 10,000km ▾]          │
│  Odometer at Service  [84,545]                                  │
│  Scheduled Date       [10/08/2026]   Completed Date [________]  │
│  Vendor               [Toyota Kenya___________]                 │
│  Cost                 [KES] [12,000.00]                         │
│  Billed To            ◉ Company   ○ Investor                    │
│  Notes                [________________________________]        │
│  Invoice/Receipt      [📎 Upload]                                │
│                                                                    │
│  ── Checklist (auto-loaded from template) ──────────────────      │
│  ☐ Engine oil & filter        [OK ▾]                              │
│  ☐ Brake pads (front/rear)    [Needs Attention ▾]  Remarks: [___]  │
│  ☐ Tire pressure & tread      [OK ▾]                                │
│  ☐ Coolant level               [OK ▾]                                │
│  ☐ Battery health               [OK ▾]                                │
│  ☐ Air filter                    [Replaced ▾]                          │
│  ☐ Wipers                         [OK ▾]                                │
│                                                                          │
│  [Cancel]                                          [Save Maintenance]  │
└──────────────────────────────────────────────────────────────┘
```

### Behavior
- **Billed To = Investor** shows an inline note: "This cost will be deducted
  from {{investor_name}}'s next payout for this vehicle" — directly
  connecting fleet-ops action to financial consequence, so a Workshop
  Supervisor doesn't accidentally cost an investor money without visibility.
- Checklist items are seeded from `maintenance_schedule_template.checklist_items_json`
  for the selected template, each row writing to `maintenance_checklist_result`.
  "Needs Attention" status on any item auto-creates a follow-up `staff_task`.
- **Vehicle status** auto-sets to `IN_SERVICE` while a maintenance record is
  `IN_PROGRESS`, reverting to `AVAILABLE` on completion (vehicle is
  unbookable during service — booking creation must check this).

### Documents Tab (expiry tracking)

```
┌──────────────────────────────────────────────────────────────────────┐
│  Documents Tab                                                        │
├──────────────────────────────────────────────────────────────────────┤
│  Type             │ Document No.  │ Expiry      │ Status              │
│  Insurance         │ POL-88213    │ 14 Jul 2026 │ ⚠ Expires in 20 days│
│  Inspection Cert.   │ NTSA-44521  │ 02 Jan 2027 │ ✓ Valid              │
│  Logbook            │ —            │ —           │ ✓ On file            │
│  [+ Add Document]                                                      │
└──────────────────────────────────────────────────────────────────────┘
```
Rows within the `VEHICLE_DOC_EXPIRY_ALERT_DAYS` window (system setting)
show the amber ⚠ state automatically — this list is the human-facing mirror
of what the `VEHICLE_DOC_EXPIRING` automation rule is already alerting on.

---

## Part B: CRM Leads Pipeline

Audience: **CRM/Sales Agent**, **Branch Manager**.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Leads Pipeline                          [+ New Lead]  [+ New Campaign]  │
│  Branch: [Nairobi ▾]   Assigned to: [All Agents ▾]                       │
├──────────┬─────────────┬─────────────┬─────────────┬─────────┬───────────┤
│   New    │  Contacted  │ Quote Sent  │ Negotiation │  Won    │   Lost    │
│   (7)    │    (12)     │    (5)      │    (3)      │  (41)   │   (18)    │
├──────────┼─────────────┼─────────────┼─────────────┼─────────┼───────────┤
│ Alice K. │ Tom M.       │ Safari Co.  │ Corp Deal X │ ...     │ ...       │
│ Website  │ Facebook Ad  │ Referral    │ Corp Out.   │         │           │
│ 2h ago   │ Follow-up    │ KES 90,000  │ Negotiating │         │           │
│ ⚠ no     │ due today    │ est. value  │ 15% discount│         │           │
│  contact │              │             │ requested   │         │           │
└──────────┴─────────────┴─────────────┴─────────────┴─────────┴───────────┘
```

- Drag-and-drop between stages writes to `lead.pipeline_stage_id` and logs a
  `lead_activity (activity_type='STAGE_CHANGE')` automatically.
- ⚠ badge on cards matches the `LEAD_NO_CONTACT` automation rule's window —
  again, the UI surfaces exactly what the rule engine is tracking, not a
  separate parallel notion of "stale."
- Card click opens Lead Detail (timeline of all `lead_activity` rows, quick
  actions: Log Call, Send SMS, Send Quote, Convert to Customer & Booking).

### Lead Detail — Convert to Booking

```
┌──────────────────────────────────────────────────────────────┐
│  Alice Kamau — Lead #1042                     Stage: Quote Sent│
├──────────────────────────────────────────────────────────────┤
│  Phone: 0712 345 678     Source: Website Form                 │
│  Interested: SUV, 24 Jun – 27 Jun                              │
│  Assigned to: Brenda M. (CRM Agent)                            │
│                                                                  │
│  ── Activity Timeline ──                                        │
│  24 Jun, 09:10 — Note: "Asked about weekend SUV rates"          │
│  24 Jun, 09:15 — SMS sent: Quote details                        │
│  [+ Log Activity]                                                │
│                                                                  │
│  [Convert to Booking →]                                          │
└──────────────────────────────────────────────────────────────┘
```

- **Convert to Booking** pre-fills the New Booking form (Screen 2 in the
  Booking spec) with the lead's name/phone/category/dates, and on save sets
  `lead.converted_customer_user_id`, `lead.converted_at`, moves the lead to
  the "Won" stage automatically, and sets `booking.lead_id` so the
  conversion is traceable both ways for CRM reporting (lead source → revenue
  attribution).

### New Campaign (SMS blast)

```
┌──────────────────────────────────────────────────────────────┐
│  New Campaign                                                  │
├──────────────────────────────────────────────────────────────┤
│  Name *           [Long Weekend SUV Promo___________]          │
│  Channel           ◉ SMS   ○ Email                              │
│  Audience          [Build Segment ▾]                            │
│    ┌────────────────────────────────────────────────────────┐  │
│    │ Customer Type: [Any ▾]                                  │  │
│    │ Last Booking: [more than ▾] [90] days ago                │  │
│    │ Branch: [Nairobi ▾]                                       │  │
│    └────────────────────────────────────────────────────────┘  │
│    Matches: 312 customers                                        │
│  Message Template  [Select or write new ▾]                       │
│    Preview: "Hi {{first_name}}, long weekend SUV special..."      │
│    SMS segments: 1 (148/160 chars)        Est. cost: KES 249.60   │
│  Schedule           ◉ Send Now   ○ Schedule for [____________]    │
│                                                                      │
│  [Cancel]                                    [Send Campaign]       │
└──────────────────────────────────────────────────────────────┘
```
- "Build Segment" filters translate directly into `campaign.target_segment_json`,
  matching the same generic field/operator pattern used in the Automation
  Rules condition builder — one mental model reused across the product
  instead of two different filter UIs to learn.
- Segment match count and SMS cost estimate update live as filters change,
  so admins see budget impact before committing spend.
