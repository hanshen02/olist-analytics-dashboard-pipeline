-- =============================================================================
-- TABLE:   public.dim_date
-- GRAIN:   One row per calendar day (date_key)
-- PURPOSE: Calendar dimension supporting time intelligence and reporting filters.
-- =============================================================================

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
FROM generate_series(
    '2016-09-01'::DATE,
    '2018-12-31'::DATE,
    '1 day'::INTERVAL
) AS g(d);

ALTER TABLE public.dim_date ADD PRIMARY KEY (date_key);
ALTER TABLE public.dim_date ALTER COLUMN full_date SET NOT NULL;
ALTER TABLE public.dim_date ALTER COLUMN year SET NOT NULL;
ALTER TABLE public.dim_date ALTER COLUMN month_num SET NOT NULL;
CREATE UNIQUE INDEX idx_dim_date_full_date ON public.dim_date (full_date);
