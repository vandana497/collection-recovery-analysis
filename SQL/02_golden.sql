-- ============================================================================
-- GOLDEN LAYER
-- Purpose: business-logic layer. Joins staging tables through account_id
-- (the only trustworthy key), builds a unified interaction fact, and computes
-- INDEPENDENT metric definitions (not trusting any pre-existing "reported"
-- numbers).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- golden_interactions: one row per outbound attempt/touch, any channel.
-- This is the backbone for contact rate, RPC, channel conversion, etc.
-- Channel definitions:
--   VOICE    -> call_attempts (every dial, connected or not)
--   WHATSAPP -> whatsapp_events (outbound sends only, event_type='SENT')
--   SMS      -> sms_events (outbound sends only, event_type='SENT')
--   FIELD    -> field_visits
-- "Contact" = a human/borrower response was registered:
--   VOICE: attempt_status = 'CONNECTED'
--   WHATSAPP/SMS: event_type IN ('DELIVERED','READ','REPLIED') -- see below
--   FIELD: outcome != 'NOT_HOME' (borrower was actually met)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE golden_interactions AS
SELECT
    'VOICE' AS channel,
    ca.attempt_id AS interaction_id,
    ca.account_id,
    a.borrower_id,
    ca.agent_id,
    ca.event_at,
    DATE_TRUNC('month', ca.event_at) AS month,
    (ca.attempt_status = 'CONNECTED') AS is_contact
FROM stg_call_attempts ca
JOIN stg_accounts a ON a.account_id = ca.account_id

UNION ALL

SELECT
    'WHATSAPP', w.whatsapp_event_id, w.account_id, a.borrower_id, NULL,
    w.event_at, DATE_TRUNC('month', w.event_at),
    (w.event_type IN ('DELIVERED','READ','REPLIED'))
FROM stg_whatsapp_events w
JOIN stg_accounts a ON a.account_id = w.account_id
WHERE w.event_type != 'FAILED'   -- FAILED sends were never delivered, not a real touch

UNION ALL

SELECT
    'SMS', s.sms_event_id, s.account_id, a.borrower_id, NULL,
    s.event_at, DATE_TRUNC('month', s.event_at),
    (s.event_type IN ('DELIVERED','READ','REPLIED'))
FROM stg_sms_events s
JOIN stg_accounts a ON a.account_id = s.account_id
WHERE s.event_type != 'FAILED'

UNION ALL

SELECT
    'FIELD', f.visit_id, f.account_id, a.borrower_id, f.agent_id,
    f.event_at, DATE_TRUNC('month', f.event_at),
    -- FIXED: real outcome values are PAID/CONTACTED/REFUSED/PTP (person was
    -- reached) vs NOT_AVAILABLE/WRONG_ADDRESS (person was NOT reached).
    -- Earlier version checked for 'NOT_HOME' which doesn't exist in this
    -- data, so every field visit was silently counted as a contact.
    (f.outcome IN ('PAID','CONTACTED','REFUSED','PTP'))
FROM stg_field_visits f
JOIN stg_accounts a ON a.account_id = f.account_id;

-- ----------------------------------------------------------------------------
-- golden_ptp: promises to pay, joined to whether they were actually kept
-- (a payment recognized for that account within 3 days of promised_date).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE golden_ptp AS
SELECT
    p.ptp_id, p.account_id, p.agent_id, p.event_at, p.promised_amount, p.promised_date,
    DATE_TRUNC('month', p.event_at) AS month,
    -- Widened to a 14-day post-promise window (industry-standard PTP-kept
    -- definition). An earlier ±3-day window was tested and returned <1% kept
    -- rates industry-wide -- implausible vs. typical 40-70% PTP-kept rates --
    -- because median PTP-to-payment gap in this data is 56 days, not <3.
    EXISTS (
        SELECT 1 FROM stg_payments pay
        WHERE pay.account_id = p.account_id
          AND pay.is_recognized_recovery
          AND pay.event_at BETWEEN p.promised_date - INTERVAL '2 day'
                                AND p.promised_date + INTERVAL '14 days'
    ) AS was_kept
FROM stg_promises_to_pay p;

-- ----------------------------------------------------------------------------
-- golden_monthly_metrics: the independent metric set that answers Q3.
-- Definitions (documented rationale in the memo / DQ report):
--   contact_rate        = contacted interactions / total interaction attempts
--   rpc                 = right-party contact: a VOICE contact where the
--                         disposition was NOT 'WRONG_NUMBER' -> proxy since
--                         we lack an explicit "right party" flag
--   ptp_rate             = PTPs / voice contacts (a PTP requires a conversation)
--   ptp_kept_rate         = PTPs kept / PTPs made
--   recovery              = SUM(amount) from stg_payments WHERE is_recognized_recovery
--   accounts_worked       = distinct accounts touched that month
--   recovery_per_account  = recovery / accounts_worked
--   agent_hours            = SUM(session duration) from stg_agent_sessions
--   recovery_per_agent_hr = recovery / agent_hours
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE golden_monthly_metrics AS
WITH interactions AS (
    SELECT month,
        COUNT(*) AS total_attempts,
        SUM(is_contact::INT) AS total_contacts,
        COUNT(DISTINCT account_id) AS accounts_worked
    FROM golden_interactions GROUP BY 1
),
voice_contacts AS (
    SELECT DATE_TRUNC('month', event_at) AS month, COUNT(*) AS voice_contacts
    FROM stg_call_attempts WHERE attempt_status='CONNECTED' GROUP BY 1
),
rpc AS (
    -- RPC rate is computed WITHIN dispositioned calls (its own natural
    -- denominator), not against call_attempts -- the two tables are different
    -- grains (calls vs. every dial attempt) and mixing them gave a >100% rate.
    SELECT DATE_TRUNC('month', d.event_at) AS month,
        COUNT(*) AS dispositioned_calls,
        SUM((d.disposition_code_norm NOT IN ('WRONG_NUMBER','NO_CONTACT'))::INT) AS rpc_count
    FROM stg_call_dispositions d
    GROUP BY 1
),
ptp AS (
    SELECT month, COUNT(*) AS ptp_count, SUM(was_kept::INT) AS ptp_kept
    FROM golden_ptp GROUP BY 1
),
recovery AS (
    SELECT DATE_TRUNC('month', event_at) AS month, SUM(amount) AS recovery_amt, COUNT(*) AS recovery_txns
    FROM stg_payments WHERE is_recognized_recovery GROUP BY 1
),
agent_hrs AS (
    SELECT DATE_TRUNC('month', login_at_ist) AS month,
           SUM(DATE_DIFF('minute', login_at_ist, logout_at_ist))/60.0 AS agent_hours
    FROM stg_agent_sessions GROUP BY 1
)
SELECT
    i.month,
    i.total_attempts, i.total_contacts,
    ROUND(i.total_contacts::DOUBLE / NULLIF(i.total_attempts,0), 4) AS contact_rate,
    r.rpc_count, r.dispositioned_calls,
    ROUND(r.rpc_count::DOUBLE / NULLIF(r.dispositioned_calls,0), 4) AS rpc_rate,
    p.ptp_count,
    ROUND(p.ptp_count::DOUBLE / NULLIF(vc.voice_contacts,0), 4) AS ptp_rate,
    p.ptp_kept,
    ROUND(p.ptp_kept::DOUBLE / NULLIF(p.ptp_count,0), 4) AS ptp_kept_rate,
    rec.recovery_amt, rec.recovery_txns,
    i.accounts_worked,
    ROUND(rec.recovery_amt / NULLIF(i.accounts_worked,0), 2) AS recovery_per_account,
    ah.agent_hours,
    ROUND(rec.recovery_amt / NULLIF(ah.agent_hours,0), 2) AS recovery_per_agent_hour
FROM interactions i
LEFT JOIN voice_contacts vc ON vc.month = i.month
LEFT JOIN rpc r ON r.month = i.month
LEFT JOIN ptp p ON p.month = i.month
LEFT JOIN recovery rec ON rec.month = i.month
LEFT JOIN agent_hrs ah ON ah.month = i.month
ORDER BY i.month;