-- =============================================================================
-- TABLE:   public.dim_products
-- GRAIN:   One row per product SKU (product_id)
-- PURPOSE: Product dimension with English category translation, listing quality
--          attributes, and carrier volumetric weight derivation.
-- =============================================================================

DROP TABLE IF EXISTS public.dim_products CASCADE;

CREATE TABLE public.dim_products AS
SELECT
    -- Primary Key
    p.product_id,

    -- Category Attributes (English translation with clean fallback)
    COALESCE(t.product_category_name_english, p.product_category_name, 'Uncategorized') AS category_name_english,
    COALESCE(p.product_category_name, 'Uncategorized') AS category_name_portuguese,

    -- Listing Quality Attributes
    p.product_name_lenght::INTEGER AS product_name_length,
    p.product_description_lenght::INTEGER AS product_description_length,
    p.product_photos_qty::INTEGER AS product_photos_qty,

    -- Physical / Shipping Attributes
    p.product_weight_g::NUMERIC AS product_weight_g,
    p.product_length_cm::NUMERIC AS product_length_cm,
    p.product_height_cm::NUMERIC AS product_height_cm,
    p.product_width_cm::NUMERIC AS product_width_cm,

    -- Derived Logistics Metrics: (L * W * H) / 5000 = volumetric weight in kg
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
