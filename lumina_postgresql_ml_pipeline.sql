-- =====================================================================
-- LUMINA SPRINGS CORPORATION
-- Intelligent Predictive Email Intelligence and Communications
-- Operations Initiative
-- Use Case A: Consumer & Trade Email Prioritization, Escalation Risk,
-- and Remaining-Time-to-Critical-Event Estimation
--
-- PURE IN-DATABASE MACHINE LEARNING PIPELINE (PostgreSQL + PostgresML)
-- Consistent with Business Case Section 7.2 absolute constraint: all
-- storage, feature engineering, training, inference, monitoring, and
-- lineage occur exclusively inside PostgreSQL. Power BI is the sole
-- consumption layer on top of the views/tables produced here — no
-- external ML platforms, notebooks, or non-PostgreSQL scoring engines.
--
-- Companion file: lumina_email_intelligence_dataset.csv / .xlsx
-- (7,900 rows x 45 columns)
--
-- Tested design target: PostgreSQL 15+ with the PostgresML extension
-- (pgml). Where PostgresML is unavailable, equivalent MADlib calls are
-- noted in comments.
-- =====================================================================


-- =====================================================================
-- SECTION 0 — EXTENSIONS
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pgml;      -- PostgresML: pgml.train / pgml.predict
CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- audit hashing / row fingerprints
CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- trigram support for SQL-native text/entity matching


-- =====================================================================
-- SECTION 1 — SCHEMA DESIGN (modular, per Business Case Section 7.1/7.5)
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS raw;        -- landing zone for email + operational extracts
CREATE SCHEMA IF NOT EXISTS curated;    -- cleaned, conformed, governed data
CREATE SCHEMA IF NOT EXISTS features;   -- versioned feature tables
CREATE SCHEMA IF NOT EXISTS models;     -- model metadata / model cards
CREATE SCHEMA IF NOT EXISTS predictions;-- scoring outputs
CREATE SCHEMA IF NOT EXISTS monitoring; -- drift & performance tracking
CREATE SCHEMA IF NOT EXISTS bi;         -- Power BI-facing semantic views


-- =====================================================================
-- SECTION 2 — RAW LANDING TABLE (mirrors the Excel/CSV export exactly)
-- =====================================================================
DROP TABLE IF EXISTS raw.email_thread_snapshot CASCADE;

CREATE TABLE raw.email_thread_snapshot (
    email_thread_id                          TEXT PRIMARY KEY,
    mailbox                                  TEXT NOT NULL,
    channel_type                             TEXT,
    received_date                            DATE,
    sender_domain_type                       TEXT,
    region                                   TEXT,
    brand                                    TEXT,
    product_category                         TEXT,
    sku_id                                   TEXT,
    batch_lot_id                             TEXT,
    retailer_name                            TEXT,
    order_id                                 TEXT,
    promotion_code                           TEXT,
    thread_length_messages                   INTEGER,
    days_since_first_message                 NUMERIC(8,1),
    avg_response_latency_hours               NUMERIC(8,1),
    max_response_latency_hours               NUMERIC(8,1),
    sender_message_count_90d                 INTEGER,
    attachment_count                         INTEGER,
    attachment_size_mb_total                 NUMERIC(10,2),
    cc_recipient_count                       INTEGER,
    reply_all_flag                           CHAR(1),
    sentiment_score                          NUMERIC(5,3),
    negative_word_count                      INTEGER,
    urgency_keyword_count                    INTEGER,
    taste_keyword_flag                       CHAR(1),
    packaging_keyword_flag                   CHAR(1),
    shelf_life_keyword_flag                  CHAR(1),
    allergen_keyword_flag                    CHAR(1),
    availability_keyword_flag                CHAR(1),
    topic_primary                            TEXT,
    prior_complaints_count_sku_90d           INTEGER,
    prior_escalations_count_retailer_12m     INTEGER,
    batch_quality_deviation_flag             CHAR(1),
    sku_recent_quality_hold_flag             CHAR(1),
    retailer_tier                            TEXT,
    consumer_loyalty_tier                    TEXT,
    assigned_team                            TEXT,
    current_status                           TEXT,
    resolution_time_hours                    NUMERIC(10,1),
    resolution_touches_count                 INTEGER,
    commercial_credit_issued_usd             NUMERIC(12,2),
    escalated_flag                           CHAR(1),
    escalation_within_48h                    SMALLINT,
    hours_to_critical_event_or_censor        NUMERIC(8,1),
    load_batch_id                            BIGINT,
    loaded_at                                TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE raw.email_thread_snapshot IS
  'Landing table for Use Case A email-intelligence source extract. One row per email thread. Loaded via COPY from the governed CSV export. No ML processing occurs on this table directly — see features.email_features_v1.';

-- ---------------------------------------------------------------------
-- Load command (run from psql, adjust path to your local copy of the CSV)
-- ---------------------------------------------------------------------
-- \copy raw.email_thread_snapshot(email_thread_id, mailbox, channel_type, received_date,
--   sender_domain_type, region, brand, product_category, sku_id, batch_lot_id, retailer_name,
--   order_id, promotion_code, thread_length_messages, days_since_first_message,
--   avg_response_latency_hours, max_response_latency_hours, sender_message_count_90d,
--   attachment_count, attachment_size_mb_total, cc_recipient_count, reply_all_flag,
--   sentiment_score, negative_word_count, urgency_keyword_count, taste_keyword_flag,
--   packaging_keyword_flag, shelf_life_keyword_flag, allergen_keyword_flag,
--   availability_keyword_flag, topic_primary, prior_complaints_count_sku_90d,
--   prior_escalations_count_retailer_12m, batch_quality_deviation_flag,
--   sku_recent_quality_hold_flag, retailer_tier, consumer_loyalty_tier, assigned_team,
--   current_status, resolution_time_hours, resolution_touches_count,
--   commercial_credit_issued_usd, escalated_flag, escalation_within_48h,
--   hours_to_critical_event_or_censor)
-- FROM 'lumina_email_intelligence_dataset.csv' WITH (FORMAT csv, HEADER true);


-- =====================================================================
-- SECTION 3 — MASTER DATA / REFERENCE TABLES (Business Case Section 7.1)
-- Standard PostgreSQL constraints/triggers for core commercial &
-- manufacturing entities referenced by email threads.
-- =====================================================================
CREATE TABLE IF NOT EXISTS curated.dim_mailbox (
    mailbox       TEXT PRIMARY KEY,
    channel_type  TEXT NOT NULL,
    owning_function TEXT NOT NULL
);
INSERT INTO curated.dim_mailbox (mailbox, channel_type, owning_function) VALUES
    ('Consumer Care','Consumer Complaint','Sales & Customer Success'),
    ('Trade/Retailer','Retailer Inquiry','Sales & Customer Success'),
    ('Quality & Food Safety','Internal Escalation','Quality Assurance & Food Safety'),
    ('Supplier Relations','Supplier Notification','Supply Chain & Procurement')
ON CONFLICT (mailbox) DO NOTHING;

CREATE TABLE IF NOT EXISTS curated.dim_retailer (
    retailer_name TEXT PRIMARY KEY,
    retailer_tier TEXT
);
INSERT INTO curated.dim_retailer (retailer_name, retailer_tier) VALUES
    ('MegaMart','Platinum'), ('FreshCo Retail','Gold'), ('Coastal Grocers','Gold'),
    ('ValueStop','Silver'), ('GreenBasket','Bronze')
ON CONFLICT (retailer_name) DO NOTHING;

-- Entity-resolution helper: fuzzy-match a free-text sender/retailer name to the
-- master retailer dimension using pg_trgm similarity (fully SQL-native).
CREATE OR REPLACE FUNCTION curated.fn_resolve_retailer(input_name TEXT)
RETURNS TEXT AS $$
    SELECT retailer_name
    FROM curated.dim_retailer
    ORDER BY similarity(retailer_name, input_name) DESC
    LIMIT 1;
$$ LANGUAGE sql IMMUTABLE;


-- =====================================================================
-- SECTION 4 — DATA QUALITY FRAMEWORK (Business Case Section 7.1)
-- Automated completeness / validity / referential-integrity / entity-
-- resolution-confidence checks with quarantine table.
-- =====================================================================
CREATE TABLE IF NOT EXISTS monitoring.dq_quarantine (
    quarantine_id   BIGSERIAL PRIMARY KEY,
    email_thread_id TEXT,
    rule_violated   TEXT,
    detail          TEXT,
    quarantined_at  TIMESTAMPTZ DEFAULT now()
);

CREATE OR REPLACE FUNCTION monitoring.run_data_quality_checks()
RETURNS TABLE(rule_violated TEXT, violation_count BIGINT) AS $$
BEGIN
    -- Rule 1: completeness on mandatory identifiers
    INSERT INTO monitoring.dq_quarantine (email_thread_id, rule_violated, detail)
    SELECT email_thread_id, 'missing_mailbox', 'mailbox is null'
    FROM raw.email_thread_snapshot WHERE mailbox IS NULL;

    -- Rule 2: validity — sentiment_score must be within [-1, 1]
    INSERT INTO monitoring.dq_quarantine (email_thread_id, rule_violated, detail)
    SELECT email_thread_id, 'invalid_sentiment_score', sentiment_score::TEXT
    FROM raw.email_thread_snapshot
    WHERE sentiment_score IS NOT NULL AND (sentiment_score < -1 OR sentiment_score > 1);

    -- Rule 3: uniqueness of email_thread_id (defence in depth beyond the PK)
    INSERT INTO monitoring.dq_quarantine (email_thread_id, rule_violated, detail)
    SELECT email_thread_id, 'duplicate_thread_id', 'count>1'
    FROM (SELECT email_thread_id, COUNT(*) c FROM raw.email_thread_snapshot GROUP BY email_thread_id HAVING COUNT(*) > 1) d;

    -- Rule 4: referential integrity — mailbox must exist in the dimension
    INSERT INTO monitoring.dq_quarantine (email_thread_id, rule_violated, detail)
    SELECT s.email_thread_id, 'unknown_mailbox', s.mailbox
    FROM raw.email_thread_snapshot s
    LEFT JOIN curated.dim_mailbox d ON d.mailbox = s.mailbox
    WHERE d.mailbox IS NULL;

    -- Rule 5: entity-resolution confidence — trade threads should resolve to a
    -- known retailer with reasonable trigram similarity
    INSERT INTO monitoring.dq_quarantine (email_thread_id, rule_violated, detail)
    SELECT s.email_thread_id, 'low_confidence_retailer_match',
           'best_match=' || curated.fn_resolve_retailer(s.retailer_name)
    FROM raw.email_thread_snapshot s
    WHERE s.mailbox = 'Trade/Retailer'
      AND similarity(s.retailer_name, curated.fn_resolve_retailer(s.retailer_name)) < 0.5;

    RETURN QUERY
    SELECT q.rule_violated, COUNT(*)::BIGINT
    FROM monitoring.dq_quarantine q
    WHERE q.quarantined_at > now() - INTERVAL '1 hour'
    GROUP BY q.rule_violated;
END;
$$ LANGUAGE plpgsql;

-- Run once after each load: SELECT * FROM monitoring.run_data_quality_checks();


-- =====================================================================
-- SECTION 5 — CURATED TABLE (cleaned, typed, partitioned by received date)
-- Multi-year historical depth via range partitioning, per Section 7.1.
-- =====================================================================
CREATE TABLE IF NOT EXISTS curated.email_threads (
    LIKE raw.email_thread_snapshot INCLUDING DEFAULTS
) PARTITION BY RANGE (received_date);

CREATE TABLE IF NOT EXISTS curated.email_threads_2025h2
    PARTITION OF curated.email_threads
    FOR VALUES FROM ('2025-07-01') TO ('2026-01-01');
CREATE TABLE IF NOT EXISTS curated.email_threads_2026h1
    PARTITION OF curated.email_threads
    FOR VALUES FROM ('2026-01-01') TO ('2026-07-01');
CREATE TABLE IF NOT EXISTS curated.email_threads_2026h2
    PARTITION OF curated.email_threads
    FOR VALUES FROM ('2026-07-01') TO ('2027-01-01');

INSERT INTO curated.email_threads
SELECT s.*
FROM raw.email_thread_snapshot s
WHERE NOT EXISTS (SELECT 1 FROM monitoring.dq_quarantine q WHERE q.email_thread_id = s.email_thread_id);

CREATE INDEX IF NOT EXISTS idx_email_threads_mailbox ON curated.email_threads (mailbox);
CREATE INDEX IF NOT EXISTS idx_email_threads_region ON curated.email_threads (region);
CREATE INDEX IF NOT EXISTS idx_email_threads_sku ON curated.email_threads (sku_id);
CREATE INDEX IF NOT EXISTS idx_email_threads_received ON curated.email_threads (received_date);


-- =====================================================================
-- SECTION 6 — FEATURE ENGINEERING (pure SQL: window functions, CTEs,
-- simple text tokenization/frequency features)
-- Materialized into a versioned feature table, per Section 7.2.
-- =====================================================================
DROP TABLE IF EXISTS features.email_features_v1;

CREATE TABLE features.email_features_v1 AS
WITH base AS (
    SELECT
        t.*,
        m.owning_function,
        -- Encode categoricals as numeric flags PostgresML can consume directly
        CASE t.reply_all_flag              WHEN 'Y' THEN 1 ELSE 0 END AS reply_all_flag_num,
        CASE t.taste_keyword_flag          WHEN 'Y' THEN 1 ELSE 0 END AS taste_keyword_num,
        CASE t.packaging_keyword_flag      WHEN 'Y' THEN 1 ELSE 0 END AS packaging_keyword_num,
        CASE t.shelf_life_keyword_flag     WHEN 'Y' THEN 1 ELSE 0 END AS shelf_life_keyword_num,
        CASE t.allergen_keyword_flag       WHEN 'Y' THEN 1 ELSE 0 END AS allergen_keyword_num,
        CASE t.availability_keyword_flag   WHEN 'Y' THEN 1 ELSE 0 END AS availability_keyword_num,
        CASE t.batch_quality_deviation_flag WHEN 'Y' THEN 1 ELSE 0 END AS batch_quality_deviation_num,
        CASE t.sku_recent_quality_hold_flag WHEN 'Y' THEN 1 ELSE 0 END AS sku_quality_hold_num,
        -- Simple SQL-native text-derived intensity ratio (tokens per message)
        ROUND((t.negative_word_count + t.urgency_keyword_count)::NUMERIC
              / NULLIF(t.thread_length_messages, 0), 3)                  AS negative_urgency_per_message,
        -- Ratio / engineered signals
        ROUND(t.max_response_latency_hours
              / NULLIF(t.avg_response_latency_hours, 0), 3)              AS latency_volatility_ratio,
        ROUND(t.commercial_credit_issued_usd
              / NULLIF(t.resolution_touches_count, 0), 2)                AS credit_per_touch,
        -- Cohort z-score of sentiment vs. same mailbox (window function)
        ROUND((t.sentiment_score -
               AVG(t.sentiment_score) OVER (PARTITION BY t.mailbox)) /
               NULLIF(STDDEV(t.sentiment_score) OVER (PARTITION BY t.mailbox), 0), 3)
                                                                           AS sentiment_z_within_mailbox,
        NTILE(5) OVER (ORDER BY t.negative_word_count + t.urgency_keyword_count DESC)
                                                                           AS intensity_quintile,
        -- Rolling count of same-SKU threads in the trailing 30 days (window function)
        COUNT(*) OVER (PARTITION BY t.sku_id
                        ORDER BY t.received_date
                        RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW)
                                                                           AS sku_threads_trailing_30d
    FROM curated.email_threads t
    LEFT JOIN curated.dim_mailbox m ON m.mailbox = t.mailbox
)
SELECT * FROM base;

ALTER TABLE features.email_features_v1 ADD PRIMARY KEY (email_thread_id);

COMMENT ON TABLE features.email_features_v1 IS
  'Version 1 feature table for Use Case A. Built entirely in SQL (CTEs + window functions + simple text-frequency features) from curated.email_threads. Feeds pgml.train directly.';


-- =====================================================================
-- SECTION 7 — TRAIN / VALIDATION SPLIT (temporal-safe via date filter)
-- Business Case Section 7.2 specifies temporal splits via date filters
-- as the preferred SQL-expressible validation technique.
-- =====================================================================
ALTER TABLE features.email_features_v1
  ADD COLUMN IF NOT EXISTS data_split TEXT;

UPDATE features.email_features_v1
SET data_split = CASE
    WHEN received_date < DATE '2026-06-01' THEN 'train'
    WHEN received_date < DATE '2026-08-01' THEN 'validation'
    ELSE 'test'
END;


-- =====================================================================
-- SECTION 8 — IN-DATABASE MODEL TRAINING (PostgresML)
-- Algorithm choice: gradient-boosted trees (xgboost), within the
-- Business-Case-approved algorithm family (Section 7.2).
-- =====================================================================
SELECT pgml.train(
    project_name    => 'lumina_email_escalation_48h',
    task            => 'classification',
    relation_name   => 'features.email_features_v1',
    y_column_name   => 'escalation_within_48h',
    algorithm       => 'xgboost',
    hyperparams     => '{
        "n_estimators": 300,
        "max_depth": 6,
        "learning_rate": 0.05,
        "subsample": 0.8,
        "colsample_bytree": 0.8
    }'::jsonb,
    test_size       => 0.15,
    test_sampling   => 'random'
);

-- Optional challenger model for comparison (regularized logistic regression) —
-- valuable here because linear models are more directly explainable to the
-- Quality & Food Safety Board and easier to defend under regulatory scrutiny.
SELECT pgml.train(
    project_name    => 'lumina_email_escalation_48h',
    task            => 'classification',
    relation_name   => 'features.email_features_v1',
    y_column_name   => 'escalation_within_48h',
    algorithm       => 'linear',
    hyperparams     => '{"penalty": "l2"}'::jsonb,
    test_size       => 0.15,
    test_sampling   => 'random'
);

-- Inspect trained model performance:
-- SELECT * FROM pgml.overview WHERE project_name = 'lumina_email_escalation_48h';


-- =====================================================================
-- SECTION 9 — MODEL CARD (structured metadata, Business Case Section 7.2)
-- =====================================================================
CREATE TABLE IF NOT EXISTS models.model_card (
    model_id                 BIGSERIAL PRIMARY KEY,
    project_name             TEXT NOT NULL,
    model_version             TEXT NOT NULL,
    algorithm                 TEXT NOT NULL,
    training_data_summary      TEXT,
    hyperparameters            JSONB,
    performance_metrics         JSONB,
    intended_use                TEXT,
    known_limitations           TEXT,
    data_privacy_considerations  TEXT,
    food_safety_considerations    TEXT,
    trained_at                    TIMESTAMPTZ DEFAULT now(),
    approved_by                   TEXT,
    risk_classification            TEXT  -- 'Standard' | 'Elevated' per Section 7.4
);

INSERT INTO models.model_card
(project_name, model_version, algorithm, training_data_summary, hyperparameters,
 performance_metrics, intended_use, known_limitations, data_privacy_considerations,
 food_safety_considerations, risk_classification)
VALUES (
    'lumina_email_escalation_48h', 'v1_xgboost',
    'xgboost (gradient-boosted trees)',
    '7,900 email threads, 45 source attributes, trailing 12 months to 2026-09-01, temporal train/validation/test split (train < 2026-06-01, validation < 2026-08-01, test >= 2026-08-01)',
    '{"n_estimators":300,"max_depth":6,"learning_rate":0.05,"subsample":0.8,"colsample_bytree":0.8}'::jsonb,
    '{"note":"populate from pgml.overview / pgml.predict against the test split after training"}'::jsonb,
    'Ranks consumer, trade, quality, and supplier email threads by 48-hour escalation risk to prioritize consumer-care and quality triage. Not a sole basis for consumer-safety advisories, product holds, or withdrawal decisions.',
    'Trained on a single synthetic snapshot; retrain on rolling production email volumes before go-live. Elevated-risk threads (allergen/food-safety keyword flags) require mandatory human review per Section 7.2.',
    'Model inputs may include personal or commercially sensitive content extracted from consumer/retailer correspondence; access is restricted via role-based controls (Section 7.1) and no raw email body text is persisted beyond derived, governed features.',
    'Threads flagged allergen_keyword_flag = Y or sku_recent_quality_hold_flag = Y are elevated-risk under Section 7.2 and require Quality & Food Safety Board sign-off before any model-informed action is taken.',
    'Elevated'
);


-- =====================================================================
-- SECTION 10 — SCORING / INFERENCE (predictions written back to PostgreSQL)
-- =====================================================================
CREATE TABLE IF NOT EXISTS predictions.email_escalation_scores (
    email_thread_id           TEXT PRIMARY KEY REFERENCES curated.email_threads(email_thread_id) ON DELETE CASCADE,
    model_version              TEXT NOT NULL,
    predicted_probability       NUMERIC(6,5),
    predicted_class              SMALLINT,
    risk_tier                     TEXT,
    requires_human_review          BOOLEAN,
    scored_at                      TIMESTAMPTZ DEFAULT now()
);

INSERT INTO predictions.email_escalation_scores
    (email_thread_id, model_version, predicted_probability, predicted_class, risk_tier, requires_human_review)
SELECT
    f.email_thread_id,
    'v1_xgboost',
    pgml.predict('lumina_email_escalation_48h', f.*)::NUMERIC(6,5)               AS predicted_probability,
    ROUND(pgml.predict('lumina_email_escalation_48h', f.*))::SMALLINT            AS predicted_class,
    CASE
        WHEN pgml.predict('lumina_email_escalation_48h', f.*) >= 0.55 THEN 'Critical'
        WHEN pgml.predict('lumina_email_escalation_48h', f.*) >= 0.30 THEN 'High'
        WHEN pgml.predict('lumina_email_escalation_48h', f.*) >= 0.12 THEN 'Medium'
        ELSE 'Low'
    END AS risk_tier,
    -- Mandatory human review for elevated-risk categories per the model card
    (f.allergen_keyword_num = 1 OR f.sku_quality_hold_num = 1
     OR pgml.predict('lumina_email_escalation_48h', f.*) >= 0.55)                AS requires_human_review
FROM features.email_features_v1 f
ON CONFLICT (email_thread_id) DO UPDATE SET
    model_version = EXCLUDED.model_version,
    predicted_probability = EXCLUDED.predicted_probability,
    predicted_class = EXCLUDED.predicted_class,
    risk_tier = EXCLUDED.risk_tier,
    requires_human_review = EXCLUDED.requires_human_review,
    scored_at = now();

-- NOTE: pgml.predict's exact call signature (row vs. array of feature
-- values) depends on your installed PostgresML version — see the
-- pgml.predict documentation for your instance and adjust the SELECT
-- list of feature columns accordingly if row-type prediction is not
-- supported in your version.


-- =====================================================================
-- SECTION 11 — MONITORING: DATA DRIFT & PERFORMANCE DEGRADATION (pure SQL)
-- =====================================================================
CREATE TABLE IF NOT EXISTS monitoring.feature_drift_log (
    check_id        BIGSERIAL PRIMARY KEY,
    feature_name    TEXT,
    baseline_mean   NUMERIC,
    current_mean    NUMERIC,
    pct_change      NUMERIC,
    drift_flag      BOOLEAN,
    checked_at      TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS monitoring.feature_baseline (
    feature_name  TEXT PRIMARY KEY,
    baseline_mean NUMERIC
);

INSERT INTO monitoring.feature_baseline (feature_name, baseline_mean)
SELECT 'negative_word_count', AVG(negative_word_count) FROM features.email_features_v1
ON CONFLICT (feature_name) DO UPDATE SET baseline_mean = EXCLUDED.baseline_mean;

INSERT INTO monitoring.feature_baseline (feature_name, baseline_mean)
SELECT 'avg_response_latency_hours', AVG(avg_response_latency_hours) FROM features.email_features_v1
ON CONFLICT (feature_name) DO UPDATE SET baseline_mean = EXCLUDED.baseline_mean;

INSERT INTO monitoring.feature_baseline (feature_name, baseline_mean)
SELECT 'sentiment_score', AVG(sentiment_score) FROM features.email_features_v1
ON CONFLICT (feature_name) DO UPDATE SET baseline_mean = EXCLUDED.baseline_mean;

CREATE OR REPLACE FUNCTION monitoring.check_feature_drift(threshold_pct NUMERIC DEFAULT 15.0)
RETURNS VOID AS $$
DECLARE
    r RECORD;
    cur_mean NUMERIC;
    pct NUMERIC;
BEGIN
    FOR r IN SELECT * FROM monitoring.feature_baseline LOOP
        EXECUTE format('SELECT AVG(%I) FROM features.email_features_v1', r.feature_name)
            INTO cur_mean;
        pct := ROUND(100.0 * (cur_mean - r.baseline_mean) / NULLIF(r.baseline_mean, 0), 2);
        INSERT INTO monitoring.feature_drift_log (feature_name, baseline_mean, current_mean, pct_change, drift_flag)
        VALUES (r.feature_name, r.baseline_mean, cur_mean, pct, ABS(pct) > threshold_pct);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Schedule after each new snapshot load: SELECT monitoring.check_feature_drift();

CREATE TABLE IF NOT EXISTS monitoring.prediction_distribution_log (
    log_id            BIGSERIAL PRIMARY KEY,
    risk_tier         TEXT,
    thread_count      BIGINT,
    avg_probability   NUMERIC(6,5),
    logged_at         TIMESTAMPTZ DEFAULT now()
);

INSERT INTO monitoring.prediction_distribution_log (risk_tier, thread_count, avg_probability)
SELECT risk_tier, COUNT(*), ROUND(AVG(predicted_probability), 5)
FROM predictions.email_escalation_scores
GROUP BY risk_tier;


-- =====================================================================
-- SECTION 12 — HUMAN-IN-THE-LOOP OVERRIDE CAPTURE (Section 7.2)
-- =====================================================================
CREATE TABLE IF NOT EXISTS predictions.human_review_feedback (
    review_id                  BIGSERIAL PRIMARY KEY,
    email_thread_id            TEXT REFERENCES curated.email_threads(email_thread_id),
    reviewer_name               TEXT,
    reviewer_function            TEXT,   -- e.g. 'Quality & Food Safety', 'Consumer Care'
    model_predicted_class         SMALLINT,
    reviewer_override_class        SMALLINT,
    override_reason                 TEXT,
    reviewed_at                      TIMESTAMPTZ DEFAULT now()
);
-- This table is the closed-loop feedback source for future retraining
-- cycles (Section 7.2: "feedback available for subsequent training cycles").


-- =====================================================================
-- SECTION 13 — SEMANTIC LAYER FOR POWER BI (bi schema; consumption-only)
-- =====================================================================
CREATE OR REPLACE VIEW bi.vw_thread_risk_overview AS
SELECT
    t.email_thread_id, t.mailbox, t.channel_type, t.received_date, t.region, t.brand,
    t.product_category, t.sku_id, t.batch_lot_id, t.retailer_name, t.retailer_tier,
    t.topic_primary, t.sentiment_score, t.negative_word_count, t.urgency_keyword_count,
    t.allergen_keyword_flag, t.packaging_keyword_flag, t.shelf_life_keyword_flag,
    t.avg_response_latency_hours, t.thread_length_messages, t.current_status,
    t.commercial_credit_issued_usd,
    p.predicted_probability, p.predicted_class, p.risk_tier, p.requires_human_review,
    p.model_version, p.scored_at,
    t.escalation_within_48h AS actual_escalation_within_48h   -- retained for backtesting/model-quality visuals
FROM curated.email_threads t
LEFT JOIN predictions.email_escalation_scores p ON p.email_thread_id = t.email_thread_id;

CREATE OR REPLACE VIEW bi.vw_risk_tier_summary AS
SELECT region, mailbox, risk_tier, COUNT(*) AS thread_count,
       ROUND(AVG(predicted_probability), 4) AS avg_predicted_probability
FROM bi.vw_thread_risk_overview
GROUP BY region, mailbox, risk_tier;

CREATE OR REPLACE VIEW bi.vw_model_quality_backtest AS
SELECT
    model_version,
    COUNT(*) AS scored_threads,
    SUM(CASE WHEN predicted_class = actual_escalation_within_48h THEN 1 ELSE 0 END)::NUMERIC
        / COUNT(*) AS accuracy,
    SUM(CASE WHEN predicted_class = 1 AND actual_escalation_within_48h = 1 THEN 1 ELSE 0 END)::NUMERIC
        / NULLIF(SUM(CASE WHEN predicted_class = 1 THEN 1 ELSE 0 END), 0) AS precision,
    SUM(CASE WHEN predicted_class = 1 AND actual_escalation_within_48h = 1 THEN 1 ELSE 0 END)::NUMERIC
        / NULLIF(SUM(CASE WHEN actual_escalation_within_48h = 1 THEN 1 ELSE 0 END), 0) AS recall
FROM bi.vw_thread_risk_overview
GROUP BY model_version;

CREATE OR REPLACE VIEW bi.vw_data_quality_summary AS
SELECT rule_violated, COUNT(*) AS violation_count, MAX(quarantined_at) AS last_seen
FROM monitoring.dq_quarantine
GROUP BY rule_violated;

CREATE OR REPLACE VIEW bi.vw_drift_monitor AS
SELECT feature_name, baseline_mean, current_mean, pct_change, drift_flag, checked_at
FROM monitoring.feature_drift_log;

CREATE OR REPLACE VIEW bi.vw_human_review_queue AS
SELECT r.email_thread_id, r.mailbox, r.region, r.retailer_name, r.topic_primary,
       r.predicted_probability, r.risk_tier, r.requires_human_review
FROM bi.vw_thread_risk_overview r
WHERE r.requires_human_review = TRUE;

-- Grant read-only access to the Power BI service account (adjust role name):
-- CREATE ROLE powerbi_reader LOGIN PASSWORD '<use a secrets manager, not plaintext>';
-- GRANT USAGE ON SCHEMA bi TO powerbi_reader;
-- GRANT SELECT ON ALL TABLES IN SCHEMA bi TO powerbi_reader;
-- ALTER DEFAULT PRIVILEGES IN SCHEMA bi GRANT SELECT ON TABLES TO powerbi_reader;


-- =====================================================================
-- SECTION 14 — SCHEDULED RETRAINING TRIGGER STUB (pg_cron)
-- Requires the pg_cron extension; illustrates threshold-based retraining
-- per Section 7.2 ("retraining triggered by scheduled SQL jobs or simple
-- threshold-based conditions").
-- =====================================================================
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('lumina_daily_drift_check', '0 5 * * *',
--     $$ SELECT monitoring.check_feature_drift(); $$);
-- SELECT cron.schedule('lumina_weekly_retrain_check', '0 6 * * 1',
--     $$ SELECT pgml.train(project_name => 'lumina_email_escalation_48h',
--                           task => 'classification',
--                           relation_name => 'features.email_features_v1',
--                           y_column_name => 'escalation_within_48h',
--                           algorithm => 'xgboost'); $$);

-- =====================================================================
-- END OF SCRIPT
-- =====================================================================
