-- =============================================================================
-- TABLE:   public.fct_seller_acquisition
-- GRAIN:   One row per marketing qualified lead (mql_id)
-- PURPOSE: B2B merchant acquisition and sales funnel mart tracking lead origin,
--          SDR/SR conversion velocity, deal outcomes, and marketplace GMV.
-- =============================================================================

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

    -- Sales Conversion Tracking
    lc.seller_id,
    (lc.won_date IS NOT NULL) AS is_won_deal,
    lc.won_date::TIMESTAMP::DATE AS won_date,
    CASE 
        WHEN lc.won_date IS NOT NULL 
        THEN ROUND(EXTRACT(EPOCH FROM (lc.won_date::TIMESTAMP - lq.first_contact_date::TIMESTAMP)) / 86400.0, 1)
        ELSE NULL 
    END AS sales_cycle_days,

    -- Sales Development Rep (SDR) & Sales Rep (SR) Ownership
    lc.sdr_id,
    lc.sr_id,

    -- Business Profile
    COALESCE(lc.business_segment, 'Unspecified') AS business_segment,
    COALESCE(lc.lead_type, 'unknown') AS lead_type,
    COALESCE(lc.lead_behaviour_profile, 'unknown') AS lead_behaviour_profile,
    COALESCE(lc.business_type, 'unknown') AS business_type,
    CASE WHEN lc.has_company IN ('True', 'true', '1', 't') THEN TRUE ELSE FALSE END AS has_company,
    CASE WHEN lc.has_gtin IN ('True', 'true', '1', 't') THEN TRUE ELSE FALSE END AS has_gtin,
    lc.declared_product_catalog_size,
    COALESCE(lc.declared_monthly_revenue::NUMERIC, 0.00)::NUMERIC(10,2) AS declared_monthly_revenue_brl,

    -- Marketplace Activation (Did the won merchant actually sell on Olist?)
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
