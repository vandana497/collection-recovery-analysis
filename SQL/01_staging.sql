-- STAGING LAYER
-- Purpose: one-to-one cleanup of each raw source. No cross-table joins yet.
-- Every transformation here is deduplication / normalization, not business logic.

-- stg_accounts
-- accounts.csv is the ONE clean, 1:1 dimension in the whole dataset (30,000) rows = 30,000 distinct account_id, no nulls in key fields). 
-- It is treated as the single source of truth for account_id -> borrower_id.

CREATE OR REPLACE TABLE stg_accounts AS
SELECT
    account_id,
    borrower_id,                       -- SOURCE OF TRUTH for this mapping
    loan_type,
    principal_amount,
    outstanding_amount,
    dpd,
    risk_segment,
    status,
    opened_at,
    timezone,
    schema_version
FROM accounts;

-- ----------------------------------------------------------------------------
-- stg_borrowers
-- FINDING: 30,600 rows but only 11,015 distinct borrower_id. For a repeated
-- borrower_id, name/phone/email/city/state are RANDOMIZED across rows (not a
-- genuine change history) -> attributes below are LOW CONFIDENCE.
-- Resolution: dedupe to one row per borrower_id using a deterministic tie-break
-- (most recently created_at, then lowest row hash) purely for reproducibility.
-- Geography/demographic cuts built on this table must be flagged low-confidence
-- in every downstream analysis.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_borrowers AS
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY borrower_id
            ORDER BY created_at DESC, name, phone
        ) AS rn
    FROM borrowers
    WHERE borrower_id IS NOT NULL
)
SELECT borrower_id, name, phone, email, city, state, created_at, updated_at
FROM ranked WHERE rn = 1;

-- ----------------------------------------------------------------------------
-- stg_agents
-- FINDING: 30,000 rows but only 1,000 distinct agent_id; employee_code is NOT
-- a stable identity (one code maps to 40+ agent_ids). All descriptive fields
-- (name/team/vendor/status) are randomized per agent_id -> LOW CONFIDENCE.
-- Resolution: agent_id is the only trustworthy key. We derive "team" and
-- "vendor_id" by MODE (most frequent value) across the 30 rows per agent, as
-- a best-effort central tendency -- not a claim of truth. joined_at = min.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_agents AS
WITH modes AS (
    SELECT agent_id,
        MIN(joined_at) AS joined_at,
        MAX(updated_at) AS last_seen_at,
        COUNT(*) AS n_raw_rows,
        COUNT(DISTINCT employee_code) AS n_distinct_emp_codes,
        COUNT(DISTINCT team) AS n_distinct_teams,
        COUNT(DISTINCT vendor_id) AS n_distinct_vendors,
        COUNT(DISTINCT status) AS n_distinct_statuses
    FROM agents GROUP BY agent_id
),
team_mode AS (
    SELECT agent_id, team, COUNT(*) c,
        ROW_NUMBER() OVER (PARTITION BY agent_id ORDER BY COUNT(*) DESC, team) rn
    FROM agents GROUP BY agent_id, team
),
vendor_mode AS (
    SELECT agent_id, vendor_id, COUNT(*) c,
        ROW_NUMBER() OVER (PARTITION BY agent_id ORDER BY COUNT(*) DESC, vendor_id) rn
    FROM agents GROUP BY agent_id, vendor_id
)
SELECT m.agent_id, m.joined_at, m.last_seen_at,
       t.team AS team_mode, v.vendor_id AS vendor_id_mode,
       m.n_raw_rows, m.n_distinct_teams, m.n_distinct_vendors,
       CASE WHEN m.n_distinct_teams <= 1 AND m.n_distinct_vendors <= 1
            THEN 'HIGH' ELSE 'LOW' END AS attribute_confidence
FROM modes m
JOIN team_mode t ON t.agent_id = m.agent_id AND t.rn = 1
JOIN vendor_mode v ON v.agent_id = m.agent_id AND v.rn = 1;

-- ----------------------------------------------------------------------------
-- stg_calls
-- FINDING: 91,350 rows -> 90,000 distinct call_id (exact duplicate injection).
-- FINDING: borrower_id is unreliable (98% mismatch vs accounts) -> dropped and
-- re-derived from stg_accounts. event_at normalized to Asia/Kolkata using the
-- row's own timezone label so hour/day-of-week analysis is meaningful.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_calls AS
WITH dedup AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY call_id ORDER BY event_at) rn
    FROM calls
)
SELECT
    call_id, account_id, agent_id, campaign_id, vendor_id,
    direction, call_status, duration_sec,
    event_at AS event_at_local_raw,
    timezone AS source_timezone,
    CASE timezone
        WHEN 'UTC' THEN event_at + INTERVAL '5 hours 30 minutes'
        WHEN 'Asia/Dubai' THEN event_at + INTERVAL '1 hour 30 minutes'
        ELSE event_at   -- already Asia/Kolkata
    END AS event_at_ist
FROM dedup WHERE rn = 1;

-- ----------------------------------------------------------------------------
-- stg_call_attempts (dedupe on attempt_id only; no timezone field provided,
-- inherits campaign/vendor context from stg_calls at golden layer)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_call_attempts AS
WITH dedup AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY attempt_id ORDER BY event_at) rn
    FROM call_attempts
)
SELECT attempt_id, account_id, call_id, agent_id, attempt_no, vendor_id,
       attempt_status, event_at
FROM dedup WHERE rn = 1;

-- ----------------------------------------------------------------------------
-- stg_call_dispositions
-- FINDING: legacy scheme has BOTH "PROMISE_TO_PAY" and "PTP" as separate
-- codes; v1/v2 only use "PTP". Treated as the same business event.
-- Normalized code mapping applied so trend lines aren't artifacts of the
-- disposition_version changing over time.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_call_dispositions AS
WITH dedup AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY disposition_id ORDER BY event_at) rn
    FROM call_dispositions
)
SELECT
    disposition_id, account_id, call_id, agent_id,
    disposition_version, disposition_code AS disposition_code_raw,
    CASE disposition_code
        WHEN 'PROMISE_TO_PAY' THEN 'PTP'
        ELSE disposition_code
    END AS disposition_code_norm,
    event_at
FROM dedup WHERE rn = 1;

-- ----------------------------------------------------------------------------
-- stg_payments  -- THE MOST IMPORTANT TABLE FOR THE "11%" CLAIM
-- FINDING #1: 500 exact duplicate payment_id rows -> drop.
-- FINDING #2: payment_reference retry-chains (same underlying transaction
-- attempted multiple times) with churning status FAILED/PENDING/SUCCESS/
-- REVERSED. Counting every SUCCESS row inflates recovery. Resolution:
-- collapse to ONE row per payment_reference (falling back to payment_id when
-- reference is null), taking the LATEST event as the final state, and
-- classifying it as "recognized" only if final status = SUCCESS.
-- REVERSED payments are explicitly excluded from recovery even if a SUCCESS
-- exists earlier in the chain (money went back out).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_payments AS
WITH id_dedup AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY payment_id ORDER BY event_at) rn
    FROM payments
),
ref_key AS (
    SELECT *, COALESCE(payment_reference, payment_id) AS dedup_key
    FROM id_dedup WHERE rn = 1
),
final_state AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY dedup_key ORDER BY event_at DESC) rn2,
        COUNT(*) OVER (PARTITION BY dedup_key) AS n_attempts_in_chain,
        BOOL_OR(payment_status = 'REVERSED') OVER (PARTITION BY dedup_key) AS ever_reversed
    FROM ref_key
)
SELECT
    payment_id, dedup_key AS payment_reference_key, account_id,
    event_at, amount, payment_status AS final_status, payment_method, provider_id,
    n_attempts_in_chain, ever_reversed,
    CASE WHEN payment_status = 'SUCCESS' AND NOT ever_reversed THEN TRUE ELSE FALSE END AS is_recognized_recovery
FROM final_state WHERE rn2 = 1;

-- ----------------------------------------------------------------------------
-- stg_promises_to_pay, stg_field_visits, stg_whatsapp_events, stg_sms_events,
-- stg_complaints, stg_account_status_history
-- Same treatment: dedupe on primary key, drop unreliable borrower_id (re-join
-- via account_id at golden layer instead).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_promises_to_pay AS
WITH dedup AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY ptp_id ORDER BY event_at) rn FROM promises_to_pay)
SELECT ptp_id, account_id, agent_id, event_at, promised_amount, promised_date, status, source
FROM dedup WHERE rn = 1;

CREATE OR REPLACE TABLE stg_field_visits AS
WITH dedup AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY visit_id ORDER BY event_at) rn FROM field_visits)
SELECT visit_id, account_id, agent_id, event_at, scheduled_at, visit_type, outcome, latitude, longitude
FROM dedup WHERE rn = 1;

CREATE OR REPLACE TABLE stg_whatsapp_events AS
WITH dedup AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY whatsapp_event_id ORDER BY event_at) rn FROM whatsapp_events)
SELECT whatsapp_event_id, account_id, event_at, message_id, event_type, template_code, provider_id
FROM dedup WHERE rn = 1;

CREATE OR REPLACE TABLE stg_sms_events AS
WITH dedup AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY sms_event_id ORDER BY event_at) rn FROM sms_events)
SELECT sms_event_id, account_id, event_at, message_id, event_type, template_code, provider_id
FROM dedup WHERE rn = 1;

CREATE OR REPLACE TABLE stg_complaints AS
WITH dedup AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY complaint_id ORDER BY event_at) rn FROM complaints)
SELECT complaint_id, account_id, event_at, complaint_type, severity, status, source, resolution_at
FROM dedup WHERE rn = 1;

CREATE OR REPLACE TABLE stg_account_status_history AS
WITH dedup AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY history_id ORDER BY recorded_at) rn FROM account_status_history)
SELECT history_id, account_id, event_at, status, changed_by, source, recorded_at
FROM dedup WHERE rn = 1;

CREATE OR REPLACE TABLE stg_daily_targeting AS
WITH dedup AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY target_id ORDER BY target_date) rn FROM daily_targeting)
SELECT target_id, account_id, campaign_id, target_date, priority, recommended_channel, status
FROM dedup WHERE rn = 1;

CREATE OR REPLACE TABLE stg_campaigns AS
SELECT campaign_id, campaign_name, channel, strategy_version, target_definition, start_at, end_at
FROM campaigns;

CREATE OR REPLACE TABLE stg_agent_sessions AS
WITH dedup AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY login_at) rn FROM agent_sessions)
SELECT session_id, agent_id, channel,
    CASE timezone WHEN 'UTC' THEN login_at + INTERVAL '5 hours 30 minutes' ELSE login_at END AS login_at_ist,
    CASE timezone WHEN 'UTC' THEN logout_at + INTERVAL '5 hours 30 minutes' ELSE logout_at END AS logout_at_ist
FROM dedup WHERE rn = 1;