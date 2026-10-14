-- =============================================================================
-- TABLE:   public.fct_monthly_cohorts
-- GRAIN:   One row per cohort month and month offset (cohort_month, month_index)
-- PURPOSE: Pre-computed monthly customer cohort retention matrix tracking active
--          buyer retention rates and cohort GMV over time.
-- =============================================================================

DROP TABLE IF EXISTS public.fct_monthly_cohorts CASCADE;

CREATE TABLE public.fct_monthly_cohorts AS
WITH
-- 1. Determine each customer's acquisition cohort (month of first completed order)
customer_first_order AS (
    SELECT 
        c.customer_unique_id,
        DATE_TRUNC('month', MIN(o.order_purchase_timestamp::TIMESTAMP))::DATE AS cohort_month
    FROM raw.customers c
    JOIN raw.orders o ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY c.customer_unique_id
),

-- 2. Size of each acquisition cohort
cohort_sizes AS (
    SELECT 
        cohort_month,
        COUNT(DISTINCT customer_unique_id) AS cohort_size
    FROM customer_first_order
    GROUP BY cohort_month
),

-- 3. Track all repeat purchase activities by month offset
customer_activities AS (
    SELECT 
        c.customer_unique_id,
        fo.cohort_month,
        (EXTRACT(YEAR FROM o.order_purchase_timestamp::TIMESTAMP) - EXTRACT(YEAR FROM fo.cohort_month)) * 12 +
        (EXTRACT(MONTH FROM o.order_purchase_timestamp::TIMESTAMP) - EXTRACT(MONTH FROM fo.cohort_month)) AS month_index,
        SUM(oi.price::NUMERIC + oi.freight_value::NUMERIC) AS period_spend_brl
    FROM raw.customers c
    JOIN raw.orders o ON c.customer_id = o.customer_id
    JOIN raw.order_items oi ON o.order_id = oi.order_id
    JOIN customer_first_order fo ON c.customer_unique_id = fo.customer_unique_id
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY c.customer_unique_id, fo.cohort_month, 3
)

SELECT
    a.cohort_month,
    TO_CHAR(a.cohort_month, 'YYYY-MM') AS cohort_year_month,
    cs.cohort_size,
    a.month_index::INTEGER AS month_index,
    'M+' || a.month_index::TEXT AS month_offset_label,
    COUNT(DISTINCT a.customer_unique_id) AS active_customers,
    ROUND((COUNT(DISTINCT a.customer_unique_id) * 100.0 / cs.cohort_size)::NUMERIC, 2) AS retention_rate_pct,
    ROUND(SUM(a.period_spend_brl)::NUMERIC, 2) AS cohort_period_gmv_brl

FROM customer_activities a
JOIN cohort_sizes cs ON a.cohort_month = cs.cohort_month
GROUP BY a.cohort_month, cs.cohort_size, a.month_index
ORDER BY a.cohort_month, a.month_index;

ALTER TABLE public.fct_monthly_cohorts ADD PRIMARY KEY (cohort_month, month_index);
ALTER TABLE public.fct_monthly_cohorts ALTER COLUMN cohort_month SET NOT NULL;
ALTER TABLE public.fct_monthly_cohorts ALTER COLUMN month_index SET NOT NULL;
ALTER TABLE public.fct_monthly_cohorts ALTER COLUMN cohort_size SET NOT NULL;
ALTER TABLE public.fct_monthly_cohorts ADD CONSTRAINT chk_cohort_month_index CHECK (month_index >= 0);
ALTER TABLE public.fct_monthly_cohorts ADD CONSTRAINT chk_cohort_retention_rate CHECK (retention_rate_pct BETWEEN 0 AND 100);
