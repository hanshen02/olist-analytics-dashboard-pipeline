-- =============================================================================
-- TABLE:   public.fct_route_logistics
-- GRAIN:   One row per fulfillment corridor (seller_state, customer_state)
-- PURPOSE: Origin-to-destination corridor logistics mart tracking freight burden,
--          delivery duration, SLA compliance, and customer review scores.
-- =============================================================================

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

    -- Volume Metrics
    COUNT(DISTINCT order_id) AS total_orders,
    COUNT(order_item_id) AS total_items,
    ROUND(SUM(price + freight_value)::NUMERIC, 2) AS total_gmv_brl,

    -- Economics
    ROUND(AVG(price)::NUMERIC, 2) AS avg_item_price_brl,
    ROUND(AVG(freight_value)::NUMERIC, 2) AS avg_freight_value_brl,
    ROUND(AVG(freight_value / NULLIF(price, 0))::NUMERIC * 100.0, 1) AS avg_freight_burden_pct,

    -- Fulfillment Duration (Delivered Orders Only)
    ROUND(AVG(CASE 
        WHEN order_delivered_customer_date IS NOT NULL 
        THEN EXTRACT(EPOCH FROM (order_delivered_customer_date - order_purchase_timestamp)) / 86400.0 
    END)::NUMERIC, 1) AS avg_delivery_days_actual,

    ROUND(AVG(CASE 
        WHEN order_delivered_customer_date IS NOT NULL 
        THEN EXTRACT(EPOCH FROM (order_estimated_delivery_date - order_purchase_timestamp)) / 86400.0 
    END)::NUMERIC, 1) AS avg_delivery_days_estimated,

    -- SLA Compliance (Date-only comparison fixes false positives)
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

    -- Customer Satisfaction
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
