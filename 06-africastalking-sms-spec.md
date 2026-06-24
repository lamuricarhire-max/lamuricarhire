# Africa's Talking SMS Integration Spec

## Scope

Outbound SMS for: booking confirmations, dispatch-ready alerts, lease
installment reminders/overdue notices, payment receipts, investor payout
notifications, staff alerts (document expiry, escalations), and CRM lead
follow-up nudges (to staff) / campaign blasts (to customers/leads).

Optional: inbound SMS handling (e.g. customer replies "STOP" to opt out, or
a short-code keyword flow) and Delivery Reports.

## Credentials & config

| Setting key | Description |
|---|---|
| `AT_API_KEY` | Africa's Talking API key |
| `AT_USERNAME` | AT account username (`sandbox` for testing) |
| `SMS_SENDER_ID` | Registered short code / alphanumeric sender ID (e.g. `LAMURI`) |
| `AT_ENV` | `sandbox` \| `production` |

Sandbox base URL: `https://api.sandbox.africastalking.com/version1/messaging`
Production base URL: `https://api.africastalking.com/version1/messaging`

## 1. Sending SMS

### Request

```
POST {base_url}
Content-Type: application/x-www-form-urlencoded
Accept: application/json
apiKey: {{AT_API_KEY}}

username={{AT_USERNAME}}&to={{phone_e164_csv}}&message={{message_body}}&from={{SMS_SENDER_ID}}
```

```typescript
@Injectable()
export class AfricasTalkingSmsService {
  constructor(
    private readonly http: HttpService,
    private readonly config: SmsConfigService,
    private readonly smsLogRepo: Repository<SmsLog>,
    private readonly templateService: MessageTemplateService,
  ) {}

  async sendFromTemplate(
    templateCode: string,
    entity: Record<string, any>,
    recipientPhone: string,
    relatedEntityType?: string,
    relatedEntityId?: string,
  ): Promise<void> {
    const template = await this.templateService.resolve(templateCode, 'SMS', entity.branchId);
    const body = renderTemplate(template.bodyTemplate, flattenEntityForTemplate(entity));
    await this.send(recipientPhone, body, { relatedEntityType, relatedEntityId, templateId: template.id });
  }

  async send(
    phone: string,
    message: string,
    meta: { relatedEntityType?: string; relatedEntityId?: string; templateId?: number } = {},
  ): Promise<void> {
    const normalizedPhone = normalizeToE164Plus(phone); // AT wants '+2547XXXXXXXX'
    const logEntry = await this.smsLogRepo.save({
      recipientPhone: normalizedPhone,
      messageBody: message,
      messageTemplateId: meta.templateId,
      relatedEntityType: meta.relatedEntityType,
      relatedEntityId: meta.relatedEntityId,
      status: 'QUEUED',
    });

    try {
      const params = new URLSearchParams({
        username: this.config.username,
        to: normalizedPhone,
        message,
        from: this.config.senderId,
      });
      const { data } = await this.http.post(this.config.baseUrl, params.toString(), {
        headers: {
          apiKey: this.config.apiKey,
          'Content-Type': 'application/x-www-form-urlencoded',
          Accept: 'application/json',
        },
      });

      const recipient = data.SMSMessageData.Recipients[0];
      // recipient: { number, cost, status, statusCode, messageId }
      await this.smsLogRepo.update(logEntry.id, {
        status: recipient.statusCode === 101 ? 'SENT' : 'FAILED',
        providerMessageId: recipient.messageId,
        costAmount: parseCost(recipient.cost), // "KES 0.8000" -> 0.8
        failureReason: recipient.statusCode !== 101 ? recipient.status : null,
        sentAt: new Date(),
      });
    } catch (err) {
      await this.smsLogRepo.update(logEntry.id, { status: 'FAILED', failureReason: err.message });
      throw err; // let calling job's retry/backoff policy handle it
    }
  }

  async sendBulk(recipients: string[], message: string): Promise<void> {
    // AT accepts comma-separated `to` for bulk in one call; for large
    // campaigns (>500), chunk into batches to stay under provider limits.
    const chunks = chunkArray(recipients, 500);
    for (const chunk of chunks) {
      await this.send(chunk.join(','), message);
    }
  }
}
```

### Response shape

```json
{
  "SMSMessageData": {
    "Message": "Sent to 1/1 Total Cost: KES 0.8000",
    "Recipients": [
      {
        "statusCode": 101,
        "number": "+254712345678",
        "status": "Success",
        "cost": "KES 0.8000",
        "messageId": "ATXid_xxxxxxxxxxxxx"
      }
    ]
  }
}
```

| statusCode | Meaning |
|---|---|
| 100 | Processed |
| 101 | Sent |
| 102 | Queued |
| 401 | Risk Hold |
| 402 | Invalid Sender ID |
| 403 | Invalid Phone Number |
| 404 | Unsupported Number Type |
| 405 | Insufficient Balance |
| 406 | User In Blacklist |
| 407 | Could Not Route |
| 500 | Internal Server Error |
| 501 | Gateway Error |
| 502 | Rejected By Gateway |

Statuses other than `100`/`101`/`102` are treated as `FAILED` and surfaced
to `sms_log.failure_reason`; `405 Insufficient Balance` specifically should
trigger an immediate high-priority alert to the Super Admin (SMS float
top-up needed) — wire this as its own automation rule
(`SMS_PROVIDER_LOW_BALANCE`).

## 2. Delivery Reports (optional, recommended for production)

Register a callback URL in the AT dashboard. AT POSTs delivery status
updates after the initial send response:

```
POST {AT_CALLBACK_BASE_URL}/sms/delivery-report
id={{messageId}}&status={{status}}&phoneNumber={{phone}}&networkCode={{code}}&failureReason={{reason}}
```

```typescript
@Post('sms/delivery-report')
async handleDeliveryReport(@Body() body: any) {
  const log = await this.smsLogRepo.findByProviderMessageId(body.id);
  if (log) {
    await this.smsLogRepo.update(log.id, {
      status: body.status === 'Success' ? 'DELIVERED' : 'FAILED',
      deliveredAt: body.status === 'Success' ? new Date() : null,
      failureReason: body.status !== 'Success' ? body.failureReason : null,
    });
  }
  return { status: 'ok' };
}
```

## 3. Inbound SMS (optional — e.g. STOP/opt-out, or USSD-like keyword replies)

Register an inbound callback URL on the AT shortcode:

```typescript
@Post('sms/inbound')
async handleInboundSms(@Body() body: any) {
  // body: { from, to, text, date, id, linkId }
  const text = body.text.trim().toUpperCase();
  if (text === 'STOP') {
    await this.userRepo.updateByPhone(body.from, { smsOptOut: true });
  }
  // Extend here for keyword-based self-service (e.g. "BAL" -> balance check reply)
  return { status: 'ok' };
}
```

> Note: `app_user` doesn't currently have an `sms_opt_out` column in the core
> schema — add one (`ALTER TABLE app_user ADD COLUMN sms_opt_out BOOLEAN NOT NULL DEFAULT FALSE;`)
> if opt-out handling is required; the Rule Engine's `SEND_SMS` action should
> check this flag before sending.

## 4. Campaign sending (CRM bulk SMS)

```typescript
@Injectable()
export class CampaignSenderService {
  async sendCampaign(campaignId: number): Promise<void> {
    const campaign = await this.campaignRepo.findOne(campaignId, { relations: ['template'] });
    const recipients = await this.resolveSegment(campaign.targetSegmentJson); // builds query from filter JSON
    await this.campaignRepo.update(campaignId, { status: 'SENDING' });

    for (const recipient of recipients) {
      const body = renderTemplate(campaign.template.bodyTemplate, recipient);
      try {
        await this.smsService.send(recipient.phone, body, {
          relatedEntityType: 'campaign', relatedEntityId: String(campaignId),
        });
        await this.campaignRecipientRepo.update(
          { campaignId, userId: recipient.userId }, { status: 'SENT', sentAt: new Date() },
        );
      } catch {
        await this.campaignRecipientRepo.update(
          { campaignId, userId: recipient.userId }, { status: 'FAILED' },
        );
      }
    }
    await this.campaignRepo.update(campaignId, { status: 'COMPLETED' });
  }
}
```

Rate-limit campaign sends (e.g. via BullMQ rate limiter at N messages/second)
to stay within AT's throughput limits and avoid carrier spam flags.

## 5. Message length & cost awareness

- Standard SMS = 160 characters (GSM-7 charset) per segment; messages with
  special/unicode characters drop to 70 chars/segment (UCS-2). Keep templates
  ASCII where possible — `message_template.body_template` previews should
  show **segment count** in the admin UI so staff see cost impact before
  saving a template.
- `sms_log.cost_amount` accumulates per send — feed into a daily SMS spend
  report and post to `chart_of_account` code `5400` (SMS & Communication
  Expense) via the Finance Posting Service for automated accounting.

## Phone number normalization (AT-specific)

Africa's Talking expects **`+`-prefixed** E.164 (`+2547XXXXXXXX`), unlike
M-Pesa which wants no `+`. Keep these as two distinct normalizer functions
rather than one shared one, to avoid a class of provider-mismatch bugs:

```typescript
function normalizeToE164Plus(phone: string): string {
  let p = phone.replace(/\s+/g, '');
  if (p.startsWith('0')) p = '+254' + p.slice(1);
  else if (!p.startsWith('+')) p = '+254' + p.replace(/^254/, '');
  return p;
}
```
