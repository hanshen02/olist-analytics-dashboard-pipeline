-- =============================================================================
-- SCRIPT:  sql/deploy_all.sql
-- PURPOSE: Master deployment runner building all 8 Kimball star schema models
--          (4 dimensions, 4 facts) with enterprise integrity constraints.
--
-- EXECUTION ORDER:
--   1. Dimensions: dim_date, dim_customers, dim_products, dim_sellers
--   2. Facts:      fct_order_items, fct_monthly_cohorts, fct_route_logistics,
--                  fct_seller_acquisition
-- =============================================================================

-- =============================================================================
-- 1. DIMENSIONS
-- =============================================================================

-- 1.1 Calendar Dimension (dim_date)
DROP TABLE IF EXISTS public.dim_date CASCADE;
CREATE TABLE public.dim_date AS
SELECT
    TO_CHAR(d, 'YYYYMMDD')::INTEGER AS date_key,
    d::DATE AS full_date,
    EXTRACT(YEAR FROM d)::INTEGER AS year,
    EXTRACT(QUARTER FROM d)::INTEGER AS quarter,
    TO_CHAR(d, 'YYYY"-Q"Q') AS year_quarter,
    EXTRACT(MONTH FROM d)::INTEGER AS month_num,
    TO_CHAR(d, 'FMMonth') AS month_name,
    TO_CHAR(d, 'Mon') AS month_name_short,
    TO_CHAR(d, 'YYYY-MM') AS year_month,
    EXTRACT(WEEK FROM d)::INTEGER AS week_of_year,
    EXTRACT(DAY FROM d)::INTEGER AS day_of_month,
    EXTRACT(ISODOW FROM d)::INTEGER AS day_of_week,
    TO_CHAR(d, 'FMDay') AS day_name,
    TO_CHAR(d, 'Dy') AS day_name_short,
    EXTRACT(ISODOW FROM d) IN (6, 7) AS is_weekend,
    EXTRACT(ISODOW FROM d) NOT IN (6, 7) AS is_weekday
FROM generate_series('2016-09-01'::DATE, '2018-12-31'::DATE, '1 day'::INTERVAL) AS g(d);

ALTER TABLE public.dim_date ADD PRIMARY KEY (date_key);
ALTER TABLE public.dim_date ALTER COLUMN full_date SET NOT NULL;
ALTER TABLE public.dim_date ALTER COLUMN year SET NOT NULL;
ALTER TABLE public.dim_date ALTER COLUMN month_num SET NOT NULL;
CREATE UNIQUE INDEX idx_dim_date_full_date ON public.dim_date (full_date);


-- 1.2 Customer Dimension (dim_customers)
DROP TABLE IF EXISTS public.dim_customers CASCADE;
CREATE TABLE public.dim_customers AS
WITH
geo_agg AS (
    SELECT
        LPAD(geolocation_zip_code_prefix::TEXT, 5, '0') AS zip_prefix,
        ROUND(AVG(geolocation_lat)::NUMERIC, 6) AS lat,
        ROUND(AVG(geolocation_lng)::NUMERIC, 6) AS lng
    FROM raw.geolocation
    GROUP BY geolocation_zip_code_prefix
),
customer_address AS (
    SELECT DISTINCT ON (c.customer_unique_id)
        c.customer_unique_id,
        LPAD(c.customer_zip_code_prefix::TEXT, 5, '0') AS customer_zip_code_prefix,
        INITCAP(TRIM(c.customer_city::TEXT)) AS customer_city,
        c.customer_state
    FROM raw.customers c
    LEFT JOIN raw.orders o ON c.customer_id = o.customer_id
    ORDER BY c.customer_unique_id, o.order_purchase_timestamp::TIMESTAMP DESC NULLS LAST
),
customer_metrics AS (
    SELECT
        c.customer_unique_id,
        MIN(o.order_purchase_timestamp::TIMESTAMP::DATE) AS first_order_date,
        MAX(o.order_purchase_timestamp::TIMESTAMP::DATE) AS last_order_date,
        COUNT(DISTINCT CASE 
            WHEN o.order_status NOT IN ('canceled', 'unavailable') 
            THEN o.order_id 
        END) AS lifetime_completed_orders,
        COALESCE(SUM(CASE 
            WHEN o.order_status NOT IN ('canceled', 'unavailable') 
            THEN oi.price::NUMERIC + oi.freight_value::NUMERIC 
        END), 0.00)::NUMERIC(10,2) AS lifetime_spend_brl
    FROM raw.customers c
    LEFT JOIN raw.orders o ON c.customer_id = o.customer_id
    LEFT JOIN raw.order_items oi ON o.order_id = oi.order_id
    GROUP BY c.customer_unique_id
),
dataset_anchor AS (
    SELECT MAX(order_purchase_timestamp::TIMESTAMP)::DATE AS max_purchase_date
    FROM raw.orders
)
SELECT
    m.customer_unique_id,
    a.customer_zip_code_prefix,
    a.customer_city,
    a.customer_state,
    CASE a.customer_state
        WHEN 'AC' THEN 'Acre'
        WHEN 'AL' THEN 'Alagoas'
        WHEN 'AP' THEN 'Amapa'
        WHEN 'AM' THEN 'Amazonas'
        WHEN 'BA' THEN 'Bahia'
        WHEN 'CE' THEN 'Ceara'
        WHEN 'DF' THEN 'Distrito Federal'
        WHEN 'ES' THEN 'Espirito Santo'
        WHEN 'GO' THEN 'Goias'
        WHEN 'MA' THEN 'Maranhao'
        WHEN 'MT' THEN 'Mato Grosso'
        WHEN 'MS' THEN 'Mato Grosso do Sul'
        WHEN 'MG' THEN 'Minas Gerais'
        WHEN 'PA' THEN 'Para'
        WHEN 'PB' THEN 'Paraiba'
        WHEN 'PR' THEN 'Parana'
        WHEN 'PE' THEN 'Pernambuco'
        WHEN 'PI' THEN 'Piaui'
        WHEN 'RJ' THEN 'Rio de Janeiro'
        WHEN 'RN' THEN 'Rio Grande do Norte'
        WHEN 'RS' THEN 'Rio Grande do Sul'
        WHEN 'RO' THEN 'Rondonia'
        WHEN 'RR' THEN 'Roraima'
        WHEN 'SC' THEN 'Santa Catarina'
        WHEN 'SP' THEN 'Sao Paulo'
        WHEN 'SE' THEN 'Sergipe'
        WHEN 'TO' THEN 'Tocantins'
        ELSE a.customer_state
    END AS customer_state_name,
    g.lat AS customer_lat,
    g.lng AS customer_lng,
    m.first_order_date,
    m.last_order_date,
    (da.max_purchase_date - m.last_order_date) AS recency_days,
    m.lifetime_completed_orders,
    m.lifetime_spend_brl,
    (m.lifetime_completed_orders >= 2) AS is_repeat_buyer,
    CASE 
        WHEN m.lifetime_completed_orders = 0 THEN '0. Inactive / Canceled'
        WHEN m.lifetime_completed_orders = 1 THEN '1. One-Time Buyer'
        WHEN m.lifetime_completed_orders = 2 THEN '2. Repeat Buyer (2 Orders)'
        ELSE '3. VIP Frequent Buyer (3+ Orders)'
    END AS repeat_buyer_tier,
    CASE 
        WHEN m.lifetime_spend_brl >= 500.00 THEN 'High Spender (R$ 500+)'
        WHEN m.lifetime_spend_brl >= 150.00 THEN 'Mid Spender (R$ 150-500)'
        ELSE 'Budget Spender (< R$ 150)'
    END AS monetary_tier,
    CASE 
        WHEN (da.max_purchase_date - m.last_order_date) <= 90  THEN 'Active (<= 90d)'
        WHEN (da.max_purchase_date - m.last_order_date) <= 180 THEN 'Lapsing (91-180d)'
        ELSE 'Dormant (> 180d)'
    END AS recency_tier
FROM customer_metrics m
CROSS JOIN dataset_anchor da
JOIN customer_address a ON m.customer_unique_id = a.customer_unique_id
LEFT JOIN geo_agg g ON a.customer_zip_code_prefix = g.zip_prefix;

ALTER TABLE public.dim_customers ADD PRIMARY KEY (customer_unique_id);
ALTER TABLE public.dim_customers ALTER COLUMN customer_state SET NOT NULL;
ALTER TABLE public.dim_customers ALTER COLUMN customer_zip_code_prefix SET NOT NULL;
ALTER TABLE public.dim_customers ADD CONSTRAINT chk_customer_lifetime_spend CHECK (lifetime_spend_brl >= 0);
ALTER TABLE public.dim_customers ADD CONSTRAINT chk_customer_orders_nonneg CHECK (lifetime_completed_orders >= 0);
CREATE INDEX idx_dim_customers_state ON public.dim_customers (customer_state);


-- 1.3 Product Dimension (dim_products)
DROP TABLE IF EXISTS public.dim_products CASCADE;
CREATE TABLE public.dim_products AS
SELECT
    p.product_id,
    COALESCE(t.product_category_name_english, p.product_category_name, 'Uncategorized') AS category_name_english,
    COALESCE(p.product_category_name, 'Uncategorized') AS category_name_portuguese,
    p.product_name_lenght::INTEGER AS product_name_length,
    p.product_description_lenght::INTEGER AS product_description_length,
    p.product_photos_qty::INTEGER AS product_photos_qty,
    p.product_weight_g::NUMERIC AS product_weight_g,
    p.product_length_cm::NUMERIC AS product_length_cm,
    p.product_height_cm::NUMERIC AS product_height_cm,
    p.product_width_cm::NUMERIC AS product_width_cm,
    ROUND(((p.product_length_cm * p.product_height_cm * p.product_width_cm) / 5000.0)::NUMERIC, 2) AS volumetric_weight_kg
FROM raw.products p
LEFT JOIN raw.product_category_name_translation t 
    ON p.product_category_name = t.product_category_name;

ALTER TABLE public.dim_products ADD PRIMARY KEY (product_id);
ALTER TABLE public.dim_products ALTER COLUMN category_name_english SET NOT NULL;
ALTER TABLE public.dim_products ALTER COLUMN category_name_portuguese SET NOT NULL;
ALTER TABLE public.dim_products ADD CONSTRAINT chk_product_weight_nonneg CHECK (product_weight_g IS NULL OR product_weight_g >= 0);
ALTER TABLE public.dim_products ADD CONSTRAINT chk_volumetric_weight_nonneg CHECK (volumetric_weight_kg IS NULL OR volumetric_weight_kg >= 0);
CREATE INDEX idx_dim_products_category ON public.dim_products (category_name_english);


-- 1.4 Seller Dimension (dim_sellers)
DROP TABLE IF EXISTS public.dim_sellers CASCADE;
CREATE TABLE public.dim_sellers AS
WITH geo_agg AS (
    SELECT
        LPAD(geolocation_zip_code_prefix::TEXT, 5, '0') AS zip_prefix,
        ROUND(AVG(geolocation_lat)::NUMERIC, 6) AS lat,
        ROUND(AVG(geolocation_lng)::NUMERIC, 6) AS lng
    FROM raw.geolocation
    GROUP BY geolocation_zip_code_prefix
)
SELECT
    s.seller_id,
    LPAD(s.seller_zip_code_prefix::TEXT, 5, '0') AS seller_zip_code_prefix,
    INITCAP(TRIM(s.seller_city::TEXT)) AS seller_city,
    s.seller_state,
    g.lat AS seller_lat,
    g.lng AS seller_lng
FROM raw.sellers s
LEFT JOIN geo_agg g ON LPAD(s.seller_zip_code_prefix::TEXT, 5, '0') = g.zip_prefix;

ALTER TABLE public.dim_sellers ADD PRIMARY KEY (seller_id);
ALTER TABLE public.dim_sellers ALTER COLUMN seller_state SET NOT NULL;
ALTER TABLE public.dim_sellers ALTER COLUMN seller_zip_code_prefix SET NOT NULL;
CREATE INDEX idx_dim_sellers_state ON public.dim_sellers (seller_state);


-- =============================================================================
-- 2. FACTS & ANALYTICAL MARTS
-- =============================================================================

-- 2.1 Transactional Fact (fct_order_items)
DROP TABLE IF EXISTS public.fct_order_items CASCADE;
CREATE TABLE public.fct_order_items AS
WITH
payments_agg AS (
    SELECT
        order_id,
        COUNT(DISTINCT payment_sequential) AS num_payment_methods,
        (ARRAY_AGG(payment_type ORDER BY payment_value DESC NULLS LAST))[1] AS primary_payment_type,
        MAX(payment_installments) AS max_payment_installments
    FROM raw.order_payments
    WHERE payment_type <> 'not_defined'
    GROUP BY order_id
),
reviews_dedup AS (
    SELECT DISTINCT ON (order_id)
        order_id,
        review_score,
        (review_score >= 4) AS is_positive_review,
        (review_score <= 2) AS is_negative_review,
        (review_comment_message IS NOT NULL) AS has_comment,
        ROUND(EXTRACT(EPOCH FROM (review_answer_timestamp - review_creation_date)) / 3600.0, 1) AS review_response_hours
    FROM raw.order_reviews
    WHERE review_id IS NOT NULL
    ORDER BY order_id, review_answer_timestamp DESC NULLS LAST
),
customer_map AS (
    SELECT DISTINCT ON (customer_id)
        customer_id,
        customer_unique_id
    FROM raw.customers
    ORDER BY customer_id
)
SELECT
    oi.order_id,
    oi.order_item_id,
    TO_CHAR(o.order_purchase_timestamp, 'YYYYMMDD')::INTEGER AS date_key,
    cm.customer_unique_id,
    oi.product_id,
    oi.seller_id,
    oi.price::NUMERIC(10,2) AS price_brl,
    oi.freight_value::NUMERIC(10,2) AS freight_brl,
    (oi.price + oi.freight_value)::NUMERIC(10,2) AS total_revenue_brl,
    o.order_status,
    COALESCE(p.primary_payment_type, 'unknown') AS primary_payment_type,
    COALESCE(p.num_payment_methods, 1) AS num_payment_methods,
    COALESCE(p.max_payment_installments, 1) AS max_payment_installments,
    o.order_purchase_timestamp,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,
    ROUND(EXTRACT(EPOCH FROM (o.order_delivered_customer_date - o.order_purchase_timestamp)) / 86400.0, 1) AS delivery_days_actual,
    ROUND(EXTRACT(EPOCH FROM (o.order_estimated_delivery_date - o.order_purchase_timestamp)) / 86400.0, 1) AS delivery_days_estimated,
    CASE 
        WHEN o.order_delivered_customer_date IS NOT NULL 
        THEN ROUND(EXTRACT(EPOCH FROM (o.order_delivered_customer_date - o.order_estimated_delivery_date)) / 86400.0, 1)
        ELSE NULL 
    END AS delay_days,
    (o.order_status = 'delivered') AS is_delivered,
    CASE
        WHEN o.order_delivered_customer_date IS NOT NULL
        THEN (o.order_delivered_customer_date::DATE > o.order_estimated_delivery_date::DATE)
        ELSE NULL
    END AS is_late,
    CASE
        WHEN o.order_delivered_customer_date IS NULL THEN '7. Undelivered'
        WHEN (o.order_delivered_customer_date::DATE - o.order_estimated_delivery_date::DATE) < -7 THEN '1. Very Early (>7d)'
        WHEN (o.order_delivered_customer_date::DATE - o.order_estimated_delivery_date::DATE) < 0 THEN '2. Early (1-7d)'
        WHEN (o.order_delivered_customer_date::DATE - o.order_estimated_delivery_date::DATE) = 0 THEN '3. Exactly On Time'
        WHEN (o.order_delivered_customer_date::DATE - o.order_estimated_delivery_date::DATE) <= 7 THEN '4. Late (1-7d)'
        WHEN (o.order_delivered_customer_date::DATE - o.order_estimated_delivery_date::DATE) <= 14 THEN '5. Late (8-14d)'
        ELSE '6. Very Late (>14d)'
    END AS delivery_delay_band,
    CASE
        WHEN o.order_delivered_customer_date IS NULL THEN 7
        WHEN (o.order_delivered_customer_date::DATE - o.order_estimated_delivery_date::DATE) < -7 THEN 1
        WHEN (o.order_delivered_customer_date::DATE - o.order_estimated_delivery_date::DATE) < 0 THEN 2
        WHEN (o.order_delivered_customer_date::DATE - o.order_estimated_delivery_date::DATE) = 0 THEN 3
        WHEN (o.order_delivered_customer_date::DATE - o.order_estimated_delivery_date::DATE) <= 7 THEN 4
        WHEN (o.order_delivered_customer_date::DATE - o.order_estimated_delivery_date::DATE) <= 14 THEN 5
        ELSE 6
    END AS delivery_delay_band_sort,
    r.review_score,
    r.is_positive_review,
    r.is_negative_review,
    COALESCE(r.has_comment, FALSE) AS has_review_comment,
    r.review_response_hours
FROM raw.order_items oi
JOIN raw.orders o ON oi.order_id = o.order_id
JOIN customer_map cm ON o.customer_id = cm.customer_id
LEFT JOIN payments_agg p ON oi.order_id = p.order_id
LEFT JOIN reviews_dedup r ON oi.order_id = r.order_id;

ALTER TABLE public.fct_order_items ADD PRIMARY KEY (order_id, order_item_id);
ALTER TABLE public.fct_order_items
    ALTER COLUMN date_key SET NOT NULL,
    ALTER COLUMN customer_unique_id SET NOT NULL,
    ALTER COLUMN product_id SET NOT NULL,
    ALTER COLUMN seller_id SET NOT NULL,
    ALTER COLUMN price_brl SET NOT NULL,
    ALTER COLUMN freight_brl SET NOT NULL,
    ALTER COLUMN total_revenue_brl SET NOT NULL,
    ADD CONSTRAINT fk_fct_order_items_date FOREIGN KEY (date_key) REFERENCES public.dim_date (date_key),
    ADD CONSTRAINT fk_fct_order_items_customer FOREIGN KEY (customer_unique_id) REFERENCES public.dim_customers (customer_unique_id),
    ADD CONSTRAINT fk_fct_order_items_product FOREIGN KEY (product_id) REFERENCES public.dim_products (product_id),
    ADD CONSTRAINT fk_fct_order_items_seller FOREIGN KEY (seller_id) REFERENCES public.dim_sellers (seller_id),
    ADD CONSTRAINT chk_price_positive CHECK (price_brl >= 0),
    ADD CONSTRAINT chk_freight_positive CHECK (freight_brl >= 0),
    ADD CONSTRAINT chk_review_score_range CHECK (review_score IS NULL OR review_score BETWEEN 1 AND 5);

CREATE INDEX idx_fct_order_items_date ON public.fct_order_items (date_key);
CREATE INDEX idx_fct_order_items_customer ON public.fct_order_items (customer_unique_id);
CREATE INDEX idx_fct_order_items_product ON public.fct_order_items (product_id);
CREATE INDEX idx_fct_order_items_seller ON public.fct_order_items (seller_id);


-- 2.2 Retention Mart (fct_monthly_cohorts)
DROP TABLE IF EXISTS public.fct_monthly_cohorts CASCADE;
CREATE TABLE public.fct_monthly_cohorts AS
WITH
customer_first_order AS (
    SELECT 
        c.customer_unique_id,
        DATE_TRUNC('month', MIN(o.order_purchase_timestamp::TIMESTAMP))::DATE AS cohort_month
    FROM raw.customers c
    JOIN raw.orders o ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY c.customer_unique_id
),
cohort_sizes AS (
    SELECT 
        cohort_month,
        COUNT(DISTINCT customer_unique_id) AS cohort_size
    FROM customer_first_order
    GROUP BY cohort_month
),
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


-- 2.3 Logistics Mart (fct_route_logistics)
DROP TABLE IF EXISTS public.fct_route_logistics CASCADE;
CREATE TABLE public.fct_route_logistics AS
WITH route_base AS (
    SELECT
        s.seller_state,
        c.customer_state,
        CASE 
            WHEN s.seller_state = c.customer_state THEN 'Intra-State (Local)'
            ELSE 'Inter-State (Cross-State)'
        END AS corridor_type,
        o.order_id,
        oi.order_item_id,
        oi.price::NUMERIC AS price,
        oi.freight_value::NUMERIC AS freight_value,
        o.order_status,
        o.order_purchase_timestamp::TIMESTAMP AS order_purchase_timestamp,
        o.order_delivered_customer_date::TIMESTAMP AS order_delivered_customer_date,
        o.order_estimated_delivery_date::TIMESTAMP AS order_estimated_delivery_date,
        r.review_score::INTEGER AS review_score
    FROM raw.order_items oi
    JOIN raw.orders o ON oi.order_id = o.order_id
    JOIN raw.sellers s ON oi.seller_id = s.seller_id
    JOIN raw.customers c ON o.customer_id = c.customer_id
    LEFT JOIN (
        SELECT DISTINCT ON (order_id) order_id, review_score
        FROM raw.order_reviews
        ORDER BY order_id, review_answer_timestamp::TIMESTAMP DESC NULLS LAST
    ) r ON o.order_id = r.order_id
)
SELECT
    seller_state,
    customer_state,
    seller_state || ' -> ' || customer_state AS route_corridor,
    corridor_type,
    COUNT(DISTINCT order_id) AS total_orders,
    COUNT(order_item_id) AS total_items,
    ROUND(SUM(price + freight_value)::NUMERIC, 2) AS total_gmv_brl,
    ROUND(AVG(price)::NUMERIC, 2) AS avg_item_price_brl,
    ROUND(AVG(freight_value)::NUMERIC, 2) AS avg_freight_value_brl,
    ROUND(AVG(freight_value / NULLIF(price, 0))::NUMERIC * 100.0, 1) AS avg_freight_burden_pct,
    ROUND(AVG(CASE 
        WHEN order_delivered_customer_date IS NOT NULL 
        THEN EXTRACT(EPOCH FROM (order_delivered_customer_date - order_purchase_timestamp)) / 86400.0 
    END)::NUMERIC, 1) AS avg_delivery_days_actual,
    ROUND(AVG(CASE 
        WHEN order_delivered_customer_date IS NOT NULL 
        THEN EXTRACT(EPOCH FROM (order_estimated_delivery_date - order_purchase_timestamp)) / 86400.0 
    END)::NUMERIC, 1) AS avg_delivery_days_estimated,
    COUNT(CASE 
        WHEN order_delivered_customer_date IS NOT NULL 
         AND order_delivered_customer_date::DATE > order_estimated_delivery_date::DATE 
        THEN 1 
    END) AS late_orders_count,
    ROUND(
        COUNT(CASE 
            WHEN order_delivered_customer_date IS NOT NULL 
             AND order_delivered_customer_date::DATE > order_estimated_delivery_date::DATE 
            THEN 1 
        END) * 100.0 / NULLIF(COUNT(CASE WHEN order_status = 'delivered' THEN 1 END), 0),
        2
    ) AS late_delivery_rate_pct,
    ROUND(AVG(review_score)::NUMERIC, 2) AS avg_route_csat
FROM route_base
GROUP BY seller_state, customer_state, corridor_type
HAVING COUNT(DISTINCT order_id) >= 10
ORDER BY total_orders DESC;

ALTER TABLE public.fct_route_logistics ADD PRIMARY KEY (seller_state, customer_state);
ALTER TABLE public.fct_route_logistics ALTER COLUMN seller_state SET NOT NULL;
ALTER TABLE public.fct_route_logistics ALTER COLUMN customer_state SET NOT NULL;
ALTER TABLE public.fct_route_logistics ALTER COLUMN total_orders SET NOT NULL;
ALTER TABLE public.fct_route_logistics ADD CONSTRAINT chk_route_total_orders CHECK (total_orders > 0);
ALTER TABLE public.fct_route_logistics ADD CONSTRAINT chk_route_late_rate CHECK (late_delivery_rate_pct IS NULL OR late_delivery_rate_pct BETWEEN 0 AND 100);
ALTER TABLE public.fct_route_logistics ADD CONSTRAINT chk_route_csat CHECK (avg_route_csat IS NULL OR avg_route_csat BETWEEN 1 AND 5);


-- 2.4 B2B Seller Acquisition Mart (fct_seller_acquisition)
DROP TABLE IF EXISTS public.fct_seller_acquisition CASCADE;
CREATE TABLE public.fct_seller_acquisition AS
WITH seller_sales AS (
    SELECT
        seller_id,
        COUNT(DISTINCT order_id) AS lifetime_orders,
        COUNT(order_item_id) AS lifetime_items_sold,
        ROUND(SUM(price)::NUMERIC, 2) AS lifetime_sales_brl
    FROM raw.order_items
    GROUP BY seller_id
)
SELECT
    lq.mql_id,
    TO_CHAR(lq.first_contact_date::TIMESTAMP, 'YYYYMMDD')::INTEGER AS contact_date_key,
    lq.first_contact_date::TIMESTAMP::DATE AS first_contact_date,
    COALESCE(lq.origin, 'unknown') AS acquisition_channel,
    lq.landing_page_id,
    lc.seller_id,
    (lc.won_date IS NOT NULL) AS is_won_deal,
    lc.won_date::TIMESTAMP::DATE AS won_date,
    CASE 
        WHEN lc.won_date IS NOT NULL 
        THEN ROUND(EXTRACT(EPOCH FROM (lc.won_date::TIMESTAMP - lq.first_contact_date::TIMESTAMP)) / 86400.0, 1)
        ELSE NULL 
    END AS sales_cycle_days,
    lc.sdr_id,
    lc.sr_id,
    COALESCE(lc.business_segment, 'Unspecified') AS business_segment,
    COALESCE(lc.lead_type, 'unknown') AS lead_type,
    COALESCE(lc.lead_behaviour_profile, 'unknown') AS lead_behaviour_profile,
    COALESCE(lc.business_type, 'unknown') AS business_type,
    CASE WHEN lc.has_company IN ('True', 'true', '1', 't') THEN TRUE ELSE FALSE END AS has_company,
    CASE WHEN lc.has_gtin IN ('True', 'true', '1', 't') THEN TRUE ELSE FALSE END AS has_gtin,
    lc.declared_product_catalog_size,
    COALESCE(lc.declared_monthly_revenue::NUMERIC, 0.00)::NUMERIC(10,2) AS declared_monthly_revenue_brl,
    (ss.seller_id IS NOT NULL) AS is_active_marketplace_seller,
    COALESCE(ss.lifetime_orders, 0) AS marketplace_orders_fulfilled,
    COALESCE(ss.lifetime_sales_brl, 0.00) AS marketplace_gmv_generated_brl
FROM raw.leads_qualified lq
LEFT JOIN raw.leads_closed lc ON lq.mql_id = lc.mql_id
LEFT JOIN seller_sales ss ON lc.seller_id = ss.seller_id;

ALTER TABLE public.fct_seller_acquisition ADD PRIMARY KEY (mql_id);
ALTER TABLE public.fct_seller_acquisition ALTER COLUMN contact_date_key SET NOT NULL;
ALTER TABLE public.fct_seller_acquisition ALTER COLUMN is_won_deal SET NOT NULL;
ALTER TABLE public.fct_seller_acquisition ALTER COLUMN acquisition_channel SET NOT NULL;
CREATE INDEX idx_fct_seller_acq_channel ON public.fct_seller_acquisition (acquisition_channel);
CREATE INDEX idx_fct_seller_acq_won ON public.fct_seller_acquisition (is_won_deal);
CREATE INDEX idx_fct_seller_acq_seller ON public.fct_seller_acquisition (seller_id);
