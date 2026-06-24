# Automation Rules Engine

## Design

`automation_rule` rows are evaluated by a generic **trigger → condition →
action** pipeline. Admins create/edit rules from a UI screen (see
`ui-specs/06-automation-rules-screen.md`); no deploy required to add or
change a rule.

```
TRIGGER (when to check)  →  CONDITIONS (must all/any pass)  →  ACTIONS (what happens)
```

### Trigger types

Triggers fall into two families:

1. **Scheduled/polling triggers** — a cron job scans for entities matching a
   time-relative condition (e.g. "installment due in 3 days"). Run hourly.
2. **Event triggers** — fired synchronously when a domain event occurs
   (e.g. `BOOKING_CONFIRMED`, `PAYMENT_RECEIVED`). The relevant service emits
   the event; the Rule Engine listens and evaluates matching rules instantly.

| trigger_event | Family | Fires when |
|---|---|---|
| `BOOKING_CONFIRMED` | Event | `booking.status` → `CONFIRMED` |
| `BOOKING_DISPATCHED` | Event | dispatch inspection completed |
| `BOOKING_RETURNED` | Event | return inspection completed |
| `BOOKING_INSTALLMENT_DUE_SOON` | Scheduled | `booking_installment.due_date - today = trigger_offset` |
| `BOOKING_INSTALLMENT_OVERDUE` | Scheduled | `due_date < today` and `status NOT IN ('PAID','WAIVED')`, past grace period |
| `PAYMENT_RECEIVED` | Event | new `payment` row inserted |
| `INVOICE_OVERDUE` | Scheduled | `invoice.due_date < today` and unpaid |
| `VEHICLE_DOC_EXPIRING` | Scheduled | `vehicle_document.expiry_date - today = trigger_offset` |
| `INSURANCE_EXPIRING` | Scheduled | `insurance_policy.end_date - today = trigger_offset` |
| `MAINTENANCE_DUE` | Scheduled | vehicle's odometer/days since last service reaches `maintenance_schedule_template` interval |
| `LEAD_NO_CONTACT` | Scheduled | `lead.created_at` or last `lead_activity` older than `trigger_offset` and stage not Won/Lost |
| `PAYOUT_CALCULATED` | Event | `investor_payout_run.status` → `CALCULATED` |
| `PAYOUT_DISBURSEMENT_FAILED` | Event | M-Pesa B2C / bank transfer fails |
| `BOOKING_RETURN_OVERDUE` | Scheduled | `end_datetime` passed, vehicle not yet returned |
| `CUSTOMER_BLACKLIST_FLAGGED` | Event | `customer_profile.blacklisted` → TRUE |

### Condition evaluation

`conditions_json` is an array of condition groups, evaluated as **AND across
the top-level array, OR within a nested array**:

```json
[
  { "field": "booking.status", "op": "=", "value": "ACTIVE" },
  { "field": "booking.rental_mode", "op": "in", "value": ["WEEKLY", "MONTHLY"] },
  [
    { "field": "customer.blacklisted", "op": "=", "value": false },
    { "field": "booking.booking_source", "op": "=", "value": "CORPORATE" }
  ]
]
```
Reads as: `status = ACTIVE AND rental_mode IN (...) AND (NOT blacklisted OR source = CORPORATE)`.

Supported `op` values: `=`, `!=`, `>`, `<`, `>=`, `<=`, `in`, `not_in`,
`contains`, `is_null`, `is_not_null`.

### Action types

```json
[
  { "type": "SEND_SMS", "template_code": "INSTALLMENT_DUE_REMINDER_SMS", "to": "customer.phone" },
  { "type": "SEND_EMAIL", "template_code": "INVOICE_EMAIL", "to": "customer.email" },
  { "type": "CREATE_TASK", "title": "Follow up: overdue lease {{booking_no}}", "assign_to": "branch_manager" },
  { "type": "CHANGE_STATUS", "entity": "booking_installment", "field": "status", "value": "OVERDUE" },
  { "type": "APPLY_LATE_FEE", "percent_setting_key": "LATE_FEE_PERCENT" },
  { "type": "WEBHOOK", "url": "https://...", "method": "POST" },
  { "type": "NOTIFY_ROLE", "role": "BRANCH_MANAGER", "channel": "EMAIL", "template_code": "..." }
]
```

### Idempotency

`automation_rule_execution_log` has a unique index on
`(automation_rule_id, related_entity_type, related_entity_id) WHERE matched = TRUE`
— a scheduled trigger that runs hourly will see the same overdue installment
every hour, but the rule only *fires* (executes actions) once per entity per
rule. To allow a rule to repeat (e.g. "remind again every 2 days while still
overdue"), the rule definition includes `repeat_interval_days` in
`trigger_offset_json`, and the engine checks the **last** matching log entry's
`executed_at` against that interval rather than blocking forever.

### Evaluation engine (NestJS)

```typescript
@Injectable()
export class AutomationRuleEngine {
  async evaluateScheduledRules(): Promise<void> {
    const rules = await this.ruleRepo.find({ where: { isActive: true } });
    for (const rule of rules.sort((a, b) => a.priority - b.priority)) {
      if (!this.isScheduledTrigger(rule.triggerEvent)) continue;
      const candidates = await this.findCandidateEntities(rule); // query per trigger_event type
      for (const entity of candidates) {
        if (await this.alreadyFiredRecently(rule, entity)) continue;
        const passed = this.evaluateConditions(rule.conditionsJson, entity);
        await this.logExecution(rule, entity, passed);
        if (passed) await this.executeActions(rule.actionsJson, entity);
      }
    }
  }

  // Called synchronously by domain services on event emission
  async handleEvent(eventName: string, entity: any): Promise<void> {
    const rules = await this.ruleRepo.find({
      where: { triggerEvent: eventName, isActive: true },
      order: { priority: 'ASC' },
    });
    for (const rule of rules) {
      const passed = this.evaluateConditions(rule.conditionsJson, entity);
      await this.logExecution(rule, entity, passed);
      if (passed) await this.executeActions(rule.actionsJson, entity);
    }
  }

  private evaluateConditions(conditions: any[], entity: any): boolean {
    return conditions.every(cond =>
      Array.isArray(cond)
        ? cond.some(sub => this.evaluateSingleCondition(sub, entity))
        : this.evaluateSingleCondition(cond, entity)
    );
  }

  private evaluateSingleCondition(cond: any, entity: any): boolean {
    const actual = resolveFieldPath(entity, cond.field); // dot-path resolver, e.g. "booking.status"
    switch (cond.op) {
      case '=': return actual === cond.value;
      case '!=': return actual !== cond.value;
      case '>': return actual > cond.value;
      case '<': return actual < cond.value;
      case '>=': return actual >= cond.value;
      case '<=': return actual <= cond.value;
      case 'in': return cond.value.includes(actual);
      case 'not_in': return !cond.value.includes(actual);
      case 'contains': return String(actual).includes(cond.value);
      case 'is_null': return actual === null || actual === undefined;
      case 'is_not_null': return actual !== null && actual !== undefined;
      default: throw new Error(`Unsupported operator: ${cond.op}`);
    }
  }

  private async executeActions(actions: any[], entity: any): Promise<void> {
    for (const action of actions) {
      switch (action.type) {
        case 'SEND_SMS':
          await this.smsService.sendFromTemplate(action.template_code, entity, resolveFieldPath(entity, action.to));
          break;
        case 'SEND_EMAIL':
          await this.emailService.sendFromTemplate(action.template_code, entity, resolveFieldPath(entity, action.to));
          break;
        case 'CREATE_TASK':
          await this.taskService.create({ ...action, relatedEntity: entity });
          break;
        case 'CHANGE_STATUS':
          await this.genericUpdateService.setField(action.entity, entity.id, action.field, action.value);
          break;
        case 'APPLY_LATE_FEE':
          await this.billingService.applyLateFee(entity, await this.settings.get(action.percent_setting_key));
          break;
        case 'NOTIFY_ROLE':
          await this.notifyRoleService.notify(action.role, action.channel, action.template_code, entity);
          break;
        case 'WEBHOOK':
          await this.httpService.post(action.url, entity).toPromise();
          break;
      }
    }
  }
}
```

## Seed Rule Library

These are inserted as `automation_rule` rows (illustrative `INSERT` shown for
the first one; the rest follow the same shape — see `02-seed-data.sql` for
how to extend it with these).

```sql
INSERT INTO automation_rule (name, trigger_event, trigger_offset_json, conditions_json, actions_json) VALUES

('Lease installment due reminder (3 days before)',
 'BOOKING_INSTALLMENT_DUE_SOON',
 '{"unit": "days", "value": 3}',
 '[{"field": "booking_installment.status", "op": "in", "value": ["PENDING", "PARTIAL"]}]',
 '[{"type": "SEND_SMS", "template_code": "INSTALLMENT_DUE_REMINDER_SMS", "to": "customer.phone"}]'
),

('Lease installment overdue — first notice',
 'BOOKING_INSTALLMENT_OVERDUE',
 '{"unit": "days", "value": 0, "repeat_interval_days": 2}',
 '[{"field": "booking_installment.status", "op": "!=", "value": "PAID"}]',
 '[{"type": "SEND_SMS", "template_code": "INSTALLMENT_OVERDUE_SMS", "to": "customer.phone"},
   {"type": "APPLY_LATE_FEE", "percent_setting_key": "LATE_FEE_PERCENT"},
   {"type": "CHANGE_STATUS", "entity": "booking_installment", "field": "status", "value": "OVERDUE"}]'
),

('Escalate to manager — lease 7+ days overdue',
 'BOOKING_INSTALLMENT_OVERDUE',
 '{"unit": "days", "value": 7}',
 '[{"field": "booking_installment.status", "op": "=", "value": "OVERDUE"}]',
 '[{"type": "CREATE_TASK", "title": "URGENT: Lease {{booking_no}} overdue 7+ days — consider repossession", "assign_to": "branch_manager"},
   {"type": "NOTIFY_ROLE", "role": "BRANCH_MANAGER", "channel": "EMAIL", "template_code": "LEASE_ESCALATION_EMAIL"}]'
),

('Vehicle document expiring in 30 days',
 'VEHICLE_DOC_EXPIRING',
 '{"unit": "days", "value": -30}',
 '[]',
 '[{"type": "SEND_SMS", "template_code": "VEHICLE_DOC_EXPIRING_STAFF_SMS", "to": "fleet_officer.phone"},
   {"type": "CREATE_TASK", "title": "Renew {{document_type}} for {{registration_no}}", "assign_to": "fleet_officer"}]'
),

('Insurance expiring in 14 days',
 'INSURANCE_EXPIRING',
 '{"unit": "days", "value": -14}',
 '[{"field": "insurance_policy.status", "op": "=", "value": "ACTIVE"}]',
 '[{"type": "CREATE_TASK", "title": "Renew insurance policy {{policy_no}} for {{registration_no}}", "assign_to": "branch_manager"},
   {"type": "SEND_EMAIL", "template_code": "INSURANCE_EXPIRING_EMAIL", "to": "branch_manager.email"}]'
),

('Booking confirmed — send confirmation SMS + generate agreement',
 'BOOKING_CONFIRMED',
 NULL,
 '[]',
 '[{"type": "SEND_SMS", "template_code": "BOOKING_CONFIRMED_SMS", "to": "customer.phone"},
   {"type": "WEBHOOK", "url": "internal://generate-rental-agreement"}]'
),

('Payment received — send receipt SMS',
 'PAYMENT_RECEIVED',
 NULL,
 '[]',
 '[{"type": "SEND_SMS", "template_code": "PAYMENT_RECEIVED_SMS", "to": "customer.phone"}]'
),

('Lead not contacted within 24 hours',
 'LEAD_NO_CONTACT',
 '{"unit": "hours", "value": 24}',
 '[{"field": "lead.pipeline_stage.name", "op": "=", "value": "New"}]',
 '[{"type": "CREATE_TASK", "title": "Contact lead {{full_name}} ({{phone}}) — no contact in 24h", "assign_to": "assigned_agent"},
   {"type": "NOTIFY_ROLE", "role": "BRANCH_MANAGER", "channel": "EMAIL", "template_code": "LEAD_STALE_EMAIL"}]'
),

('Investor payout calculated — notify investor',
 'PAYOUT_CALCULATED',
 NULL,
 '[]',
 '[{"type": "SEND_SMS", "template_code": "INVESTOR_PAYOUT_PROCESSING_SMS", "to": "investor.phone"}]'
),

('Payout disbursement failed — alert accountant',
 'PAYOUT_DISBURSEMENT_FAILED',
 NULL,
 '[]',
 '[{"type": "CREATE_TASK", "title": "Payout FAILED for {{vehicle_registration_no}} — {{failure_reason}}", "assign_to": "accountant"},
   {"type": "NOTIFY_ROLE", "role": "ACCOUNTANT", "channel": "EMAIL", "template_code": "PAYOUT_FAILED_EMAIL"}]'
),

('Vehicle not returned by end of booking',
 'BOOKING_RETURN_OVERDUE',
 '{"unit": "hours", "value": 2}',
 '[{"field": "booking.status", "op": "=", "value": "ACTIVE"}]',
 '[{"type": "SEND_SMS", "template_code": "RETURN_OVERDUE_CUSTOMER_SMS", "to": "customer.phone"},
   {"type": "CREATE_TASK", "title": "Vehicle {{registration_no}} overdue for return — booking {{booking_no}}", "assign_to": "dispatch_officer"}]'
),

('Maintenance due by mileage or time',
 'MAINTENANCE_DUE',
 '{"unit": "km_or_days", "value": 0}',
 '[]',
 '[{"type": "CREATE_TASK", "title": "Schedule service for {{registration_no}} ({{schedule_name}})", "assign_to": "workshop_supervisor"},
   {"type": "CHANGE_STATUS", "entity": "vehicle", "field": "status", "value": "IN_SERVICE"}]'
);
```

## Why this satisfies "admin-customizable for all of the above"

- **New reminder cadence?** Edit `trigger_offset_json.value` — no deploy.
- **New channel preference?** Add a `SEND_EMAIL` action alongside/instead of `SEND_SMS`.
- **New role to notify?** `NOTIFY_ROLE` resolves the role dynamically — works
  for any role created later via the RBAC screens, including custom ones.
- **Branch-specific behavior?** Set `automation_rule.branch_id` to scope a
  rule to one branch (e.g. Mombasa wants a 5-day grace period, Nairobi wants 2)
  — the global NULL-branch rule still applies everywhere else.
- **Disable without deleting?** `is_active = false` — preserves the rule and
  its execution history for re-enabling later.
