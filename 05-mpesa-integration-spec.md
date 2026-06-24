# M-Pesa Integration Spec (Safaricom Daraja API)

## Scope

Three M-Pesa flows are needed:

1. **STK Push (Lipa Na M-Pesa Online)** — customer pays an invoice from
   inside the app/web portal by entering their phone number; M-Pesa prompts
   them on their phone to enter PIN.
2. **C2B (Customer-to-Business via Paybill)** — customer pays directly via
   the Paybill number + Account Number (the booking/invoice number) without
   needing the app open; M-Pesa sends a server callback.
3. **B2C (Business-to-Customer)** — used for **investor payouts** —
   disbursing money from the company's M-Pesa account to the investor's
   phone number.

All three use Safaricom's Daraja API v2 (sandbox: `https://sandbox.safaricom.co.ke`,
production: `https://api.safaricom.co.ke`).

## Credentials & config (stored in `system_setting`, branch-scoped where relevant)

| Setting key | Description |
|---|---|
| `MPESA_CONSUMER_KEY` / `MPESA_CONSUMER_SECRET` | OAuth app credentials from Daraja portal |
| `MPESA_PAYBILL_NUMBER` (a.k.a. Shortcode) | Used for STK Push & C2B |
| `MPESA_PASSKEY` | Lipa Na M-Pesa Online passkey, used to build STK `Password` |
| `MPESA_B2C_SHORTCODE` | Often the same as Paybill, or a dedicated B2C shortcode |
| `MPESA_B2C_INITIATOR_NAME` | API operator username for B2C |
| `MPESA_B2C_SECURITY_CREDENTIAL` | Encrypted initiator password (RSA-encrypted with Safaricom's public cert) |
| `MPESA_CALLBACK_BASE_URL` | Public HTTPS base URL Safaricom calls back to |
| `MPESA_ENV` | `sandbox` \| `production` |

> **Never store the raw B2C initiator password.** Only the
> `SecurityCredential` (already RSA-encrypted per Safaricom's spec using
> their public certificate) is persisted.

## 1. Authentication (shared by all flows)

```
GET {base_url}/oauth/v1/generate?grant_type=client_credentials
Authorization: Basic base64(consumer_key:consumer_secret)

Response: { "access_token": "...", "expires_in": "3599" }
```

```typescript
@Injectable()
export class MpesaAuthService {
  private cachedToken: { token: string; expiresAt: number } | null = null;

  async getAccessToken(): Promise<string> {
    if (this.cachedToken && Date.now() < this.cachedToken.expiresAt) {
      return this.cachedToken.token;
    }
    const auth = Buffer.from(`${this.config.consumerKey}:${this.config.consumerSecret}`).toString('base64');
    const { data } = await this.http.get(`${this.config.baseUrl}/oauth/v1/generate?grant_type=client_credentials`, {
      headers: { Authorization: `Basic ${auth}` },
    });
    this.cachedToken = { token: data.access_token, expiresAt: Date.now() + (Number(data.expires_in) - 60) * 1000 };
    return this.cachedToken.token;
  }
}
```

Cache the token (valid ~1 hour) in Redis, refresh 60s before expiry.

## 2. STK Push (customer pays invoice from the app)

### Request

```
POST {base_url}/mpesa/stkpush/v1/processrequest
Authorization: Bearer {access_token}

{
  "BusinessShortCode": "{{paybill_number}}",
  "Password": "{{base64(shortcode + passkey + timestamp)}}",
  "Timestamp": "{{YYYYMMDDHHmmss}}",
  "TransactionType": "CustomerPayBillOnline",
  "Amount": "{{invoice_amount}}",
  "PartyA": "{{customer_phone_2547XXXXXXXX}}",
  "PartyB": "{{paybill_number}}",
  "PhoneNumber": "{{customer_phone_2547XXXXXXXX}}",
  "CallBackURL": "{{MPESA_CALLBACK_BASE_URL}}/mpesa/stk/callback",
  "AccountReference": "{{invoice_no}}",
  "TransactionDesc": "Payment for {{invoice_no}}"
}
```

```typescript
async initiateStkPush(invoice: Invoice, phoneNumber: string): Promise<StkPushResponse> {
  const timestamp = formatTimestamp(new Date()); // YYYYMMDDHHmmss
  const password = Buffer.from(
    `${this.config.paybillNumber}${this.config.passkey}${timestamp}`
  ).toString('base64');

  const token = await this.mpesaAuth.getAccessToken();
  const { data } = await this.http.post(
    `${this.config.baseUrl}/mpesa/stkpush/v1/processrequest`,
    {
      BusinessShortCode: this.config.paybillNumber,
      Password: password,
      Timestamp: timestamp,
      TransactionType: 'CustomerPayBillOnline',
      Amount: Math.round(invoice.totalAmount - invoice.amountPaid),
      PartyA: normalizeToE164(phoneNumber),       // 2547XXXXXXXX, no '+'
      PartyB: this.config.paybillNumber,
      PhoneNumber: normalizeToE164(phoneNumber),
      CallBackURL: `${this.config.callbackBaseUrl}/mpesa/stk/callback`,
      AccountReference: invoice.invoiceNo,
      TransactionDesc: `Payment for ${invoice.invoiceNo}`,
    },
    { headers: { Authorization: `Bearer ${token}` } },
  );

  // data: { MerchantRequestID, CheckoutRequestID, ResponseCode, ResponseDescription, CustomerMessage }
  await this.mpesaLogRepo.save({
    direction: 'STK_PUSH',
    merchantRequestId: data.MerchantRequestID,
    checkoutRequestId: data.CheckoutRequestID,
    phoneNumber, amount: invoice.totalAmount,
    rawPayload: data,
  });
  return data;
}
```

### Callback (Safaricom → our server)

```
POST {MPESA_CALLBACK_BASE_URL}/mpesa/stk/callback

{
  "Body": {
    "stkCallback": {
      "MerchantRequestID": "...",
      "CheckoutRequestID": "...",
      "ResultCode": 0,
      "ResultDesc": "The service request is processed successfully.",
      "CallbackMetadata": {
        "Item": [
          { "Name": "Amount", "Value": 1500 },
          { "Name": "MpesaReceiptNumber", "Value": "QGR7XXXX1A" },
          { "Name": "TransactionDate", "Value": 20260624153012 },
          { "Name": "PhoneNumber", "Value": 254712345678 }
        ]
      }
    }
  }
}
```

```typescript
@Post('mpesa/stk/callback')
async handleStkCallback(@Body() body: any): Promise<{ ResultCode: number; ResultDesc: string }> {
  const callback = body.Body.stkCallback;
  await this.mpesaLogRepo.save({ direction: 'STK_PUSH', rawPayload: body, resultCode: callback.ResultCode, resultDesc: callback.ResultDesc });

  if (callback.ResultCode === 0) {
    const meta = parseCallbackMetadata(callback.CallbackMetadata.Item);
    const invoice = await this.invoiceRepo.findByCheckoutRequestId(callback.CheckoutRequestID);
    const payment = await this.paymentService.recordPayment({
      invoiceId: invoice.id,
      amount: meta.Amount,
      paymentMethod: 'MPESA_STK',
      mpesaTransactionId: meta.MpesaReceiptNumber,
      paidAt: parseMpesaDate(meta.TransactionDate),
    });
    await this.automationEngine.handleEvent('PAYMENT_RECEIVED', payment);
    await this.numberingService.generateReceipt(payment); // PDF + sms/email per automation rule
  } else {
    // ResultCode != 0: user cancelled, insufficient funds, timeout, etc.
    await this.notifyStaff(`STK push failed for CheckoutRequestID ${callback.CheckoutRequestID}: ${callback.ResultDesc}`);
  }

  // MUST always return 200 + this exact shape, or Safaricom retries the callback
  return { ResultCode: 0, ResultDesc: 'Accepted' };
}
```

> **Critical:** Always respond `200 OK` with `{ ResultCode: 0, ResultDesc: "Accepted" }`
> to Safaricom's callback regardless of whether *our* processing succeeded —
> this acknowledges receipt of the webhook. Internal failures are handled by
> our own retry/alerting, not by making Safaricom retry the callback.

## 3. C2B (Paybill — customer pays without app, account ref = booking/invoice no.)

### One-time setup: register URLs

```
POST {base_url}/mpesa/c2b/v1/registerurl
{
  "ShortCode": "{{paybill_number}}",
  "ResponseType": "Completed",
  "ConfirmationURL": "{{MPESA_CALLBACK_BASE_URL}}/mpesa/c2b/confirmation",
  "ValidationURL": "{{MPESA_CALLBACK_BASE_URL}}/mpesa/c2b/validation"
}
```

### Validation callback (optional — only if ValidationURL is enabled on the shortcode)

Used to check the `BillRefNumber` (account number entered by customer)
actually matches a known invoice/booking before accepting payment:

```typescript
@Post('mpesa/c2b/validation')
async handleC2bValidation(@Body() body: any) {
  const invoice = await this.invoiceRepo.findByInvoiceNo(body.BillRefNumber);
  if (!invoice) {
    return { ResultCode: 'C2B00012', ResultDesc: 'Rejected - Invoice not found' };
  }
  return { ResultCode: '0', ResultDesc: 'Accepted' };
}
```

### Confirmation callback (payment actually happened — always fires)

```json
{
  "TransactionType": "Pay Bill",
  "TransID": "QGR7XXXX1A",
  "TransAmount": "1500.00",
  "BusinessShortCode": "600000",
  "BillRefNumber": "NBO-INV-000412",
  "MSISDN": "254712345678",
  "FirstName": "John"
}
```

```typescript
@Post('mpesa/c2b/confirmation')
async handleC2bConfirmation(@Body() body: any) {
  await this.mpesaLogRepo.save({ direction: 'C2B', rawPayload: body });

  const invoice = await this.invoiceRepo.findByInvoiceNo(body.BillRefNumber);
  if (invoice) {
    const payment = await this.paymentService.recordPayment({
      invoiceId: invoice.id,
      amount: Number(body.TransAmount),
      paymentMethod: 'MPESA_C2B',
      mpesaTransactionId: body.TransID,
      externalReference: body.MSISDN,
    });
    await this.automationEngine.handleEvent('PAYMENT_RECEIVED', payment);
  } else {
    // Unmatched payment — money received but no invoice reference matched.
    // Create an "unallocated payment" task for the accountant to reconcile manually.
    await this.taskService.create({
      title: `Unallocated M-Pesa payment ${body.TransID} - ref "${body.BillRefNumber}" - KES ${body.TransAmount}`,
      assignToRole: 'ACCOUNTANT',
    });
  }
  // C2B confirmation MUST be acknowledged this way regardless of outcome
  return { ResultCode: '0', ResultDesc: 'Success' };
}
```

## 4. B2C (Investor Payouts)

### Request

```
POST {base_url}/mpesa/b2c/v1/paymentrequest
Authorization: Bearer {access_token}

{
  "OriginatorConversationID": "{{uuid}}",
  "InitiatorName": "{{MPESA_B2C_INITIATOR_NAME}}",
  "SecurityCredential": "{{MPESA_B2C_SECURITY_CREDENTIAL}}",
  "CommandID": "BusinessPayment",
  "Amount": "{{net_payout_amount}}",
  "PartyA": "{{MPESA_B2C_SHORTCODE}}",
  "PartyB": "{{investor_phone_2547XXXXXXXX}}",
  "Remarks": "Payout {{vehicle_registration_no}} {{period_label}}",
  "QueueTimeOutURL": "{{MPESA_CALLBACK_BASE_URL}}/mpesa/b2c/timeout",
  "ResultURL": "{{MPESA_CALLBACK_BASE_URL}}/mpesa/b2c/result",
  "Occasion": "Investor Payout"
}
```

```typescript
async disburseInvestorPayout(payoutRun: InvestorPayoutRun): Promise<void> {
  const investor = await this.investorRepo.findByContractId(payoutRun.investorContractId);
  const token = await this.mpesaAuth.getAccessToken();

  const { data } = await this.http.post(
    `${this.config.baseUrl}/mpesa/b2c/v1/paymentrequest`,
    {
      OriginatorConversationID: uuidv4(),
      InitiatorName: this.config.b2cInitiatorName,
      SecurityCredential: this.config.b2cSecurityCredential,
      CommandID: 'BusinessPayment',
      Amount: Math.round(payoutRun.netPayoutAmount),
      PartyA: this.config.b2cShortcode,
      PartyB: normalizeToE164(investor.mpesaPayoutNumber),
      Remarks: `Payout ${payoutRun.vehicleRegistrationNo} ${payoutRun.periodLabel}`,
      QueueTimeOutURL: `${this.config.callbackBaseUrl}/mpesa/b2c/timeout`,
      ResultURL: `${this.config.callbackBaseUrl}/mpesa/b2c/result`,
      Occasion: 'Investor Payout',
    },
    { headers: { Authorization: `Bearer ${token}` } },
  );

  await this.mpesaLogRepo.save({
    direction: 'B2C', rawPayload: data, linkedPayoutRunId: payoutRun.id,
  });
  await this.payoutRunRepo.update(payoutRun.id, { status: 'PROCESSING' });
}
```

### Result callback

```json
{
  "Result": {
    "ResultType": 0,
    "ResultCode": 0,
    "ResultDesc": "The service request is processed successfully.",
    "OriginatorConversationID": "...",
    "TransactionID": "QGR8XXXX9B",
    "ResultParameters": {
      "ResultParameter": [
        { "Key": "TransactionAmount", "Value": 33012 },
        { "Key": "TransactionReceipt", "Value": "QGR8XXXX9B" },
        { "Key": "ReceiverPartyPublicName", "Value": "254712345678 - JANE INVESTOR" },
        { "Key": "TransactionCompletedDateTime", "Value": "24.06.2026 15:42:11" }
      ]
    }
  }
}
```

```typescript
@Post('mpesa/b2c/result')
async handleB2cResult(@Body() body: any) {
  const result = body.Result;
  const log = await this.mpesaLogRepo.findByOriginatorConversationId(result.OriginatorConversationID);
  const payoutRun = await this.payoutRunRepo.findOne(log.linkedPayoutRunId);

  if (result.ResultCode === 0) {
    const params = parseResultParameters(result.ResultParameters.ResultParameter);
    await this.payoutRunRepo.update(payoutRun.id, {
      status: 'PAID',
      paidAt: parseMpesaDate(params.TransactionCompletedDateTime),
      paymentReference: params.TransactionReceipt,
    });
    await this.automationEngine.handleEvent('PAYOUT_PAID', payoutRun);
    await this.documentService.generateInvestorStatement(payoutRun);
  } else {
    await this.payoutRunRepo.update(payoutRun.id, { status: 'FAILED' });
    await this.automationEngine.handleEvent('PAYOUT_DISBURSEMENT_FAILED', { ...payoutRun, failureReason: result.ResultDesc });
  }
  return { ResultCode: 0, ResultDesc: 'Accepted' };
}

@Post('mpesa/b2c/timeout')
async handleB2cTimeout(@Body() body: any) {
  // Network/queue timeout — treat same as failure, but flagged distinctly
  // so staff know to check whether money actually moved before retrying
  // (avoid double-paying an investor).
  await this.mpesaLogRepo.save({ direction: 'B2C_TIMEOUT', rawPayload: body });
  await this.taskService.create({
    title: `B2C payout TIMED OUT — verify before retry: ${body.Result?.OriginatorConversationID}`,
    assignToRole: 'ACCOUNTANT',
  });
  return { ResultCode: 0, ResultDesc: 'Accepted' };
}
```

## Reconciliation safeguards

- Every callback is persisted **raw** to `mpesa_transaction_log` before any
  processing — if our processing logic has a bug, the source-of-truth payload
  is never lost and can be replayed.
- B2C requests use `OriginatorConversationID` as an idempotency key — before
  disbursing, check no `mpesa_transaction_log` row with `direction='B2C'` and
  `linked_payout_run_id = payoutRun.id` and a non-failed result already
  exists, to prevent double-disbursement on retry.
- Daily automated reconciliation job compares `payment` + `investor_payout_run`
  totals against the M-Pesa statement/API balance for the paybill and B2C
  shortcode, flagging variances as a `staff_task` for the Accountant.

## Phone number normalization

M-Pesa requires `2547XXXXXXXX` format (no leading `+`, no leading `0`).
Centralize this:

```typescript
function normalizeToE164(phone: string): string {
  let p = phone.replace(/\s+/g, '').replace(/^\+/, '');
  if (p.startsWith('0')) p = '254' + p.slice(1);
  if (p.startsWith('7') || p.startsWith('1')) p = '254' + p; // bare 9-digit
  return p;
}
```
