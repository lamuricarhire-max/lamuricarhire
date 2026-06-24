-- ============================================================================
-- LAMURI CAR HIRE — SEED DATA
-- ============================================================================
-- Populates the system with sane defaults so admins are customizing an
-- already-working setup, not starting from a blank slate. Everything here
-- can be edited or deleted from the admin UI after go-live.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Countries & currencies
-- ---------------------------------------------------------------------------
INSERT INTO currency (code, name, symbol, decimal_places) VALUES
    ('KES', 'Kenyan Shilling', 'KSh', 2),
    ('USD', 'US Dollar', '$', 2),
    ('UGX', 'Ugandan Shilling', 'USh', 0),
    ('TZS', 'Tanzanian Shilling', 'TSh', 0);

INSERT INTO country (iso_code, name, default_currency_code, phone_dial_code) VALUES
    ('KE', 'Kenya', 'KES', '+254'),
    ('UG', 'Uganda', 'UGX', '+256'),
    ('TZ', 'Tanzania', 'TZS', '+255');

INSERT INTO tax_jurisdiction (country_id, name, tax_authority_code, notes)
    SELECT id, 'Kenya - KRA', 'KRA', 'Standard Kenyan VAT + withholding regime'
    FROM country WHERE iso_code = 'KE';

-- Standard Kenyan VAT on car hire (16%), price-inclusive.
INSERT INTO tax_rule (jurisdiction_id, name, tax_type, rate_percent, applies_to, is_inclusive, effective_from)
    SELECT id, 'Standard VAT - Rental Invoices', 'VAT', 16.000, 'RENTAL_INVOICE', TRUE, '2024-01-01'
    FROM tax_jurisdiction WHERE tax_authority_code = 'KRA';

-- Withholding tax applied to investor payouts (rate is illustrative —
-- admin must confirm against current KRA rules for rental/lease income;
-- exposed here purely as a configurable row, not tax advice).
INSERT INTO tax_rule (jurisdiction_id, name, tax_type, rate_percent, applies_to, is_inclusive, effective_from)
    SELECT id, 'Withholding Tax - Investor Payout', 'WITHHOLDING', 5.000, 'INVESTOR_PAYOUT', FALSE, '2024-01-01'
    FROM tax_jurisdiction WHERE tax_authority_code = 'KRA';

-- ---------------------------------------------------------------------------
-- Branch (seed one, admin adds more)
-- ---------------------------------------------------------------------------
INSERT INTO branch (country_id, code, name, currency_code, tax_jurisdiction_id, phone, email)
    SELECT c.id, 'NBO01', 'Nairobi CBD', 'KES', tj.id, '+254700000000', 'nairobi@lamuri.co.ke'
    FROM country c, tax_jurisdiction tj
    WHERE c.iso_code = 'KE' AND tj.tax_authority_code = 'KRA';

-- Document numbering sequences for the seeded branch.
INSERT INTO document_sequence (branch_id, document_type, prefix, padding)
SELECT b.id, dt.document_type, b.code || '-' || dt.prefix || '-', 6
FROM branch b
CROSS JOIN (VALUES
    ('INVOICE', 'INV'), ('RECEIPT', 'RCT'), ('AGREEMENT', 'AGR'),
    ('CREDIT_NOTE', 'CRN'), ('BOOKING', 'BK')
) AS dt(document_type, prefix)
WHERE b.code = 'NBO01';

-- ---------------------------------------------------------------------------
-- RBAC: Permissions (resource x action grid)
-- ---------------------------------------------------------------------------
INSERT INTO permission (resource, action) 
SELECT resource, action FROM (VALUES
    ('VEHICLE','CREATE'),('VEHICLE','READ'),('VEHICLE','UPDATE'),('VEHICLE','DELETE'),
    ('BOOKING','CREATE'),('BOOKING','READ'),('BOOKING','UPDATE'),('BOOKING','DELETE'),('BOOKING','APPROVE'),
    ('DISPATCH','CREATE'),('DISPATCH','READ'),
    ('MAINTENANCE','CREATE'),('MAINTENANCE','READ'),('MAINTENANCE','UPDATE'),
    ('INVOICE','CREATE'),('INVOICE','READ'),('INVOICE','UPDATE'),('INVOICE','APPROVE'),('INVOICE','EXPORT'),
    ('PAYMENT','CREATE'),('PAYMENT','READ'),
    ('PAYOUT','CREATE'),('PAYOUT','READ'),('PAYOUT','APPROVE'),('PAYOUT','EXPORT'),
    ('INVESTOR','CREATE'),('INVESTOR','READ'),('INVESTOR','UPDATE'),
    ('LEAD','CREATE'),('LEAD','READ'),('LEAD','UPDATE'),
    ('CAMPAIGN','CREATE'),('CAMPAIGN','READ'),
    ('USER','CREATE'),('USER','READ'),('USER','UPDATE'),('USER','DELETE'),
    ('ROLE','CREATE'),('ROLE','READ'),('ROLE','UPDATE'),
    ('SETTING','READ'),('SETTING','UPDATE'),
    ('REPORT','READ'),('REPORT','EXPORT'),
    ('AUTOMATION_RULE','CREATE'),('AUTOMATION_RULE','READ'),('AUTOMATION_RULE','UPDATE')
) AS p(resource, action);

-- ---------------------------------------------------------------------------
-- RBAC: Roles
-- ---------------------------------------------------------------------------
INSERT INTO role (name, description, is_system_role) VALUES
    ('SUPER_ADMIN', 'Full system access across all branches and configuration', TRUE),
    ('BRANCH_MANAGER', 'Full operational control of a single branch', TRUE),
    ('DISPATCH_OFFICER', 'Vehicle assignment, handover and return inspections', TRUE),
    ('RESERVATIONS_AGENT', 'Bookings, quotes, customer service', TRUE),
    ('ACCOUNTANT', 'Invoicing, payments, tax exports, payout approval', TRUE),
    ('WORKSHOP_SUPERVISOR', 'Maintenance scheduling and checklist sign-off', TRUE),
    ('CRM_SALES_AGENT', 'Leads pipeline and campaign management', TRUE),
    ('INVESTOR_PORTAL', 'Read-only investor self-service portal access', TRUE);

-- SUPER_ADMIN gets every permission.
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM role r CROSS JOIN permission p WHERE r.name = 'SUPER_ADMIN';

-- BRANCH_MANAGER: everything except global USER/ROLE/SETTING management.
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM role r, permission p
WHERE r.name = 'BRANCH_MANAGER'
  AND p.resource NOT IN ('ROLE') ;

-- DISPATCH_OFFICER
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM role r, permission p
WHERE r.name = 'DISPATCH_OFFICER'
  AND (p.resource IN ('DISPATCH','MAINTENANCE') OR (p.resource = 'VEHICLE' AND p.action = 'READ') OR (p.resource = 'BOOKING' AND p.action = 'READ'));

-- RESERVATIONS_AGENT
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM role r, permission p
WHERE r.name = 'RESERVATIONS_AGENT'
  AND (p.resource IN ('BOOKING','LEAD') OR (p.resource = 'VEHICLE' AND p.action = 'READ') OR (p.resource = 'INVOICE' AND p.action IN ('CREATE','READ')));

-- ACCOUNTANT
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM role r, permission p
WHERE r.name = 'ACCOUNTANT'
  AND (p.resource IN ('INVOICE','PAYMENT','PAYOUT','REPORT') OR (p.resource = 'BOOKING' AND p.action = 'READ'));

-- WORKSHOP_SUPERVISOR
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM role r, permission p
WHERE r.name = 'WORKSHOP_SUPERVISOR'
  AND (p.resource = 'MAINTENANCE' OR (p.resource = 'VEHICLE' AND p.action IN ('READ','UPDATE')));

-- CRM_SALES_AGENT
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM role r, permission p
WHERE r.name = 'CRM_SALES_AGENT'
  AND p.resource IN ('LEAD','CAMPAIGN');

-- INVESTOR_PORTAL: read-only on their own data (app layer scopes rows to
-- the logged-in investor_user_id; permission grid just allows the READ).
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM role r, permission p
WHERE r.name = 'INVESTOR_PORTAL'
  AND p.resource IN ('VEHICLE','PAYOUT','INVESTOR') AND p.action = 'READ';

-- ---------------------------------------------------------------------------
-- Vehicle categories with default rates (KES)
-- ---------------------------------------------------------------------------
INSERT INTO vehicle_category (name, default_daily_rate, default_weekly_rate, default_monthly_rate, currency_code) VALUES
    ('Economy',  3500,  21000,  75000, 'KES'),
    ('SUV',      7500,  45000, 160000, 'KES'),
    ('Van',      9000,  54000, 190000, 'KES'),
    ('Pickup',   6500,  39000, 140000, 'KES'),
    ('Luxury',  15000,  90000, 320000, 'KES');

-- ---------------------------------------------------------------------------
-- Lead sources & pipeline stages
-- ---------------------------------------------------------------------------
INSERT INTO lead_source (name) VALUES
    ('Website Form'), ('Phone Inquiry'), ('Walk-in'), ('Referral'),
    ('Facebook/Instagram Ad'), ('Corporate Outreach'), ('Booking.com / OTA');

INSERT INTO lead_pipeline_stage (name, sort_order, is_won_stage, is_lost_stage) VALUES
    ('New', 1, FALSE, FALSE),
    ('Contacted', 2, FALSE, FALSE),
    ('Quote Sent', 3, FALSE, FALSE),
    ('Negotiation', 4, FALSE, FALSE),
    ('Won - Converted', 5, TRUE, FALSE),
    ('Lost', 6, FALSE, TRUE);

-- ---------------------------------------------------------------------------
-- Chart of Accounts (minimal, extendable)
-- ---------------------------------------------------------------------------
INSERT INTO chart_of_account (account_code, account_name, account_type) VALUES
    ('1000', 'Cash & Bank', 'ASSET'),
    ('1100', 'M-Pesa Collection Account', 'ASSET'),
    ('1200', 'Accounts Receivable', 'ASSET'),
    ('1300', 'Security Deposits Held', 'LIABILITY'),
    ('2100', 'VAT Payable', 'LIABILITY'),
    ('2200', 'Withholding Tax Payable', 'LIABILITY'),
    ('2300', 'Investor Payouts Payable', 'LIABILITY'),
    ('4000', 'Rental Revenue', 'REVENUE'),
    ('4100', 'Extra Charges Revenue (Fuel/Damage/Late Fees)', 'REVENUE'),
    ('4200', 'Management Fee Revenue', 'REVENUE'),
    ('5000', 'Vehicle Maintenance Expense', 'EXPENSE'),
    ('5100', 'Insurance Expense', 'EXPENSE'),
    ('5200', 'Fuel Expense', 'EXPENSE'),
    ('5300', 'Salaries & Wages', 'EXPENSE'),
    ('5400', 'SMS & Communication Expense', 'EXPENSE'),
    ('5500', 'Investor Payout Expense (Cost of Revenue Share)', 'EXPENSE');

-- ---------------------------------------------------------------------------
-- Payout formula templates (admin can add more / edit params)
-- ---------------------------------------------------------------------------
INSERT INTO payout_formula_template (name, formula_type, formula_params, description) VALUES
    ('Standard 70/30 Net Revenue Share', 'REVENUE_SHARE',
     '{"investor_share_percent": 70, "base": "NET"}',
     'Investor receives 70% of net revenue (after maintenance/insurance deductions) per period.'),

    ('Fixed Monthly Lease - KES 60,000', 'FIXED_PERIODIC',
     '{"amount": 60000, "frequency": "MONTHLY", "currency": "KES"}',
     'Company pays investor a fixed amount per month regardless of bookings.'),

    ('Hybrid: KES 25,000 Guaranteed + 50% Above', 'HYBRID_MIN_GUARANTEE',
     '{"guaranteed_amount": 25000, "investor_share_percent": 50, "base": "NET"}',
     'Investor guaranteed a minimum; receives 50% of net revenue above the guarantee threshold.'),

    ('Tiered Revenue Share', 'TIERED_REVENUE_SHARE',
     '{"base": "NET", "tiers": [{"upto": 50000, "percent": 60}, {"upto": 100000, "percent": 70}, {"upto": null, "percent": 80}]}',
     'Investor share percentage increases as net revenue crosses thresholds.'),

    ('Per-Booking Flat Fee', 'PER_BOOKING_FEE',
     '{"fee_per_booking": 0, "fee_per_day": 1500, "currency": "KES"}',
     'Investor paid a flat amount per rental day the vehicle was actually booked out.');

-- ---------------------------------------------------------------------------
-- Message templates (SMS + Email) — placeholders use {{handlebars}} syntax
-- ---------------------------------------------------------------------------
INSERT INTO message_template (code, channel, subject, body_template) VALUES
    ('BOOKING_CONFIRMED_SMS', 'SMS', NULL,
     'Hi {{first_name}}, your booking {{booking_no}} for {{vehicle_make_model}} from {{start_date}} to {{end_date}} is CONFIRMED. Pickup: {{pickup_location}}. - LAMURI Car Hire'),

    ('DISPATCH_READY_SMS', 'SMS', NULL,
     'Hi {{first_name}}, your vehicle {{registration_no}} is ready for pickup at {{pickup_location}}. Booking {{booking_no}}. - LAMURI'),

    ('INSTALLMENT_DUE_REMINDER_SMS', 'SMS', NULL,
     'Hi {{first_name}}, your lease payment of {{currency}} {{amount_due}} for {{booking_no}} is due on {{due_date}}. Pay via M-Pesa Paybill {{paybill_number}}, Account {{booking_no}}. - LAMURI'),

    ('INSTALLMENT_OVERDUE_SMS', 'SMS', NULL,
     'Hi {{first_name}}, payment of {{currency}} {{amount_due}} for {{booking_no}} is now OVERDUE. A late fee may apply. Please pay promptly to avoid service interruption. - LAMURI'),

    ('PAYMENT_RECEIVED_SMS', 'SMS', NULL,
     'LAMURI: Payment of {{currency}} {{amount}} received for {{booking_no}}. Receipt {{receipt_no}}. Thank you!'),

    ('VEHICLE_DOC_EXPIRING_STAFF_SMS', 'SMS', NULL,
     'ALERT: {{document_type}} for vehicle {{registration_no}} expires on {{expiry_date}}. Please renew.'),

    ('INVESTOR_PAYOUT_PROCESSED_SMS', 'SMS', NULL,
     'Hi {{first_name}}, your payout of {{currency}} {{net_amount}} for {{vehicle_registration_no}} ({{period_label}}) has been sent via {{payout_method}}. Ref: {{payment_reference}}. - LAMURI'),

    ('LEAD_FOLLOWUP_REMINDER_SMS', 'SMS', NULL,
     'Reminder: Follow up with lead {{lead_name}} ({{lead_phone}}) - {{notes}}.'),

    ('INVOICE_EMAIL', 'EMAIL', 'Invoice {{invoice_no}} from LAMURI Car Hire',
     '<p>Dear {{first_name}},</p><p>Please find attached invoice {{invoice_no}} for {{currency}} {{total_amount}}, due {{due_date}}.</p><p>Thank you for choosing LAMURI Car Hire.</p>'),

    ('INVESTOR_STATEMENT_EMAIL', 'EMAIL', 'Your Payout Statement - {{period_label}}',
     '<p>Dear {{first_name}},</p><p>Attached is your payout statement for {{vehicle_registration_no}} covering {{period_label}}. Net amount: {{currency}} {{net_amount}}.</p>');

-- ---------------------------------------------------------------------------
-- Key system_setting defaults (admin-editable, no code change to alter)
-- ---------------------------------------------------------------------------
INSERT INTO system_setting (setting_key, setting_value, value_type, description) VALUES
    ('LATE_FEE_PERCENT', '5', 'NUMBER', 'Late fee % applied to overdue installments'),
    ('GRACE_PERIOD_DAYS', '2', 'NUMBER', 'Days after due_date before an installment is marked OVERDUE'),
    ('INSTALLMENT_REMINDER_DAYS_BEFORE', '3', 'NUMBER', 'Days before due_date to send the first SMS reminder'),
    ('SECURITY_DEPOSIT_DEFAULT_PERCENT', '20', 'NUMBER', 'Default security deposit as % of booking value if rate_plan does not specify one'),
    ('SMS_SENDER_ID', '"LAMURI"', 'STRING', 'Africa''s Talking SMS sender/short code'),
    ('MPESA_PAYBILL_NUMBER', '"600000"', 'STRING', 'M-Pesa Paybill number for customer payments'),
    ('VEHICLE_DOC_EXPIRY_ALERT_DAYS', '30', 'NUMBER', 'Days before document expiry to start alerting staff'),
    ('PAYOUT_APPROVAL_REQUIRED', 'true', 'BOOLEAN', 'Whether investor payouts require manager approval before disbursement');
