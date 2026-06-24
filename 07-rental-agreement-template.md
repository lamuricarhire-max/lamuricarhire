# Rental Agreement Template (Merge-Ready)

Stored in `document_template` where `document_type = 'RENTAL_AGREEMENT'`.
`body_template` is the HTML below; the Document Merge Engine replaces every
`{{placeholder}}` with live data from `booking`, `vehicle`, `customer_profile`,
`rate_plan`, and `branch` at the moment the agreement is generated, then
freezes the rendered result into `rental_agreement.rendered_content_html`
(so later rate or T&C changes never retroactively alter a signed agreement).

This is written for Kenyan operating context (KRA PIN, NTSA/traffic law
references, KES) but every clause number, fee, and threshold is a variable
an admin can edit in the template editor — nothing below is hardcoded into
application code.

---

```html
<div class="agreement">

  <header>
    <img src="{{branch_logo_url}}" alt="LAMURI Car Hire" />
    <h1>VEHICLE RENTAL AGREEMENT</h1>
    <p>Agreement No: <strong>{{agreement_no}}</strong> &nbsp;|&nbsp;
       Date: {{agreement_date}} &nbsp;|&nbsp; Branch: {{branch_name}}</p>
  </header>

  <section id="parties">
    <h2>1. PARTIES</h2>
    <p>
      This Agreement is made between <strong>{{company_legal_name}}</strong>
      ("the Company"), of {{branch_address}}, KRA PIN {{company_kra_pin}},
      and:
    </p>
    <table class="parties-table">
      <tr><td>Customer Name</td><td>{{customer_full_name}}</td></tr>
      <tr><td>ID/Passport No.</td><td>{{customer_id_no}}</td></tr>
      <tr><td>Driving License No.</td><td>{{customer_license_no}} (Exp: {{customer_license_expiry}})</td></tr>
      <tr><td>Phone</td><td>{{customer_phone}}</td></tr>
      <tr><td>Email</td><td>{{customer_email}}</td></tr>
      {{#if customer_is_corporate}}
      <tr><td>Company Name</td><td>{{customer_company_name}}</td></tr>
      <tr><td>Company KRA PIN</td><td>{{customer_company_kra_pin}}</td></tr>
      {{/if}}
    </table>
    <p>("the Customer", together with the Company, "the Parties").</p>
  </section>

  <section id="vehicle-details">
    <h2>2. VEHICLE DETAILS</h2>
    <table class="vehicle-table">
      <tr><td>Make / Model</td><td>{{vehicle_make}} {{vehicle_model}} ({{vehicle_year}})</td></tr>
      <tr><td>Registration No.</td><td>{{vehicle_registration_no}}</td></tr>
      <tr><td>Color</td><td>{{vehicle_color}}</td></tr>
      <tr><td>Odometer at Handover</td><td>{{odometer_at_dispatch}} km</td></tr>
      <tr><td>Fuel Level at Handover</td><td>{{fuel_level_at_dispatch}}%</td></tr>
    </table>
  </section>

  <section id="rental-period">
    <h2>3. RENTAL PERIOD &amp; RATE</h2>
    <table class="rental-table">
      <tr><td>Rental Mode</td><td>{{rental_mode}}</td></tr>
      <tr><td>Start</td><td>{{start_datetime}}</td></tr>
      <tr><td>End</td><td>{{end_datetime}}</td></tr>
      <tr><td>Rate</td><td>{{currency_code}} {{rate_amount}} per {{rate_unit_label}}</td></tr>
      {{#if mileage_limit_per_period}}
      <tr><td>Mileage Allowance</td><td>{{mileage_limit_per_period}} km per {{rate_unit_label}}; excess billed at {{currency_code}} {{excess_mileage_rate}}/km</td></tr>
      {{/if}}
      <tr><td>Total Rental Charge</td><td>{{currency_code}} {{base_amount}}</td></tr>
      <tr><td>Security Deposit</td><td>{{currency_code}} {{security_deposit_amount}} (refundable, see Clause 8)</td></tr>
    </table>

    {{#if is_installment_lease}}
    <p><strong>Payment Schedule (Weekly/Monthly Lease):</strong></p>
    <table class="installments-table">
      <thead><tr><th>#</th><th>Period</th><th>Amount Due</th><th>Due Date</th></tr></thead>
      <tbody>
        {{#each installments}}
        <tr><td>{{installment_no}}</td><td>{{period_start}} – {{period_end}}</td>
            <td>{{currency_code}} {{amount_due}}</td><td>{{due_date}}</td></tr>
        {{/each}}
      </tbody>
    </table>
    <p>Each installment is due in advance, on or before its listed due date.
       Late payments are subject to Clause 6 (Late Payment).</p>
    {{/if}}
  </section>

  <section id="use-of-vehicle">
    <h2>4. USE OF THE VEHICLE</h2>
    <ol>
      <li>The Customer shall use the Vehicle solely for lawful purposes and
          shall not use it for: hire or reward to third parties, instruction,
          towing, racing or speed-testing, transporting hazardous goods, or
          any purpose violating Kenyan traffic law (Traffic Act, Cap 403).</li>
      <li>The Vehicle shall not be driven outside Kenya without prior written
          consent from the Company and, where applicable, the vehicle owner.</li>
      <li>Only persons named on this Agreement as authorized drivers, holding
          a valid driving license, may operate the Vehicle. Additional driver
          fee: {{currency_code}} {{additional_driver_fee}} per additional
          authorized driver.</li>
      <li>The Customer must immediately notify the Company of any traffic
          offense, accident, theft, or mechanical fault, and must report any
          accident to the nearest police station within 24 hours.</li>
    </ol>
  </section>

  <section id="fuel-mileage">
    <h2>5. FUEL, MILEAGE &amp; CONDITION</h2>
    <ol>
      <li>The Vehicle is issued with {{fuel_level_at_dispatch}}% fuel and must
          be returned with the same level; shortfall is charged at
          {{currency_code}} {{fuel_shortfall_rate}}/% plus a refueling service
          fee of {{currency_code}} {{refueling_service_fee}}.</li>
      <li>The Customer accepts the Vehicle in the condition recorded on the
          Dispatch Inspection Form (Annex A), signed by both Parties at
          handover. Any damage not present at handover but found at return
          will be charged per Clause 7.</li>
    </ol>
  </section>

  <section id="late-payment">
    <h2>6. LATE RETURN &amp; LATE PAYMENT</h2>
    <ol>
      <li><strong>Late Return:</strong> A grace period of
          {{late_return_grace_minutes}} minutes applies. Beyond this, late
          return is charged at {{late_return_rate_multiplier}}x the
          applicable per-day rate for each additional day or part-day.</li>
      <li><strong>Late Payment (Lease/Installment bookings):</strong> Payments
          not received by their due date, after a grace period of
          {{grace_period_days}} day(s), attract a late fee of
          {{late_fee_percent}}% of the overdue installment amount. Continued
          non-payment beyond {{suspension_threshold_days}} days entitles the
          Company to suspend the rental and repossess the Vehicle, without
          prejudice to amounts already owed.</li>
    </ol>
  </section>

  <section id="damage-liability">
    <h2>7. DAMAGE, LOSS &amp; INSURANCE</h2>
    <ol>
      <li>The Vehicle is insured under Policy No. {{insurance_policy_no}}
          ({{insurance_cover_type}}) with {{insurer_name}}.</li>
      <li>The Customer is liable for an excess of up to
          {{currency_code}} {{insurance_excess_amount}} per incident in the
          event of an accident, theft, or damage, regardless of fault,
          except where the Company's own negligence is established.</li>
      <li>The Customer shall bear full repair/replacement cost for damage
          arising from: driving under the influence of alcohol or drugs,
          driving without a valid license, use outside permitted purposes
          (Clause 4), off-road use unless explicitly authorized, or any
          breach of this Agreement — in which case the insurance excess cap
          in 7.2 does not apply.</li>
      <li>Traffic fines, parking fines, and toll charges incurred during the
          rental period are the sole responsibility of the Customer and will
          be billed with a {{currency_code}} {{admin_fee_traffic_fine}}
          administration fee per incident.</li>
    </ol>
  </section>

  <section id="security-deposit">
    <h2>8. SECURITY DEPOSIT</h2>
    <ol>
      <li>The security deposit of {{currency_code}} {{security_deposit_amount}}
          is held against damage, fuel shortfall, traffic fines, excess
          mileage, late fees, or other charges arising under this Agreement.</li>
      <li>The deposit (less any deductions under this Agreement) is
          refundable within {{deposit_refund_days}} business days of the
          Vehicle's return and inspection sign-off.</li>
    </ol>
  </section>

  <section id="termination">
    <h2>9. TERMINATION</h2>
    <ol>
      <li>The Company may terminate this Agreement immediately and
          repossess the Vehicle, without refund of charges already accrued,
          if the Customer breaches any material term, including non-payment
          beyond the threshold in Clause 6.2.</li>
      <li>Early termination by the Customer of a weekly/monthly lease before
          the end of the contracted term may attract an early-termination
          fee of {{currency_code}} {{early_termination_fee}} or forfeiture of
          the security deposit, whichever is specified in the Rate Plan.</li>
    </ol>
  </section>

  <section id="general">
    <h2>10. GENERAL</h2>
    <ol>
      <li>This Agreement is governed by the laws of the Republic of Kenya.
          Disputes shall first be referred to mediation, failing which to
          the courts of Kenya with jurisdiction.</li>
      <li>This Agreement, together with its Annexes (Dispatch Inspection
          Form, Return Inspection Form, and the Rate Plan referenced in
          Clause 3), constitutes the entire agreement between the Parties.</li>
      <li>Terms &amp; Conditions Version: {{terms_version}}</li>
    </ol>
  </section>

  <section id="signatures">
    <h2>SIGNATURES</h2>
    <table class="signature-table">
      <tr>
        <td>
          <p>For the Company:</p>
          <div class="signature-line"></div>
          <p>{{staff_witness_name}} — {{staff_witness_title}}</p>
          <p>Date: {{staff_signed_date}}</p>
        </td>
        <td>
          <p>The Customer:</p>
          <div class="signature-line"></div>
          <p>{{customer_full_name}}</p>
          <p>Date: {{customer_signed_date}}</p>
        </td>
      </tr>
    </table>
  </section>

</div>
```

---

## Variables Reference

| Placeholder | Source |
|---|---|
| `{{agreement_no}}`, `{{agreement_date}}` | `rental_agreement.agreement_no`, `created_at` |
| `{{branch_name}}`, `{{branch_address}}`, `{{branch_logo_url}}` | `branch` |
| `{{company_legal_name}}`, `{{company_kra_pin}}` | global `system_setting` |
| `{{customer_*}}` | `app_user` + `customer_profile` joined on `booking.customer_user_id` |
| `{{vehicle_*}}` | `vehicle` joined on `booking.vehicle_id` |
| `{{odometer_at_dispatch}}`, `{{fuel_level_at_dispatch}}` | `vehicle_inspection` where `inspection_type='DISPATCH'` |
| `{{rate_amount}}`, `{{rate_unit_label}}`, `{{mileage_limit_per_period}}`, `{{excess_mileage_rate}}` | `rate_plan` |
| `{{installments}}` (array) | `booking_installment` rows for this booking, only rendered `{{#if is_installment_lease}}` when `rental_mode != 'DAILY'` |
| `{{late_fee_percent}}`, `{{grace_period_days}}` | `system_setting` (`LATE_FEE_PERCENT`, `GRACE_PERIOD_DAYS`) — same values the Automation Engine uses, so the contract text and the system's actual behavior never drift apart |
| `{{insurance_*}}` | `insurance_policy` active for the vehicle at booking start |
| `{{security_deposit_amount}}` | `booking.security_deposit_amount` |
| `{{terms_version}}` | `rental_agreement.terms_version` |

## Annexes (separate generated documents, referenced by this agreement)

- **Annex A — Dispatch Inspection Form**: rendered from `vehicle_inspection`
  (`inspection_type='DISPATCH'`), including the exterior damage diagram and
  accessory checklist, signed digitally by customer + dispatch officer.
- **Annex B — Return Inspection Form**: same structure, `inspection_type='RETURN'`,
  generated at vehicle return; any new damage drives `booking_extra_charge`.

## Implementation note: per-branch / per-category overrides

Because `document_template` is keyed on `(branch_id, document_type, version)`,
a branch operating in a different country (e.g. Uganda) can have its own
template referencing UGX, Ugandan traffic law citations, and local insurer
clauses — same engine, different data row. Admins create a new version
rather than editing in place, so agreements already signed under v1.0 remain
legible and accurate even after v1.1 changes clause wording.
