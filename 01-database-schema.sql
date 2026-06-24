-- ============================================================================
-- LAMURI CAR HIRE — DATABASE SCHEMA (PostgreSQL 15+)
-- ============================================================================
-- Design principles:
--   1. Multi-branch & multi-currency from day one (branch_id + currency_code
--      on every money-bearing / operational table).
--   2. Configuration over code: formulas, tax rules, automation rules and
--      document templates are DATA, not application logic.
--   3. Soft-delete via deleted_at on records with financial/legal history;
--      hard delete only on pure config/lookup tables.
--   4. Every table has created_at/updated_at; financial tables add
--      created_by/updated_by for audit.
--   5. Money stored as NUMERIC(14,2) in transaction currency; never FLOAT.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================================
-- SECTION 1: ORGANIZATION, BRANCHES, CURRENCY, TAX JURISDICTION
-- ============================================================================

CREATE TABLE country (
    id              SMALLSERIAL PRIMARY KEY,
    iso_code        CHAR(2) NOT NULL UNIQUE,         -- 'KE', 'UG', 'TZ'
    name            VARCHAR(100) NOT NULL,
    default_currency_code CHAR(3) NOT NULL,          -- 'KES'
    phone_dial_code VARCHAR(5) NOT NULL,              -- '+254'
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE currency (
    code            CHAR(3) PRIMARY KEY,              -- ISO 4217: KES, USD, UGX
    name            VARCHAR(50) NOT NULL,
    symbol          VARCHAR(5) NOT NULL,
    decimal_places  SMALLINT NOT NULL DEFAULT 2,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

-- Date-stamped FX rates for consolidated multi-branch reporting.
CREATE TABLE exchange_rate (
    id              BIGSERIAL PRIMARY KEY,
    base_currency   CHAR(3) NOT NULL REFERENCES currency(code),
    quote_currency  CHAR(3) NOT NULL REFERENCES currency(code),
    rate            NUMERIC(18,8) NOT NULL,           -- 1 base = rate * quote
    effective_date  DATE NOT NULL,
    source          VARCHAR(50) DEFAULT 'manual',      -- 'manual','CBK','xe_api'
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (base_currency, quote_currency, effective_date)
);

CREATE TABLE tax_jurisdiction (
    id              SERIAL PRIMARY KEY,
    country_id      SMALLINT NOT NULL REFERENCES country(id),
    name            VARCHAR(100) NOT NULL,             -- 'Kenya - KRA'
    tax_authority_code VARCHAR(50),                    -- e.g. KRA PIN format validator key
    notes           TEXT
);

-- Admin-configurable tax rules. The Tax Engine resolves the applicable row(s)
-- for a transaction by branch + transaction_type + customer_type + date.
CREATE TABLE tax_rule (
    id                  SERIAL PRIMARY KEY,
    jurisdiction_id     INTEGER NOT NULL REFERENCES tax_jurisdiction(id),
    name                VARCHAR(100) NOT NULL,         -- 'Standard VAT', 'Withholding Tax - Investor Payout'
    tax_type            VARCHAR(30) NOT NULL,          -- 'VAT','WITHHOLDING','EXCISE','CATERING_LEVY','CUSTOM'
    rate_percent        NUMERIC(6,3) NOT NULL,         -- 16.000
    applies_to          VARCHAR(30) NOT NULL,          -- 'RENTAL_INVOICE','INVESTOR_PAYOUT','SERVICE_FEE','ALL'
    customer_type_filter VARCHAR(20),                  -- NULL=all, 'INDIVIDUAL','CORPORATE'
    is_inclusive         BOOLEAN NOT NULL DEFAULT TRUE, -- price-inclusive vs exclusive of tax
    effective_from      DATE NOT NULL,
    effective_to        DATE,                          -- NULL = open-ended
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE branch (
    id              SERIAL PRIMARY KEY,
    country_id      SMALLINT NOT NULL REFERENCES country(id),
    code            VARCHAR(10) NOT NULL UNIQUE,       -- 'NBO01','MSA01'
    name            VARCHAR(100) NOT NULL,             -- 'Nairobi CBD'
    currency_code   CHAR(3) NOT NULL REFERENCES currency(code),
    tax_jurisdiction_id INTEGER REFERENCES tax_jurisdiction(id),
    address         TEXT,
    phone           VARCHAR(20),
    email           VARCHAR(100),
    timezone        VARCHAR(50) NOT NULL DEFAULT 'Africa/Nairobi',
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Generic key/value system settings, scoped optionally per branch.
-- Lets admins tune behavior (grace periods, late fee %, SMS sender ID, etc.)
-- without code changes. value is JSONB to support any shape.
CREATE TABLE system_setting (
    id              SERIAL PRIMARY KEY,
    branch_id       INTEGER REFERENCES branch(id),     -- NULL = global default
    setting_key     VARCHAR(100) NOT NULL,              -- 'LATE_FEE_PERCENT','GRACE_PERIOD_DAYS'
    setting_value   JSONB NOT NULL,
    value_type      VARCHAR(20) NOT NULL DEFAULT 'JSON', -- 'NUMBER','STRING','BOOLEAN','JSON'
    description     TEXT,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by      UUID,
    UNIQUE (branch_id, setting_key)
);

-- Sequential, gapless document numbering per branch + document type
-- (KRA requires sequential non-reusable invoice numbers).
CREATE TABLE document_sequence (
    id              SERIAL PRIMARY KEY,
    branch_id       INTEGER NOT NULL REFERENCES branch(id),
    document_type   VARCHAR(30) NOT NULL,             -- 'INVOICE','RECEIPT','AGREEMENT','CREDIT_NOTE'
    prefix          VARCHAR(20) NOT NULL DEFAULT '',   -- 'NBO-INV-'
    next_number      BIGINT NOT NULL DEFAULT 1,
    padding          SMALLINT NOT NULL DEFAULT 6,       -- zero-pad width
    reset_policy     VARCHAR(20) NOT NULL DEFAULT 'NEVER', -- 'NEVER','YEARLY','MONTHLY'
    last_reset_at    TIMESTAMPTZ,
    UNIQUE (branch_id, document_type)
);

-- ============================================================================
-- SECTION 2: IDENTITY & ACCESS (RBAC)
-- ============================================================================

CREATE TABLE app_user (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    branch_id       INTEGER REFERENCES branch(id),      -- home branch (staff); NULL ok for investors w/ multi-vehicle across branches
    user_type       VARCHAR(20) NOT NULL,                -- 'STAFF','INVESTOR','CUSTOMER','SYSTEM'
    first_name      VARCHAR(80) NOT NULL,
    last_name       VARCHAR(80) NOT NULL,
    email           VARCHAR(150) UNIQUE,
    phone           VARCHAR(20) NOT NULL UNIQUE,          -- E.164 format, primary login/SMS channel
    password_hash   TEXT,                                 -- NULL for SMS-OTP-only investor/customer portal accounts
    national_id     VARCHAR(30),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ
);

CREATE TABLE role (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(50) NOT NULL UNIQUE,          -- 'SUPER_ADMIN','BRANCH_MANAGER','DISPATCH_OFFICER', etc.
    description     TEXT,
    is_system_role  BOOLEAN NOT NULL DEFAULT FALSE,        -- system roles can't be deleted, only extended
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE permission (
    id              SERIAL PRIMARY KEY,
    resource        VARCHAR(60) NOT NULL,                  -- 'VEHICLE','BOOKING','INVOICE','PAYOUT','USER', ...
    action          VARCHAR(30) NOT NULL,                  -- 'CREATE','READ','UPDATE','DELETE','APPROVE','EXPORT'
    description     TEXT,
    UNIQUE (resource, action)
);

CREATE TABLE role_permission (
    role_id         INTEGER NOT NULL REFERENCES role(id) ON DELETE CASCADE,
    permission_id   INTEGER NOT NULL REFERENCES permission(id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE user_role (
    user_id         UUID NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    role_id         INTEGER NOT NULL REFERENCES role(id) ON DELETE CASCADE,
    branch_id       INTEGER REFERENCES branch(id),          -- role can be branch-scoped (e.g. manager of branch X only)
    assigned_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, role_id, branch_id)
);

CREATE TABLE staff_profile (
    user_id         UUID PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
    employee_no     VARCHAR(30) UNIQUE,
    job_title       VARCHAR(80),
    department      VARCHAR(50),                            -- 'OPERATIONS','FINANCE','FLEET','SALES'
    hire_date       DATE,
    employment_status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE', -- 'ACTIVE','SUSPENDED','TERMINATED'
    reports_to_user_id UUID REFERENCES app_user(id)
);

CREATE TABLE audit_log (
    id              BIGSERIAL PRIMARY KEY,
    user_id         UUID REFERENCES app_user(id),
    branch_id       INTEGER REFERENCES branch(id),
    action          VARCHAR(50) NOT NULL,                    -- 'CREATE','UPDATE','DELETE','APPROVE','LOGIN'
    entity_type     VARCHAR(60) NOT NULL,                    -- 'vehicle','booking','payout_run', etc.
    entity_id       VARCHAR(60) NOT NULL,
    before_data     JSONB,
    after_data      JSONB,
    ip_address      VARCHAR(45),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_entity ON audit_log(entity_type, entity_id);
CREATE INDEX idx_audit_user ON audit_log(user_id, created_at);

-- ============================================================================
-- SECTION 3: FLEET / VEHICLE MANAGEMENT
-- ============================================================================

CREATE TABLE vehicle_category (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(50) NOT NULL UNIQUE,        -- 'Economy','SUV','Luxury','Van','Pickup'
    default_daily_rate NUMERIC(12,2),
    default_weekly_rate NUMERIC(12,2),
    default_monthly_rate NUMERIC(12,2),
    currency_code   CHAR(3) REFERENCES currency(code)
);

CREATE TABLE vehicle (
    id                  SERIAL PRIMARY KEY,
    branch_id           INTEGER NOT NULL REFERENCES branch(id),
    category_id         INTEGER REFERENCES vehicle_category(id),
    ownership_type      VARCHAR(20) NOT NULL,            -- 'COMPANY_OWNED','INVESTOR_OWNED'
    registration_no     VARCHAR(20) NOT NULL UNIQUE,     -- 'KDA 123A'
    make                VARCHAR(50) NOT NULL,
    model               VARCHAR(50) NOT NULL,
    year                SMALLINT,
    color               VARCHAR(30),
    vin_chassis_no      VARCHAR(50),
    engine_no           VARCHAR(50),
    transmission        VARCHAR(15),                      -- 'MANUAL','AUTOMATIC'
    fuel_type           VARCHAR(15),                       -- 'PETROL','DIESEL','HYBRID','EV'
    seats               SMALLINT,
    odometer_km         INTEGER NOT NULL DEFAULT 0,
    gps_device_id       VARCHAR(50),                       -- tracker integration reference
    daily_rate          NUMERIC(12,2),
    weekly_rate         NUMERIC(12,2),
    monthly_rate        NUMERIC(12,2),
    currency_code       CHAR(3) NOT NULL REFERENCES currency(code),
    status              VARCHAR(20) NOT NULL DEFAULT 'AVAILABLE',
        -- 'AVAILABLE','RENTED','RESERVED','IN_SERVICE','OUT_OF_SERVICE','DISPOSED'
    current_branch_id   INTEGER REFERENCES branch(id),    -- where vehicle physically is now (may differ from home branch_id)
    acquisition_date    DATE,
    acquisition_value   NUMERIC(14,2),
    disposal_date       DATE,
    photo_urls          JSONB,                              -- ["url1","url2"]
    notes                TEXT,
    is_active            BOOLEAN NOT NULL DEFAULT TRUE,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at             TIMESTAMPTZ
);
CREATE INDEX idx_vehicle_branch_status ON vehicle(branch_id, status);
CREATE INDEX idx_vehicle_ownership ON vehicle(ownership_type);

CREATE TABLE vehicle_document (
    id                  SERIAL PRIMARY KEY,
    vehicle_id          INTEGER NOT NULL REFERENCES vehicle(id) ON DELETE CASCADE,
    document_type       VARCHAR(30) NOT NULL,             -- 'LOGBOOK','INSURANCE','INSPECTION_CERT','TLB_PERMIT'
    document_no         VARCHAR(60),
    issued_date          DATE,
    expiry_date          DATE,
    issuing_authority    VARCHAR(100),
    file_url             TEXT,
    reminder_sent_at      TIMESTAMPTZ,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_vehicle_doc_expiry ON vehicle_document(expiry_date);

CREATE TABLE insurance_policy (
    id                  SERIAL PRIMARY KEY,
    vehicle_id          INTEGER NOT NULL REFERENCES vehicle(id),
    insurer_name         VARCHAR(100) NOT NULL,
    policy_no            VARCHAR(60) NOT NULL,
    cover_type           VARCHAR(20) NOT NULL,             -- 'COMPREHENSIVE','THIRD_PARTY'
    premium_amount       NUMERIC(12,2),
    currency_code        CHAR(3) REFERENCES currency(code),
    start_date            DATE NOT NULL,
    end_date              DATE NOT NULL,
    excess_amount         NUMERIC(12,2),
    billed_to             VARCHAR(20) NOT NULL DEFAULT 'COMPANY', -- 'COMPANY','INVESTOR' (who pays premium — feeds payout deductions)
    document_url          TEXT,
    status                 VARCHAR(20) NOT NULL DEFAULT 'ACTIVE', -- 'ACTIVE','EXPIRED','CANCELLED'
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_insurance_vehicle ON insurance_policy(vehicle_id, end_date);

CREATE TABLE insurance_claim (
    id                  SERIAL PRIMARY KEY,
    insurance_policy_id INTEGER NOT NULL REFERENCES insurance_policy(id),
    vehicle_id          INTEGER NOT NULL REFERENCES vehicle(id),
    incident_date        DATE NOT NULL,
    description           TEXT,
    claim_amount          NUMERIC(12,2),
    approved_amount       NUMERIC(12,2),
    status                VARCHAR(20) NOT NULL DEFAULT 'FILED', -- 'FILED','UNDER_REVIEW','APPROVED','REJECTED','PAID'
    booking_id            INTEGER,                              -- FK added after booking table defined (nullable link)
    police_abstract_url   TEXT,
    photos_urls           JSONB,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Maintenance: service schedule TEMPLATE (admin-configurable per category) +
-- actual service records + checklist items.
CREATE TABLE maintenance_schedule_template (
    id                  SERIAL PRIMARY KEY,
    category_id          INTEGER REFERENCES vehicle_category(id),  -- NULL = applies to all
    name                  VARCHAR(100) NOT NULL,        -- 'Standard Service - 5000km'
    interval_km           INTEGER,                       -- trigger by mileage
    interval_days          INTEGER,                       -- trigger by time
    checklist_items_json   JSONB NOT NULL,                -- [{item:'Engine oil', instructions:'...'}, ...]
    is_active               BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE maintenance_record (
    id                  SERIAL PRIMARY KEY,
    vehicle_id          INTEGER NOT NULL REFERENCES vehicle(id),
    schedule_template_id INTEGER REFERENCES maintenance_schedule_template(id),
    service_type         VARCHAR(30) NOT NULL,           -- 'SCHEDULED','REPAIR','ACCIDENT','TIRE','INSPECTION'
    odometer_at_service   INTEGER,
    scheduled_date         DATE,
    completed_date         DATE,
    vendor_name             VARCHAR(100),                 -- garage/workshop
    cost_amount             NUMERIC(12,2) NOT NULL DEFAULT 0,
    currency_code            CHAR(3) REFERENCES currency(code),
    billed_to                VARCHAR(20) NOT NULL DEFAULT 'COMPANY', -- 'COMPANY','INVESTOR' (feeds payout deductions)
    status                    VARCHAR(20) NOT NULL DEFAULT 'SCHEDULED', -- 'SCHEDULED','IN_PROGRESS','COMPLETED','CANCELLED'
    invoice_doc_url            TEXT,
    notes                      TEXT,
    created_by                 UUID REFERENCES app_user(id),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_maintenance_vehicle ON maintenance_record(vehicle_id, scheduled_date);

CREATE TABLE maintenance_checklist_result (
    id                  SERIAL PRIMARY KEY,
    maintenance_record_id INTEGER NOT NULL REFERENCES maintenance_record(id) ON DELETE CASCADE,
    item_name              VARCHAR(150) NOT NULL,
    status                  VARCHAR(15) NOT NULL,          -- 'OK','NEEDS_ATTENTION','REPLACED','NOT_APPLICABLE'
    remarks                  TEXT,
    checked_by                UUID REFERENCES app_user(id),
    checked_at                 TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Vehicle dispatch / handover & return inspections (condition capture both ways).
CREATE TABLE vehicle_inspection (
    id                  SERIAL PRIMARY KEY,
    vehicle_id          INTEGER NOT NULL REFERENCES vehicle(id),
    booking_id           INTEGER,                          -- FK added after booking table defined
    inspection_type        VARCHAR(15) NOT NULL,            -- 'DISPATCH','RETURN'
    odometer_reading        INTEGER NOT NULL,
    fuel_level_percent       SMALLINT,
    exterior_condition_json   JSONB,                        -- diagram points / damage notes
    interior_condition_notes   TEXT,
    accessories_checklist_json JSONB,                        -- {spare_tyre:true, jack:true, ...}
    damage_found              BOOLEAN NOT NULL DEFAULT FALSE,
    damage_notes                TEXT,
    photo_urls                  JSONB,
    inspected_by                 UUID NOT NULL REFERENCES app_user(id),
    customer_signature_url        TEXT,
    staff_signature_url            TEXT,
    inspected_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_inspection_vehicle ON vehicle_inspection(vehicle_id, inspected_at);

-- Vehicle movement/transfer between branches (for multi-branch fleet rebalancing).
CREATE TABLE vehicle_transfer (
    id                  SERIAL PRIMARY KEY,
    vehicle_id          INTEGER NOT NULL REFERENCES vehicle(id),
    from_branch_id        INTEGER NOT NULL REFERENCES branch(id),
    to_branch_id           INTEGER NOT NULL REFERENCES branch(id),
    requested_by            UUID REFERENCES app_user(id),
    approved_by              UUID REFERENCES app_user(id),
    status                    VARCHAR(20) NOT NULL DEFAULT 'PENDING', -- 'PENDING','APPROVED','IN_TRANSIT','COMPLETED','CANCELLED'
    requested_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at                TIMESTAMPTZ
);

-- ============================================================================
-- SECTION 4: INVESTORS (VEHICLE OWNERS) & LEASING CONTRACTS
-- ============================================================================

CREATE TABLE investor_profile (
    user_id             UUID PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
    investor_code       VARCHAR(20) UNIQUE NOT NULL,          -- 'INV-0001'
    kra_pin             VARCHAR(20),
    payout_currency_code CHAR(3) NOT NULL REFERENCES currency(code),
    preferred_payout_method VARCHAR(20) NOT NULL DEFAULT 'MPESA_B2C', -- 'MPESA_B2C','BANK_TRANSFER'
    bank_name           VARCHAR(100),
    bank_account_no     VARCHAR(40),
    bank_branch         VARCHAR(80),
    mpesa_payout_number VARCHAR(20),
    notes               TEXT,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- A reusable PAYOUT FORMULA TEMPLATE that admins define ONCE, then attach to
-- many investor contracts. This is the heart of "admin-customizable payout
-- model" — no two formula types are hardcoded; they're all data.
--
-- formula_type drives which parameters the Payout Engine expects in
-- formula_params (JSONB). See 02-investor-payout-engine.md for full spec.
--   'FIXED_PERIODIC'        params: { amount, frequency }
--   'REVENUE_SHARE'         params: { investor_share_percent, base: 'GROSS'|'NET' }
--   'HYBRID_MIN_GUARANTEE'  params: { guaranteed_amount, investor_share_percent, base }
--   'TIERED_REVENUE_SHARE'  params: { tiers: [{upto, percent}, ...], base }
--   'PER_BOOKING_FEE'       params: { fee_per_booking, fee_per_day }
CREATE TABLE payout_formula_template (
    id                  SERIAL PRIMARY KEY,
    name                VARCHAR(100) NOT NULL,                -- 'Standard 65/35 Net Share'
    formula_type        VARCHAR(30) NOT NULL,
    formula_params      JSONB NOT NULL,
    description         TEXT,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          UUID REFERENCES app_user(id)
);

-- The contract between LAMURI and an investor for ONE vehicle (a vehicle could
-- in theory be re-contracted over time, hence contract has its own date range
-- rather than living directly on vehicle).
CREATE TABLE investor_contract (
    id                  SERIAL PRIMARY KEY,
    contract_no         VARCHAR(30) UNIQUE NOT NULL,           -- 'IC-NBO-0042'
    investor_user_id    UUID NOT NULL REFERENCES app_user(id),
    vehicle_id          INTEGER NOT NULL REFERENCES vehicle(id),
    branch_id           INTEGER NOT NULL REFERENCES branch(id),
    payout_formula_template_id INTEGER REFERENCES payout_formula_template(id),
    formula_override_params JSONB,                              -- per-contract override of template defaults
    payout_frequency    VARCHAR(20) NOT NULL DEFAULT 'MONTHLY',  -- 'WEEKLY','MONTHLY'
    payout_day_of_period SMALLINT NOT NULL DEFAULT 1,             -- day-of-week (1-7) if WEEKLY, day-of-month if MONTHLY
    deduct_maintenance  BOOLEAN NOT NULL DEFAULT TRUE,            -- whether maintenance cost is deducted before payout
    deduct_insurance    BOOLEAN NOT NULL DEFAULT TRUE,
    deduct_commission   BOOLEAN NOT NULL DEFAULT TRUE,            -- LAMURI's management commission, if modeled as deduction not share
    management_fee_percent NUMERIC(6,3) DEFAULT 0,                -- flat management fee on top of/alternative to revenue share
    contract_start_date DATE NOT NULL,
    contract_end_date   DATE,
    status              VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',    -- 'DRAFT','ACTIVE','SUSPENDED','TERMINATED','EXPIRED'
    termination_reason  TEXT,
    signed_document_url TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          UUID REFERENCES app_user(id)
);
CREATE INDEX idx_investor_contract_vehicle ON investor_contract(vehicle_id);
CREATE INDEX idx_investor_contract_investor ON investor_contract(investor_user_id);

-- One row per payout cycle execution (e.g. "March 2026 monthly run").
-- Generated by the Payout Engine; see 02-investor-payout-engine.md.
CREATE TABLE investor_payout_run (
    id                  BIGSERIAL PRIMARY KEY,
    investor_contract_id INTEGER NOT NULL REFERENCES investor_contract(id),
    period_start        DATE NOT NULL,
    period_end          DATE NOT NULL,
    gross_revenue       NUMERIC(14,2) NOT NULL DEFAULT 0,
    deductions_total    NUMERIC(14,2) NOT NULL DEFAULT 0,
    deductions_breakdown JSONB,                                  -- [{type:'MAINTENANCE',amount:..},{type:'INSURANCE',amount:..}]
    management_fee_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
    withholding_tax_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
    net_payout_amount   NUMERIC(14,2) NOT NULL DEFAULT 0,
    currency_code       CHAR(3) NOT NULL REFERENCES currency(code),
    calculation_trace   JSONB,                                   -- full step-by-step calc for transparency/audit
    status              VARCHAR(20) NOT NULL DEFAULT 'CALCULATED', -- 'CALCULATED','APPROVED','PAID','FAILED','DISPUTED','REVERSED'
    approved_by         UUID REFERENCES app_user(id),
    approved_at         TIMESTAMPTZ,
    paid_at             TIMESTAMPTZ,
    payment_reference   VARCHAR(80),                              -- M-Pesa B2C transaction ID / bank ref
    statement_document_id INTEGER,                                -- FK to generated_document, added later
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_payout_run_contract ON investor_payout_run(investor_contract_id, period_start);
CREATE UNIQUE INDEX uq_payout_run_period ON investor_payout_run(investor_contract_id, period_start, period_end);

-- ============================================================================
-- SECTION 5: CUSTOMERS, LEADS & CRM
-- ============================================================================

CREATE TABLE customer_profile (
    user_id             UUID PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
    customer_type        VARCHAR(20) NOT NULL DEFAULT 'INDIVIDUAL', -- 'INDIVIDUAL','CORPORATE'
    company_name          VARCHAR(150),
    kra_pin                VARCHAR(20),
    id_or_passport_no       VARCHAR(30),
    drivers_license_no       VARCHAR(30),
    drivers_license_expiry    DATE,
    drivers_license_doc_url    TEXT,
    id_doc_url                  TEXT,
    address                       TEXT,
    blacklisted                   BOOLEAN NOT NULL DEFAULT FALSE,
    blacklist_reason               TEXT,
    loyalty_points                  INTEGER NOT NULL DEFAULT 0,
    customer_source                  VARCHAR(50),               -- 'WEBSITE','REFERRAL','WALK_IN','CORPORATE_DEAL'
    created_at                        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE lead_source (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(60) NOT NULL UNIQUE             -- 'Website Form','Facebook Ad','Walk-in','Referral','Corporate Outreach'
);

CREATE TABLE lead_pipeline_stage (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(50) NOT NULL UNIQUE,             -- 'New','Contacted','Quote Sent','Negotiation','Won','Lost'
    sort_order       SMALLINT NOT NULL,
    is_won_stage      BOOLEAN NOT NULL DEFAULT FALSE,
    is_lost_stage      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE lead (
    id                  SERIAL PRIMARY KEY,
    branch_id            INTEGER NOT NULL REFERENCES branch(id),
    full_name             VARCHAR(150) NOT NULL,
    phone                  VARCHAR(20) NOT NULL,
    email                   VARCHAR(150),
    lead_source_id           INTEGER REFERENCES lead_source(id),
    pipeline_stage_id         INTEGER NOT NULL REFERENCES lead_pipeline_stage(id),
    interested_category_id     INTEGER REFERENCES vehicle_category(id),
    interested_start_date        DATE,
    interested_end_date            DATE,
    estimated_value                 NUMERIC(12,2),
    assigned_to_user_id              UUID REFERENCES app_user(id),  -- CRM agent
    converted_customer_user_id        UUID REFERENCES app_user(id), -- set when lead becomes a customer
    converted_at                       TIMESTAMPTZ,
    lost_reason                         TEXT,
    notes                                TEXT,
    created_at                            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                             TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_lead_stage ON lead(pipeline_stage_id);
CREATE INDEX idx_lead_assigned ON lead(assigned_to_user_id);

CREATE TABLE lead_activity (
    id                  SERIAL PRIMARY KEY,
    lead_id              INTEGER NOT NULL REFERENCES lead(id) ON DELETE CASCADE,
    activity_type          VARCHAR(20) NOT NULL,            -- 'CALL','SMS','EMAIL','MEETING','NOTE','STAGE_CHANGE'
    notes                    TEXT,
    follow_up_due_at           TIMESTAMPTZ,
    completed                   BOOLEAN NOT NULL DEFAULT FALSE,
    performed_by                 UUID REFERENCES app_user(id),
    created_at                     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_lead_activity_followup ON lead_activity(follow_up_due_at) WHERE completed = FALSE;

CREATE TABLE campaign (
    id                  SERIAL PRIMARY KEY,
    name                  VARCHAR(100) NOT NULL,
    channel                VARCHAR(15) NOT NULL,             -- 'SMS','EMAIL'
    target_segment_json      JSONB,                            -- filter definition: {customer_type:'CORPORATE', last_booking_before:'...'}
    message_template_id        INTEGER,                          -- FK to message_template, defined later
    scheduled_at                 TIMESTAMPTZ,
    status                        VARCHAR(20) NOT NULL DEFAULT 'DRAFT', -- 'DRAFT','SCHEDULED','SENDING','COMPLETED','CANCELLED'
    created_by                     UUID REFERENCES app_user(id),
    created_at                       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE campaign_recipient (
    id                  BIGSERIAL PRIMARY KEY,
    campaign_id           INTEGER NOT NULL REFERENCES campaign(id) ON DELETE CASCADE,
    user_id                 UUID REFERENCES app_user(id),
    lead_id                   INTEGER REFERENCES lead(id),
    status                     VARCHAR(15) NOT NULL DEFAULT 'PENDING', -- 'PENDING','SENT','FAILED','DELIVERED'
    sent_at                      TIMESTAMPTZ
);

-- ============================================================================
-- SECTION 6: BOOKINGS, RENTAL AGREEMENTS & PRICING
-- ============================================================================
-- NOTE: "leasing model with weekly/monthly payments" applies on BOTH sides:
--   - Customer-side: a customer can rent a vehicle under a weekly or monthly
--     PAYMENT SCHEDULE (long-term lease), not just a single daily rental.
--   - Investor-side: handled separately above (investor_contract /
--     investor_payout_run) since that is owner→company, not customer→company.
-- This section models the customer-facing booking/rental/lease lifecycle.

CREATE TABLE rate_plan (
    id                  SERIAL PRIMARY KEY,
    branch_id             INTEGER REFERENCES branch(id),       -- NULL = applies to all branches
    category_id            INTEGER REFERENCES vehicle_category(id),
    name                     VARCHAR(100) NOT NULL,              -- 'Standard Daily','Corporate Monthly Lease'
    rental_mode                VARCHAR(15) NOT NULL,               -- 'DAILY','WEEKLY','MONTHLY'
    rate_amount                  NUMERIC(12,2) NOT NULL,
    currency_code                  CHAR(3) NOT NULL REFERENCES currency(code),
    mileage_limit_per_period         INTEGER,                       -- NULL = unlimited
    excess_mileage_rate                NUMERIC(10,2),
    security_deposit_amount              NUMERIC(12,2),
    min_period_units                       SMALLINT NOT NULL DEFAULT 1, -- min 1 week / 1 month / 1 day
    is_active                                BOOLEAN NOT NULL DEFAULT TRUE,
    created_at                                 TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE booking (
    id                  SERIAL PRIMARY KEY,
    booking_no            VARCHAR(30) UNIQUE NOT NULL,           -- 'NBO-BK-000123'
    branch_id               INTEGER NOT NULL REFERENCES branch(id),
    customer_user_id          UUID NOT NULL REFERENCES app_user(id),
    vehicle_id                  INTEGER REFERENCES vehicle(id),     -- nullable until assigned at confirmation
    category_id                   INTEGER REFERENCES vehicle_category(id), -- requested category before assignment
    rate_plan_id                    INTEGER REFERENCES rate_plan(id),
    rental_mode                       VARCHAR(15) NOT NULL,             -- 'DAILY','WEEKLY','MONTHLY'
    booking_source                      VARCHAR(20) NOT NULL DEFAULT 'STAFF', -- 'WEBSITE','APP','STAFF','WALK_IN','CORPORATE'
    lead_id                                INTEGER REFERENCES lead(id),
    start_datetime                          TIMESTAMPTZ NOT NULL,
    end_datetime                              TIMESTAMPTZ NOT NULL,
    pickup_location                             VARCHAR(150),
    dropoff_location                              VARCHAR(150),
    driver_required                                BOOLEAN NOT NULL DEFAULT FALSE,
    assigned_driver_user_id                          UUID REFERENCES app_user(id),
    base_amount                                        NUMERIC(14,2) NOT NULL DEFAULT 0,
    discount_amount                                      NUMERIC(14,2) NOT NULL DEFAULT 0,
    security_deposit_amount                                NUMERIC(14,2) NOT NULL DEFAULT 0,
    security_deposit_status                                  VARCHAR(15) NOT NULL DEFAULT 'PENDING', -- 'PENDING','HELD','REFUNDED','FORFEITED'
    currency_code                                              CHAR(3) NOT NULL REFERENCES currency(code),
    status                                                       VARCHAR(20) NOT NULL DEFAULT 'INQUIRY',
        -- 'INQUIRY','QUOTED','CONFIRMED','DISPATCHED','ACTIVE','RETURNED','COMPLETED','CANCELLED','OVERDUE'
    cancellation_reason                                            TEXT,
    created_by                                                       UUID REFERENCES app_user(id),
    created_at                                                         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                                                           TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_booking_customer ON booking(customer_user_id);
CREATE INDEX idx_booking_vehicle_dates ON booking(vehicle_id, start_datetime, end_datetime);
CREATE INDEX idx_booking_status ON booking(branch_id, status);

-- For weekly/monthly LEASES, a booking spans many billing cycles. This table
-- generates one row per cycle so invoicing/SMS reminders/late-fee logic can
-- operate per-installment rather than on the whole booking.
CREATE TABLE booking_installment (
    id                  SERIAL PRIMARY KEY,
    booking_id            INTEGER NOT NULL REFERENCES booking(id) ON DELETE CASCADE,
    installment_no          INTEGER NOT NULL,                  -- 1,2,3...
    period_start               DATE NOT NULL,
    period_end                   DATE NOT NULL,
    amount_due                     NUMERIC(14,2) NOT NULL,
    amount_paid                      NUMERIC(14,2) NOT NULL DEFAULT 0,
    due_date                           DATE NOT NULL,
    status                               VARCHAR(15) NOT NULL DEFAULT 'PENDING', -- 'PENDING','PARTIAL','PAID','OVERDUE','WAIVED'
    late_fee_applied                       NUMERIC(12,2) NOT NULL DEFAULT 0,
    created_at                               TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (booking_id, installment_no)
);
CREATE INDEX idx_installment_due ON booking_installment(due_date, status);

CREATE TABLE rental_agreement (
    id                  SERIAL PRIMARY KEY,
    booking_id            INTEGER NOT NULL UNIQUE REFERENCES booking(id),
    agreement_no             VARCHAR(30) UNIQUE NOT NULL,        -- 'NBO-AGR-000123'
    template_id                INTEGER,                            -- FK to document_template, defined later
    rendered_content_html        TEXT,                              -- frozen snapshot of merged agreement at signing time
    pdf_url                         TEXT,
    customer_signed                   BOOLEAN NOT NULL DEFAULT FALSE,
    customer_signature_url              TEXT,
    customer_signed_at                    TIMESTAMPTZ,
    staff_witness_user_id                   UUID REFERENCES app_user(id),
    staff_signed_at                           TIMESTAMPTZ,
    terms_version                               VARCHAR(20),         -- which T&C version was active
    created_at                                   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Links a booking to its dispatch and return inspections (1:1 each way).
ALTER TABLE vehicle_inspection ADD CONSTRAINT fk_inspection_booking
    FOREIGN KEY (booking_id) REFERENCES booking(id);
ALTER TABLE insurance_claim ADD CONSTRAINT fk_claim_booking
    FOREIGN KEY (booking_id) REFERENCES booking(id);

CREATE TABLE booking_extra_charge (
    id                  SERIAL PRIMARY KEY,
    booking_id            INTEGER NOT NULL REFERENCES booking(id) ON DELETE CASCADE,
    charge_type             VARCHAR(30) NOT NULL,              -- 'LATE_RETURN','FUEL','DAMAGE','TRAFFIC_FINE','EXCESS_MILEAGE','CLEANING','GPS_VIOLATION'
    description               TEXT,
    amount                       NUMERIC(12,2) NOT NULL,
    currency_code                  CHAR(3) REFERENCES currency(code),
    is_billed                        BOOLEAN NOT NULL DEFAULT FALSE,
    created_by                         UUID REFERENCES app_user(id),
    created_at                            TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- SECTION 7: FINANCE & ACCOUNTING (Invoices, Payments, Ledger, Tax)
-- ============================================================================

-- Minimal but real chart of accounts so the system can post double-entry
-- journal lines automatically (automated accounting requirement).
CREATE TABLE chart_of_account (
    id                  SERIAL PRIMARY KEY,
    branch_id             INTEGER REFERENCES branch(id),        -- NULL = shared across branches (consolidated COA)
    account_code            VARCHAR(20) NOT NULL,                -- '4000','2100'
    account_name              VARCHAR(100) NOT NULL,              -- 'Rental Revenue','VAT Payable'
    account_type                 VARCHAR(20) NOT NULL,              -- 'ASSET','LIABILITY','EQUITY','REVENUE','EXPENSE'
    parent_account_id              INTEGER REFERENCES chart_of_account(id),
    is_active                        BOOLEAN NOT NULL DEFAULT TRUE,
    UNIQUE (branch_id, account_code)
);

CREATE TABLE journal_entry (
    id                  BIGSERIAL PRIMARY KEY,
    branch_id             INTEGER NOT NULL REFERENCES branch(id),
    entry_date              DATE NOT NULL,
    reference_type             VARCHAR(30) NOT NULL,             -- 'INVOICE','PAYMENT','PAYOUT','EXPENSE','MANUAL'
    reference_id                 VARCHAR(60) NOT NULL,            -- e.g. invoice id
    description                    TEXT,
    currency_code                    CHAR(3) NOT NULL REFERENCES currency(code),
    posted_by                          UUID REFERENCES app_user(id),
    posted_at                            TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_reversed                            BOOLEAN NOT NULL DEFAULT FALSE,
    reversal_of_entry_id                     BIGINT REFERENCES journal_entry(id)
);

CREATE TABLE journal_entry_line (
    id                  BIGSERIAL PRIMARY KEY,
    journal_entry_id     BIGINT NOT NULL REFERENCES journal_entry(id) ON DELETE CASCADE,
    account_id              INTEGER NOT NULL REFERENCES chart_of_account(id),
    debit_amount               NUMERIC(14,2) NOT NULL DEFAULT 0,
    credit_amount                 NUMERIC(14,2) NOT NULL DEFAULT 0,
    memo                            TEXT,
    CHECK (debit_amount = 0 OR credit_amount = 0)   -- a line is either a debit or a credit, not both
);
CREATE INDEX idx_jel_entry ON journal_entry_line(journal_entry_id);
CREATE INDEX idx_jel_account ON journal_entry_line(account_id);

CREATE TABLE invoice (
    id                  SERIAL PRIMARY KEY,
    invoice_no            VARCHAR(30) UNIQUE NOT NULL,           -- generated via document_sequence
    branch_id               INTEGER NOT NULL REFERENCES branch(id),
    booking_id                INTEGER REFERENCES booking(id),
    booking_installment_id      INTEGER REFERENCES booking_installment(id), -- set when invoice is for one lease cycle
    customer_user_id              UUID NOT NULL REFERENCES app_user(id),
    issue_date                       DATE NOT NULL DEFAULT CURRENT_DATE,
    due_date                           DATE NOT NULL,
    subtotal_amount                      NUMERIC(14,2) NOT NULL DEFAULT 0,
    tax_amount                             NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_amount                             NUMERIC(14,2) NOT NULL DEFAULT 0,
    amount_paid                                NUMERIC(14,2) NOT NULL DEFAULT 0,
    currency_code                                CHAR(3) NOT NULL REFERENCES currency(code),
    status                                         VARCHAR(15) NOT NULL DEFAULT 'DRAFT', -- 'DRAFT','SENT','PARTIAL','PAID','OVERDUE','VOID'
    tax_rule_id_snapshot                             INTEGER REFERENCES tax_rule(id), -- which rule was applied
    pdf_url                                            TEXT,
    sent_via_email_at                                    TIMESTAMPTZ,
    sent_via_sms_at                                        TIMESTAMPTZ,
    created_at                                               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                                                 TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_invoice_customer ON invoice(customer_user_id);
CREATE INDEX idx_invoice_status ON invoice(branch_id, status, due_date);

CREATE TABLE invoice_line_item (
    id                  SERIAL PRIMARY KEY,
    invoice_id            INTEGER NOT NULL REFERENCES invoice(id) ON DELETE CASCADE,
    description             VARCHAR(200) NOT NULL,
    quantity                  NUMERIC(10,2) NOT NULL DEFAULT 1,
    unit_price                  NUMERIC(14,2) NOT NULL,
    line_total                    NUMERIC(14,2) NOT NULL,
    tax_rate_percent                NUMERIC(6,3) NOT NULL DEFAULT 0,
    account_id                        INTEGER REFERENCES chart_of_account(id) -- revenue account this maps to
);

CREATE TABLE payment_method (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(40) NOT NULL UNIQUE              -- 'MPESA_STK','MPESA_C2B','CASH','BANK_TRANSFER','CARD'
);

CREATE TABLE payment (
    id                  SERIAL PRIMARY KEY,
    receipt_no            VARCHAR(30) UNIQUE NOT NULL,          -- generated via document_sequence
    branch_id               INTEGER NOT NULL REFERENCES branch(id),
    invoice_id                INTEGER REFERENCES invoice(id),
    customer_user_id             UUID NOT NULL REFERENCES app_user(id),
    payment_method_id              INTEGER NOT NULL REFERENCES payment_method(id),
    amount                            NUMERIC(14,2) NOT NULL,
    currency_code                       CHAR(3) NOT NULL REFERENCES currency(code),
    external_reference                    VARCHAR(80),          -- M-Pesa receipt no / bank slip no
    mpesa_transaction_id                    VARCHAR(40),
    status                                    VARCHAR(15) NOT NULL DEFAULT 'CONFIRMED', -- 'PENDING','CONFIRMED','FAILED','REVERSED'
    paid_at                                    TIMESTAMPTZ NOT NULL DEFAULT now(),
    received_by                                  UUID REFERENCES app_user(id),
    pdf_receipt_url                                TEXT,
    created_at                                       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_payment_invoice ON payment(invoice_id);
CREATE INDEX idx_payment_customer ON payment(customer_user_id);

-- Raw inbound M-Pesa callback log — every Daraja callback stored verbatim
-- before processing, for reconciliation and replay/debugging.
CREATE TABLE mpesa_transaction_log (
    id                  BIGSERIAL PRIMARY KEY,
    direction             VARCHAR(10) NOT NULL,                 -- 'C2B','B2C','STK_PUSH'
    merchant_request_id     VARCHAR(60),
    checkout_request_id       VARCHAR(60),
    mpesa_receipt_number        VARCHAR(40),
    phone_number                   VARCHAR(20),
    amount                            NUMERIC(14,2),
    result_code                        INTEGER,
    result_desc                          TEXT,
    raw_payload                            JSONB NOT NULL,
    linked_payment_id                        INTEGER REFERENCES payment(id),
    linked_payout_run_id                       BIGINT REFERENCES investor_payout_run(id),
    received_at                                  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE credit_note (
    id                  SERIAL PRIMARY KEY,
    credit_note_no        VARCHAR(30) UNIQUE NOT NULL,
    invoice_id              INTEGER NOT NULL REFERENCES invoice(id),
    amount                     NUMERIC(14,2) NOT NULL,
    reason                       TEXT,
    issued_by                     UUID REFERENCES app_user(id),
    issued_at                       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE expense (
    id                  SERIAL PRIMARY KEY,
    branch_id             INTEGER NOT NULL REFERENCES branch(id),
    vehicle_id              INTEGER REFERENCES vehicle(id),       -- nullable for general/overhead expenses
    category                  VARCHAR(40) NOT NULL,                -- 'FUEL','MAINTENANCE','INSURANCE','SALARY','RENT','UTILITIES'
    amount                       NUMERIC(14,2) NOT NULL,
    currency_code                  CHAR(3) NOT NULL REFERENCES currency(code),
    expense_date                     DATE NOT NULL,
    vendor_name                        VARCHAR(100),
    receipt_doc_url                       TEXT,
    account_id                              INTEGER REFERENCES chart_of_account(id),
    approved_by                               UUID REFERENCES app_user(id),
    created_by                                  UUID REFERENCES app_user(id),
    created_at                                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- SECTION 8: COMMUNICATIONS (SMS via Africa's Talking, Email)
-- ============================================================================

-- Reusable message templates with placeholders, e.g. "{{customer_name}}".
-- Admin-editable per event type & channel — no code change to alter wording.
CREATE TABLE message_template (
    id                  SERIAL PRIMARY KEY,
    branch_id             INTEGER REFERENCES branch(id),         -- NULL = global default
    code                    VARCHAR(50) NOT NULL,                  -- 'BOOKING_CONFIRMED_SMS','INVOICE_DUE_EMAIL'
    channel                   VARCHAR(10) NOT NULL,                 -- 'SMS','EMAIL'
    subject                     VARCHAR(150),                        -- email only
    body_template                 TEXT NOT NULL,                       -- "Hi {{first_name}}, your booking {{booking_no}} is confirmed."
    language                        VARCHAR(10) NOT NULL DEFAULT 'en',
    is_active                         BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at                          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (branch_id, code, language)
);

CREATE TABLE sms_log (
    id                  BIGSERIAL PRIMARY KEY,
    branch_id             INTEGER REFERENCES branch(id),
    recipient_user_id       UUID REFERENCES app_user(id),
    recipient_phone           VARCHAR(20) NOT NULL,
    message_template_id        INTEGER REFERENCES message_template(id),
    message_body                  TEXT NOT NULL,
    provider                        VARCHAR(20) NOT NULL DEFAULT 'AFRICASTALKING',
    provider_message_id               VARCHAR(80),
    status                              VARCHAR(15) NOT NULL DEFAULT 'QUEUED', -- 'QUEUED','SENT','DELIVERED','FAILED'
    cost_amount                          NUMERIC(8,4),
    failure_reason                         TEXT,
    related_entity_type                      VARCHAR(40),                       -- 'booking','invoice','payout_run','lead'
    related_entity_id                          VARCHAR(40),
    sent_at                                      TIMESTAMPTZ,
    delivered_at                                   TIMESTAMPTZ,
    created_at                                       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_sms_log_entity ON sms_log(related_entity_type, related_entity_id);
CREATE INDEX idx_sms_log_status ON sms_log(status);

CREATE TABLE email_log (
    id                  BIGSERIAL PRIMARY KEY,
    branch_id             INTEGER REFERENCES branch(id),
    recipient_user_id       UUID REFERENCES app_user(id),
    recipient_email           VARCHAR(150) NOT NULL,
    message_template_id        INTEGER REFERENCES message_template(id),
    subject                      VARCHAR(200),
    body_html                      TEXT,
    attachment_urls                  JSONB,                          -- [{name:'Invoice.pdf', url:'...'}]
    status                              VARCHAR(15) NOT NULL DEFAULT 'QUEUED', -- 'QUEUED','SENT','FAILED','BOUNCED'
    provider_message_id                  VARCHAR(80),
    failure_reason                         TEXT,
    related_entity_type                      VARCHAR(40),
    related_entity_id                          VARCHAR(40),
    sent_at                                      TIMESTAMPTZ,
    created_at                                     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_email_log_entity ON email_log(related_entity_type, related_entity_id);

-- ============================================================================
-- SECTION 9: AUTOMATION RULE ENGINE
-- ============================================================================
-- Admin-defined trigger -> condition -> action rules. See
-- 04-automation-rules-engine.md for full evaluation logic and seed library.

CREATE TABLE automation_rule (
    id                  SERIAL PRIMARY KEY,
    branch_id             INTEGER REFERENCES branch(id),          -- NULL = applies to all branches
    name                    VARCHAR(120) NOT NULL,                  -- 'Send reminder 3 days before lease due'
    trigger_event             VARCHAR(50) NOT NULL,                  -- 'BOOKING_INSTALLMENT_DUE_SOON','VEHICLE_DOC_EXPIRING','LEAD_NO_CONTACT_24H', etc.
    trigger_offset_json         JSONB,                                 -- {unit:'days', value:-3} = 3 days before the event timestamp
    conditions_json                JSONB,                                 -- [{field:'booking.status', op:'=', value:'ACTIVE'}, ...] (AND'ed; groups support OR)
    actions_json                      JSONB NOT NULL,                       -- [{type:'SEND_SMS', template_code:'LEASE_DUE_REMINDER'}, {type:'CREATE_TASK',...}]
    is_active                            BOOLEAN NOT NULL DEFAULT TRUE,
    priority                                SMALLINT NOT NULL DEFAULT 100,    -- lower runs first
    created_by                                UUID REFERENCES app_user(id),
    created_at                                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE automation_rule_execution_log (
    id                  BIGSERIAL PRIMARY KEY,
    automation_rule_id    INTEGER NOT NULL REFERENCES automation_rule(id),
    related_entity_type     VARCHAR(40) NOT NULL,
    related_entity_id         VARCHAR(40) NOT NULL,
    matched                    BOOLEAN NOT NULL,
    actions_taken_json            JSONB,
    error_message                   TEXT,
    executed_at                       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_rule_exec_rule ON automation_rule_execution_log(automation_rule_id, executed_at);
-- Prevents double-firing the same rule for the same entity within a run window
CREATE UNIQUE INDEX uq_rule_entity_fired ON automation_rule_execution_log(automation_rule_id, related_entity_type, related_entity_id)
    WHERE matched = TRUE;

CREATE TABLE staff_task (
    id                  SERIAL PRIMARY KEY,
    title                 VARCHAR(150) NOT NULL,
    description             TEXT,
    assigned_to_user_id       UUID REFERENCES app_user(id),
    related_entity_type         VARCHAR(40),
    related_entity_id             VARCHAR(40),
    due_at                           TIMESTAMPTZ,
    status                             VARCHAR(15) NOT NULL DEFAULT 'OPEN', -- 'OPEN','IN_PROGRESS','DONE','CANCELLED'
    created_by_rule_id                   INTEGER REFERENCES automation_rule(id), -- NULL if manually created
    created_at                             TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at                             TIMESTAMPTZ
);
CREATE INDEX idx_task_assigned ON staff_task(assigned_to_user_id, status);

-- ============================================================================
-- SECTION 10: DOCUMENT TEMPLATES & GENERATED DOCUMENTS
-- ============================================================================

CREATE TABLE document_template (
    id                  SERIAL PRIMARY KEY,
    branch_id             INTEGER REFERENCES branch(id),          -- NULL = global default, branch can override
    document_type           VARCHAR(30) NOT NULL,                   -- 'RENTAL_AGREEMENT','INVOICE','RECEIPT','STATEMENT_CUSTOMER','STATEMENT_INVESTOR','CREDIT_NOTE'
    name                       VARCHAR(100) NOT NULL,
    body_template                TEXT NOT NULL,                       -- HTML w/ {{placeholders}} and {{#each}} blocks (Handlebars-style)
    version                         VARCHAR(20) NOT NULL DEFAULT '1.0',
    is_active                         BOOLEAN NOT NULL DEFAULT TRUE,
    created_at                          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (branch_id, document_type, version)
);

CREATE TABLE generated_document (
    id                  SERIAL PRIMARY KEY,
    document_template_id  INTEGER REFERENCES document_template(id),
    document_type            VARCHAR(30) NOT NULL,
    related_entity_type        VARCHAR(40) NOT NULL,                 -- 'invoice','payment','rental_agreement','investor_payout_run'
    related_entity_id            VARCHAR(40) NOT NULL,
    pdf_url                         TEXT NOT NULL,
    print_count                       INTEGER NOT NULL DEFAULT 0,
    last_printed_at                     TIMESTAMPTZ,
    generated_at                          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_gendoc_entity ON generated_document(related_entity_type, related_entity_id);

-- Now that generated_document exists, link investor_payout_run statement.
ALTER TABLE investor_payout_run ADD CONSTRAINT fk_payout_statement_doc
    FOREIGN KEY (statement_document_id) REFERENCES generated_document(id);

