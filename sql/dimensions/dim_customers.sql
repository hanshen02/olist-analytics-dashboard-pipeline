-- =============================================================================
-- TABLE:   public.dim_customers
-- GRAIN:   One row per customer (customer_unique_id)
-- PURPOSE: Customer dimension deduplicating transaction tokens to human person grain;
--          calculates lifetime orders, spend, dynamic recency, and value tiers.
-- =============================================================================

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
    -- Primary Key (Human Entity Grain)
    m.customer_unique_id,

    -- Geographic Attributes (Resolved from most recent order)
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

    -- Customer Order History & RFM Metrics (Dynamically Anchored)
    m.first_order_date,
    m.last_order_date,
    (da.max_purchase_date - m.last_order_date) AS recency_days,
    m.lifetime_completed_orders,
    m.lifetime_spend_brl,
    (m.lifetime_completed_orders >= 2) AS is_repeat_buyer,

    -- Behavioral & Monetary Segmentation Tiers
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
