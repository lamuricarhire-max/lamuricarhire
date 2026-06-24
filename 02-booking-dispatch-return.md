# UI Spec — Booking, Dispatch & Return Inspection

Audience: **Reservations Agent**, **Dispatch Officer**.

## Screen 1: Booking Calendar / Board

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Bookings              Branch: [Nairobi ▾]    View: [Board] [Calendar]   │
│  [+ New Booking]                                Search: [____________]   │
│                                                                            │
│  ┌──────────┬──────────────┬──────────────┬──────────────┬─────────────┐ │
│  │ Inquiry  │  Confirmed   │  Dispatched  │   Active     │  Returned   │ │
│  │   (4)    │     (9)      │     (3)      │    (21)      │  Today (5)  │ │
│  ├──────────┼──────────────┼──────────────┼──────────────┼─────────────┤ │
│  │ NBO-BK-  │ NBO-BK-00121 │ NBO-BK-00098 │ NBO-BK-00076 │ NBO-BK-00050│ │
│  │ 00130    │ John K.      │ Mary A.      │ Corp: Safari │ Peter O.    │ │
│  │ Alice W. │ Toyota Axio  │ KDA 123A     │ Tours Ltd    │ KDF 789C    │ │
│  │ Economy  │ Today 2pm    │ Out since    │ Monthly      │ Returned    │ │
│  │ ?dates   │ pickup       │ Tue          │ lease, 4/6   │ 9:15am      │ │
│  │ [Quote]  │ [Dispatch]   │ [Return]     │ paid         │ [Inspect]   │ │
│  └──────────┴──────────────┴──────────────┴──────────────┴─────────────┘ │
└──────────────────────────────────────────────────────────────────────────┘
```

### Behavior
- Kanban-style board grouped by `booking.status`. Cards are draggable
  between adjacent statuses only where a valid transition exists (e.g. can't
  drag `INQUIRY` straight to `ACTIVE` — must pass through `CONFIRMED` →
  `DISPATCHED`). Invalid drop targets are visually disabled (greyed) while dragging.
- Each card's primary button matches its next logical action: `Quote` →
  `Dispatch` → `Return` → `Inspect`.
- Cards for `WEEKLY`/`MONTHLY` bookings show installment progress
  ("4/6 paid") pulled from `booking_installment`.
- Calendar view (toggle) shows the same data as a Gantt-style timeline per
  vehicle — useful for spotting double-booking risk before confirming.

## Screen 2: New Booking Form

```
┌──────────────────────────────────────────────────────────────────────┐
│  New Booking                                                          │
├──────────────────────────────────────────────────────────────────────┤
│  Customer *      [Search by phone/name — or + New Customer]           │
│                                                                         │
│  Rental Mode      ◉ Daily   ○ Weekly   ○ Monthly                      │
│  Vehicle Category [SUV ▾]      Specific Vehicle (optional) [______▾]   │
│  Start            [24/06/2026] [09:00]                                 │
│  End              [27/06/2026] [09:00]      → 3 days                   │
│                                                                         │
│  Rate Plan        [Standard Daily - SUV ▾]   KES 7,500/day             │
│  Pickup Location  [Branch — Nairobi CBD ▾]                             │
│  Dropoff Location [Same as pickup ▾]                                   │
│  Driver Required  ☐                                                    │
│                                                                         │
│  ── Pricing Summary ──────────────────────────────────────────────────  │
│  Base Charge (3 days × 7,500)                          KES 22,500.00   │
│  Security Deposit (20%)                                 KES 4,500.00   │
│  ───────────────────────────────────────────────────────────────────   │
│  Total Due Now                                         KES 27,000.00   │
│                                                                         │
│  [Cancel]                              [Save as Quote] [Confirm Booking]│
└──────────────────────────────────────────────────────────────────────┘
```

### Behavior
- Selecting **Weekly/Monthly** replaces the Pricing Summary with the
  installment schedule preview (mirrors the agreement template's
  installments table) and a note: "An invoice will be generated automatically
  {{N}} days before each due date."
- **Specific Vehicle** dropdown filters to `status = 'AVAILABLE'` vehicles in
  the chosen category at the chosen branch with no date overlap against
  existing bookings (server validates this regardless of what the UI shows,
  to handle race conditions between two agents booking simultaneously).
- **Confirm Booking** is disabled until a specific vehicle is assigned
  (booking can be saved as Quote without one, but not confirmed).
- On **Confirm Booking**: status → `CONFIRMED`, fires `BOOKING_CONFIRMED`
  event (SMS sent, rental agreement generated per automation rule), and
  for Weekly/Monthly mode, generates the full set of `booking_installment` rows.

## Screen 3: Dispatch Inspection (Tablet-friendly, used at vehicle handover)

```
┌──────────────────────────────────────────────────────────────────────┐
│  Dispatch — Booking NBO-BK-00121 — Toyota Axio KDA 123A                │
├──────────────────────────────────────────────────────────────────────┤
│  Odometer Reading *        [ 84,210 ] km                               │
│  Fuel Level *               [▓▓▓▓▓▓▓▓░░] 80%                           │
│                                                                         │
│  ── Exterior Condition ──  (tap a zone to flag damage)                 │
│        ┌──────────────────────────┐                                   │
│        │      [top-down car       │   Legend:                         │
│        │       diagram, tappable  │   ● No damage                     │
│        │       zones: front,      │   ● Scratch                       │
│        │       rear, L/R sides,   │   ● Dent                          │
│        │       roof, mirrors]     │   ● Crack/Break                   │
│        └──────────────────────────┘                                   │
│                                                                         │
│  ── Accessories Checklist ──                                           │
│  ☑ Spare tyre   ☑ Jack   ☑ Wheel spanner   ☑ Warning triangle          │
│  ☑ Fire extinguisher   ☑ First aid kit   ☑ Floor mats (4)              │
│                                                                         │
│  Interior Notes  [______________________________________________]      │
│  Photos          [📷 Add Photo] (min. 4 recommended: front/back/L/R)   │
│                                                                         │
│  ── Signatures ──                                                       │
│  Customer Signature   [  sign here  ]                                   │
│  Staff Signature       [  sign here  ]      Dispatch Officer: John D.   │
│                                                                           │
│  [Cancel]                                          [Complete Dispatch]   │
└──────────────────────────────────────────────────────────────────────┘
```

### Behavior
- **Complete Dispatch** is disabled until: odometer entered, fuel level set,
  at least one signature pair captured, and ≥1 photo attached (configurable
  minimum via `system_setting`).
- Tapping a damage zone opens a small popup to select damage type and add a
  note/photo for that specific zone; stored in `exterior_condition_json` as
  `[{zone: 'front_bumper', type: 'scratch', note: '...', photo_url: '...'}]`.
- On submit: creates `vehicle_inspection` (`inspection_type='DISPATCH'`),
  updates `vehicle.status = 'RENTED'`, `vehicle.odometer_km`, and
  `booking.status = 'DISPATCHED'` → `'ACTIVE'`. Triggers `BOOKING_DISPATCHED`
  event (SMS to customer with pickup confirmation if not already sent).

## Screen 4: Return Inspection

Same layout as Dispatch, with one addition at the top:

```
┌──────────────────────────────────────────────────────────────────────┐
│  Return — Booking NBO-BK-00121 — Toyota Axio KDA 123A                  │
│  ⚠ Comparing against Dispatch Inspection (24 Jun, 09:05)               │
├──────────────────────────────────────────────────────────────────────┤
│  Odometer Reading *        [ 84,545 ] km     (+335 km this rental)     │
│  Fuel Level *               [▓▓▓▓▓░░░░░] 50%  (Dispatched at 80% — ⚠   │
│                                                 shortfall: 30%)         │
│  ...same condition diagram, pre-loaded with dispatch-time markers      │
│      greyed out, new damage marked in red...                          │
└──────────────────────────────────────────────────────────────────────┘
```

### Behavior
- System auto-computes **mileage used** and **fuel shortfall** by diffing
  against the linked DISPATCH inspection, and **pre-calculates** the
  corresponding `booking_extra_charge` line items (excess mileage, fuel
  shortfall) for staff to review/confirm before they post — never silently
  auto-bills without a staff review step on this screen.
- New damage zones tapped during Return that weren't present at Dispatch are
  highlighted distinctly and prompt: "This appears to be new damage — add to
  invoice?" with a Yes/No per item, feeding `booking_extra_charge (charge_type='DAMAGE')`.
- A summary panel appears before final submit:

```
  ── Charges to be Added ──────────────────────────
  Excess Mileage (35 km over allowance × 15)   KES 525.00
  Fuel Shortfall (30% × rate)                  KES 1,800.00
  Damage — rear bumper scratch                 KES 3,500.00
  ──────────────────────────────────────────────────
  Total Extra Charges                          KES 5,825.00

  [Edit Charges]                    [Confirm Return & Generate Invoice]
```

- On confirm: `vehicle.status → 'AVAILABLE'`, `booking.status → 'RETURNED'`
  (then `'COMPLETED'` once final invoice is paid), security deposit
  reconciliation triggered (`security_deposit_amount - extra_charges`,
  refund or forfeiture per Clause 8 of the agreement), and a final invoice
  is generated covering any extra charges.
