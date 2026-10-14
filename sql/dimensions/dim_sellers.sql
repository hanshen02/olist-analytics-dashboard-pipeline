-- =============================================================================
-- TABLE:   public.dim_sellers
-- GRAIN:   One row per marketplace seller (seller_id)
-- PURPOSE: Marketplace seller dimension enriched with aggregated geolocation coordinates.
-- =============================================================================

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
    -- Primary Key
    s.seller_id,

    -- Geographic Attributes
    LPAD(s.seller_zip_code_prefix::TEXT, 5, '0') AS seller_zip_code_prefix,
    INITCAP(TRIM(s.seller_city::TEXT)) AS seller_city,
    s.seller_state,

    -- Coordinates for Route Logistics
    g.lat AS seller_lat,
    g.lng AS seller_lng

FROM raw.sellers s
LEFT JOIN geo_agg g ON LPAD(s.seller_zip_code_prefix::TEXT, 5, '0') = g.zip_prefix;

ALTER TABLE public.dim_sellers ADD PRIMARY KEY (seller_id);
ALTER TABLE public.dim_sellers ALTER COLUMN seller_state SET NOT NULL;
ALTER TABLE public.dim_sellers ALTER COLUMN seller_zip_code_prefix SET NOT NULL;
CREATE INDEX idx_dim_sellers_state ON public.dim_sellers (seller_state);
