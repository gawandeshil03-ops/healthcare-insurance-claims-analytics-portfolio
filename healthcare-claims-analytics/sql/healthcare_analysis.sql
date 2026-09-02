-- ===============================================================
-- PROJECT: Healthcare Insurance Claims Analytics
-- Author:  Dennis Aningu
-- Tool:    PostgreSQL 18
-- Dataset: Healthcare Dataset (55,500 patient records)
-- Source:  Kaggle - prasad22/healthcare-dataset
-- 
-- DESCRIPTION:
-- End-to-end SQL analysis of healthcare insurance claims data.
-- Covers summary statistics, insurer billing analysis, condition
-- cost rankings, anomaly detection, length of stay analysis,
-- and month-on-month admission trends.
--
-- SKILLS DEMONSTRATED:
-- CTEs, Window Functions (RANK, LAG, PARTITION BY),
-- Aggregate Functions, CASE statements, Date functions,
-- Statistical anomaly detection (Z-score method),
-- NULLIF for safe division, DATE_TRUNC, TO_CHAR
-- ================================================================





-- ================================================================
-- QUERY 1: DATASET OVERVIEW & SUMMARY STATISTICS
-- Purpose: Understand the full dataset before deeper analysis.
--          First step any analyst should run on a new dataset.
-- ================================================================

SELECT
    COUNT(*)                              AS total_patients,
    ROUND(AVG(age), 1)                    AS avg_age,
    MIN(age)                              AS youngest,
    MAX(age)                              AS oldest,
    ROUND(AVG(billing_amount), 2)         AS avg_billing,
    ROUND(MIN(billing_amount), 2)         AS min_billing,
    ROUND(MAX(billing_amount), 2)         AS max_billing,
    COUNT(DISTINCT hospital)              AS total_hospitals,
    COUNT(DISTINCT doctor)                AS total_doctors,
    COUNT(DISTINCT insurance_provider)    AS total_insurers,
    COUNT(DISTINCT medical_condition)     AS total_conditions
FROM patients;

-- KEY FINDINGS:
-- 55,500 patients | Age range: 13-89 | Avg billing: $25,539
-- Negative min billing (-$2,008) flagged as data anomaly
-- 5 insurance providers | 6 medical conditions





-- ================================================================
-- QUERY 2: BILLING ANALYSIS BY INSURANCE PROVIDER
-- Purpose: Compare total claims, average billing, and cost spread
--          across all insurance providers. Uses window function
--          to calculate each insurer's share of total billing.
-- ================================================================

SELECT
    insurance_provider,
    COUNT(*)                                     	AS total_claims,
    ROUND(AVG(billing_amount), 2)                	AS avg_claim_value,
    ROUND(SUM(billing_amount), 2)                	AS total_billed,
    ROUND(MIN(billing_amount), 2)                	AS min_claim,
    ROUND(MAX(billing_amount), 2)                	AS max_claim,
    ROUND(STDDEV(billing_amount), 2)             	AS billing_stddev,
    ROUND(AVG(billing_amount) * 100.0 /
        	SUM(AVG(billing_amount)) OVER (), 2) 	AS pct_of_avg_total
FROM patients
GROUP BY insurance_provider
ORDER BY total_billed DESC;

-- KEY FINDINGS:
-- Cigna leads with $287M total billed (11,249 claims)
-- All 5 insurers hold ~20% share each
-- Aetna has the worst negative claim at -$2,008 (data anomaly)
-- Billing std deviation of ~$14,000 indicates wide claim spread





-- ================================================================
-- QUERY 3: COST ANALYSIS BY MEDICAL CONDITION
--          WITH RUNNING TOTALS AND RANKINGS
-- Purpose: Rank conditions by total cost, show each condition's
--          share of total billing, and calculate running totals.
--          Uses chained CTEs and multiple window functions.
-- ================================================================

WITH condition_summary AS (
    SELECT
        medical_condition,
        COUNT(*)                                AS total_cases,
        ROUND(AVG(billing_amount), 2)           AS avg_billing,
        ROUND(SUM(billing_amount), 2)           AS total_billing,
        ROUND(AVG(age), 1)                      AS avg_patient_age,
        COUNT(DISTINCT insurance_provider)      AS insurers_covering
    FROM patients
    GROUP BY medical_condition
),
ranked AS (
    SELECT *,
        RANK() OVER (ORDER BY total_billing DESC)       AS cost_rank,
        ROUND(total_billing * 100.0 /
            SUM(total_billing) OVER (), 2)              AS pct_of_total_cost,
        ROUND(SUM(total_billing)
            OVER (ORDER BY total_billing DESC), 2)      AS running_total
    FROM condition_summary
)
SELECT
    cost_rank,
    medical_condition,
    total_cases,
    avg_billing,
    total_billing,
    pct_of_total_cost,
    running_total,
    avg_patient_age,
    insurers_covering
FROM ranked
ORDER BY cost_rank;

-- KEY FINDINGS:
-- Diabetes is the highest cost condition at $238M (16.83% of total)
-- Cancer has the lowest avg billing at $25,162 despite high case volume
-- Running total reaches $1.4B across all 6 conditions
-- All conditions covered by all 5 insurers





-- ================================================================
-- QUERY 4: ANOMALY DETECTION - BILLING OUTLIERS
--          USING Z-SCORE STATISTICAL METHOD
-- Purpose: Identify statistically unusual billing amounts.
--          Z-score > 1 or < -1 flags records for review.
--          Mirrors fraud detection and claims auditing workflows.
-- ================================================================

WITH billing_stats AS (
    SELECT
        ROUND(AVG(billing_amount), 2)       AS mean_billing,
        ROUND(STDDEV(billing_amount), 2)    AS stddev_billing
    FROM patients
),
patient_zscore AS (
    SELECT
        p.name,
        p.age,
        p.medical_condition,
        p.insurance_provider,
        p.billing_amount,
        p.admission_type,
        ROUND(
            (p.billing_amount - s.mean_billing) / s.stddev_billing
        		, 2)                                AS z_score
    FROM patients p
    CROSS JOIN billing_stats s
)
SELECT
    name,
    age,
    medical_condition,
    insurance_provider,
    billing_amount,
    admission_type,
    z_score,
    CASE
        WHEN z_score > 1  THEN 'Above Average - Monitor'
        WHEN z_score < -1 THEN 'Below Average - Possible Refund/Error'
        ELSE 'Normal Range'
    END                                     AS anomaly_flag,
    COUNT(*) OVER (
        PARTITION BY
            CASE
                WHEN z_score > 1  THEN 'Above Average - Monitor'
                WHEN z_score < -1 THEN 'Below Average - Possible Refund/Error'
                ELSE 'Normal Range'
            END
    )                                       AS flag_group_count
FROM patient_zscore
ORDER BY z_score DESC
LIMIT 20;

-- KEY FINDINGS:
-- 11,618 patients (~21%) flagged as Above Average billing
-- Highest billing: tOdd CARrILIO at $52,764 (Z-score: 1.92)
-- Mixed capitalisation in patient names identified as data quality issue
-- No extreme outliers beyond 2 std deviations (uniform billing distribution)





-- ================================================================
-- QUERY 5: LENGTH OF STAY ANALYSIS
--          WITH COST PER DAY AND RISK CLASSIFICATION
-- Purpose: Calculate length of stay per patient, cost per day,
--          and compare against condition averages using PARTITION BY.
--          Classifies patients by stay risk level.
-- ================================================================

WITH los_analysis AS (
    SELECT
        name,
        age,
        medical_condition,
        insurance_provider,
        admission_type,
        date_of_admission,
        discharge_date,
        billing_amount,
        (discharge_date - date_of_admission)        AS length_of_stay,
        ROUND(
            billing_amount /
            NULLIF((discharge_date - date_of_admission), 0)
        , 2)                                        AS cost_per_day
    FROM patients
),
ranked_los AS (
    SELECT *,
        ROUND(AVG(length_of_stay)
            OVER (PARTITION BY medical_condition), 1)   AS avg_los_by_condition,
        ROUND(AVG(cost_per_day)
            OVER (PARTITION BY insurance_provider), 2)  AS avg_cost_per_day_by_insurer,
        RANK() OVER (
            PARTITION BY medical_condition
            ORDER BY length_of_stay DESC
        )                                               AS los_rank_in_condition
    FROM los_analysis
)
SELECT
    name,
    age,
    medical_condition,
    insurance_provider,
    admission_type,
    length_of_stay,
    cost_per_day,
    avg_los_by_condition,
    avg_cost_per_day_by_insurer,
    los_rank_in_condition,
    CASE
        WHEN length_of_stay > avg_los_by_condition * 1.5
            THEN 'Extended Stay - High Risk'
        WHEN length_of_stay > avg_los_by_condition
            THEN 'Above Average Stay'
        ELSE 'Normal Stay'
    END                                                 AS stay_classification
FROM ranked_los
ORDER BY length_of_stay DESC
LIMIT 20;

-- KEY FINDINGS:
-- Max length of stay: 30 days (all flagged as Extended Stay - High Risk)
-- Avg LOS for Arthritis: 15.5 days, making 30-day stays double the average
-- Cost per day varies widely ($50 to $1,606) for same condition and same LOS
-- NULLIF used to prevent division by zero for same-day discharges





-- ================================================================
-- QUERY 6: MONTHLY ADMISSION TRENDS
--          WITH MONTH-ON-MONTH CHANGES USING LAG FUNCTION
-- Purpose: Track admission volumes and billing trends month by month.
--          Uses LAG() to calculate MoM percentage changes.
--          Classifies each month's trend for executive reporting.
-- ================================================================

WITH monthly_stats AS (
    SELECT
        DATE_TRUNC('month', date_of_admission)      AS admission_month,
        COUNT(*)                                    AS total_admissions,
        ROUND(SUM(billing_amount), 2)               AS total_billing,
        ROUND(AVG(billing_amount), 2)               AS avg_billing,
        COUNT(CASE WHEN admission_type = 'Emergency'
            THEN 1 END)                             AS emergency_admissions,
        COUNT(CASE WHEN admission_type = 'Urgent'
            THEN 1 END)                             AS urgent_admissions,
        COUNT(CASE WHEN admission_type = 'Elective'
            THEN 1 END)                             AS elective_admissions
    FROM patients
    GROUP BY DATE_TRUNC('month', date_of_admission)
),
mom_analysis AS (
    SELECT *,
        LAG(total_admissions)
            OVER (ORDER BY admission_month)         AS prev_month_admissions,
        LAG(total_billing)
            OVER (ORDER BY admission_month)         AS prev_month_billing,
        ROUND(
            (total_admissions - LAG(total_admissions)
                OVER (ORDER BY admission_month)) * 100.0
            / NULLIF(LAG(total_admissions)
                OVER (ORDER BY admission_month), 0)
        , 2)                                        AS admissions_mom_pct,
        ROUND(
            (total_billing - LAG(total_billing)
                OVER (ORDER BY admission_month)) * 100.0
            / NULLIF(LAG(total_billing)
                OVER (ORDER BY admission_month), 0)
        , 2)                                        AS billing_mom_pct
    FROM monthly_stats
)
SELECT
    TO_CHAR(admission_month, 'Mon YYYY')            AS month,
    total_admissions,
    emergency_admissions,
    urgent_admissions,
    elective_admissions,
    total_billing,
    avg_billing,
    admissions_mom_pct                              AS admissions_change_pct,
    billing_mom_pct                                 AS billing_change_pct,
    CASE
        WHEN admissions_mom_pct > 10  THEN 'Significant Increase'
        WHEN admissions_mom_pct > 0   THEN 'Moderate Increase'
        WHEN admissions_mom_pct IS NULL THEN 'Baseline Month'
        ELSE 'Decrease'
    END                                             AS trend_flag
FROM mom_analysis
ORDER BY admission_month;

-- KEY FINDINGS:
-- 61 months of data from May 2019 onwards
-- Jun 2019: +32.22% admission spike (Significant Increase)
-- Mar 2021: +15.77% spike, likely seasonal or policy-driven
-- Monthly billing consistently $22M - $26M range
-- Feb 2021 and Sep 2020 show steepest drops (~-10%)


