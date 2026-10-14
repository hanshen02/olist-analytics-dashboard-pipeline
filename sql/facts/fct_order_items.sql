-- =============================================================================
-- TABLE:   public.fct_order_items
-- GRAIN:   One row per order line item (order_id, order_item_id)
-- PURPOSE: Core transactional fact table integrating line-item financials, payment
--          financing, verified delivery SLA, and pre-joined customer review scores.
-- =============================================================================

DROP TABLE IF EXISTS public.fct_order_items CASCADE;

CREATE TABLE public.fct_order_items AS
WITH
-- 1. Pre-aggregate payments to order grain (prevents multi-payment fan-out)
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

-- 2. Two-stage review deduplication: exactly 1 authoritative review per order
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

-- 3. Resolve order customer_id token -> true human customer_unique_id
customer_map AS (
    SELECT DISTINCT ON (customer_id)
        customer_id,
        customer_unique_id
    FROM raw.customers
    ORDER BY customer_id
)

SELECT
    -- Degenerate Transaction Keys (Composite PK)
    oi.order_id,
    oi.order_item_id,

    -- Dimensional Foreign Keys
    TO_CHAR(o.order_purchase_timestamp, 'YYYYMMDD')::INTEGER AS date_key,
    cm.customer_unique_id,
    oi.product_id,
    oi.seller_id,

    -- Financial Measures (Line-Item Grain)
    oi.price::NUMERIC(10,2) AS price_brl,
    oi.freight_value::NUMERIC(10,2) AS freight_brl,
    (oi.price + oi.freight_value)::NUMERIC(10,2) AS total_revenue_brl,

    -- Order Status & Financing Context
    o.order_status,
    COALESCE(p.primary_payment_type, 'unknown') AS primary_payment_type,
    COALESCE(p.num_payment_methods, 1) AS num_payment_methods,
    COALESCE(p.max_payment_installments, 1) AS max_payment_installments,

    -- Raw Timestamps
    o.order_purchase_timestamp,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,

    -- Delivery Durations (Decimal Days)
    ROUND(EXTRACT(EPOCH FROM (o.order_delivered_customer_date - o.order_purchase_timestamp)) / 86400.0, 1) AS delivery_days_actual,
    ROUND(EXTRACT(EPOCH FROM (o.order_estimated_delivery_date - o.order_purchase_timestamp)) / 86400.0, 1) AS delivery_days_estimated,
    CASE 
        WHEN o.order_delivered_customer_date IS NOT NULL 
        THEN ROUND(EXTRACT(EPOCH FROM (o.order_delivered_customer_date - o.order_estimated_delivery_date)) / 86400.0, 1)
        ELSE NULL 
    END AS delay_days,

    -- Delivery SLA Flags (Date-only comparison fixes false positives)
    (o.order_status = 'delivered') AS is_delivered,
    CASE
        WHEN o.order_delivered_customer_date IS NOT NULL
        THEN (o.order_delivered_customer_date::DATE > o.order_estimated_delivery_date::DATE)
        ELSE NULL
    END AS is_late,

    -- Chronological Delay Bands
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

    -- Pre-Joined Customer Review Satisfaction
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

-- Enforce Referential Integrity & Column Constraints
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
