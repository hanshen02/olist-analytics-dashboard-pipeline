-- =============================================================================
-- SCRIPT:  sql/raw_schema_init.sql
-- PURPOSE: Initialize Olist raw schema and 11 transactional landing tables.
--          Enforces PostgreSQL data types and relational constraints.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS raw;

-- 1. Customers (1 row per order token)
CREATE TABLE IF NOT EXISTS raw.customers (
    customer_id TEXT NOT NULL,
    customer_unique_id TEXT NOT NULL,
    customer_zip_code_prefix INTEGER,
    customer_city TEXT,
    customer_state TEXT,
    CONSTRAINT pk_customers PRIMARY KEY (customer_id)
);

-- 2. Sellers
CREATE TABLE IF NOT EXISTS raw.sellers (
    seller_id TEXT NOT NULL,
    seller_zip_code_prefix INTEGER,
    seller_city TEXT,
    seller_state TEXT,
    CONSTRAINT pk_sellers PRIMARY KEY (seller_id)
);

-- 3. Products
CREATE TABLE IF NOT EXISTS raw.products (
    product_id TEXT NOT NULL,
    product_category_name TEXT,
    product_name_lenght INTEGER,
    product_description_lenght INTEGER,
    product_photos_qty INTEGER,
    product_weight_g NUMERIC(8,2),
    product_length_cm NUMERIC(6,2),
    product_height_cm NUMERIC(6,2),
    product_width_cm NUMERIC(6,2),
    CONSTRAINT pk_products PRIMARY KEY (product_id)
);

-- 4. Category Name Translations
CREATE TABLE IF NOT EXISTS raw.product_category_name_translation (
    product_category_name TEXT NOT NULL,
    product_category_name_english TEXT,
    CONSTRAINT pk_product_category_name_translation PRIMARY KEY (product_category_name)
);

-- 5. Geolocation (Point coordinates; multiple coordinates per zip code prefix)
CREATE TABLE IF NOT EXISTS raw.geolocation (
    geolocation_zip_code_prefix INTEGER,
    geolocation_lat NUMERIC(9,6),
    geolocation_lng NUMERIC(9,6),
    geolocation_city TEXT,
    geolocation_state TEXT
);

-- 6. Orders
CREATE TABLE IF NOT EXISTS raw.orders (
    order_id TEXT NOT NULL,
    customer_id TEXT NOT NULL,
    order_status TEXT NOT NULL,
    order_purchase_timestamp TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    order_approved_at TIMESTAMP(0) WITHOUT TIME ZONE,
    order_delivered_carrier_date TIMESTAMP(0) WITHOUT TIME ZONE,
    order_delivered_customer_date TIMESTAMP(0) WITHOUT TIME ZONE,
    order_estimated_delivery_date TIMESTAMP(0) WITHOUT TIME ZONE,
    CONSTRAINT pk_orders PRIMARY KEY (order_id),
    CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES raw.customers (customer_id)
);

-- 7. Order Items (Line-item grain)
CREATE TABLE IF NOT EXISTS raw.order_items (
    order_id TEXT NOT NULL,
    order_item_id INTEGER NOT NULL,
    product_id TEXT NOT NULL,
    seller_id TEXT NOT NULL,
    shipping_limit_date TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    price NUMERIC(10,2) NOT NULL,
    freight_value NUMERIC(10,2) NOT NULL,
    CONSTRAINT pk_order_items PRIMARY KEY (order_id, order_item_id),
    CONSTRAINT fk_order_items_order FOREIGN KEY (order_id) REFERENCES raw.orders (order_id),
    CONSTRAINT fk_order_items_product FOREIGN KEY (product_id) REFERENCES raw.products (product_id),
    CONSTRAINT fk_order_items_seller FOREIGN KEY (seller_id) REFERENCES raw.sellers (seller_id)
);

-- 8. Order Payments
CREATE TABLE IF NOT EXISTS raw.order_payments (
    order_id TEXT NOT NULL,
    payment_sequential INTEGER NOT NULL,
    payment_type TEXT NOT NULL,
    payment_installments INTEGER NOT NULL,
    payment_value NUMERIC(10,2) NOT NULL,
    CONSTRAINT pk_order_payments PRIMARY KEY (order_id, payment_sequential),
    CONSTRAINT fk_order_payments_order FOREIGN KEY (order_id) REFERENCES raw.orders (order_id)
);

-- 9. Order Reviews
CREATE TABLE IF NOT EXISTS raw.order_reviews (
    review_id TEXT,
    order_id TEXT NOT NULL,
    review_score SMALLINT,
    review_comment_title TEXT,
    review_comment_message TEXT,
    review_creation_date TIMESTAMP(0) WITHOUT TIME ZONE,
    review_answer_timestamp TIMESTAMP(0) WITHOUT TIME ZONE,
    CONSTRAINT fk_order_reviews_order FOREIGN KEY (order_id) REFERENCES raw.orders (order_id)
);

-- 10. Marketing Qualified Leads (MQL)
CREATE TABLE IF NOT EXISTS raw.leads_qualified (
    mql_id TEXT NOT NULL,
    first_contact_date TIMESTAMP(0) WITHOUT TIME ZONE,
    landing_page_id TEXT,
    origin TEXT,
    CONSTRAINT pk_leads_qualified PRIMARY KEY (mql_id)
);

-- 11. Closed Deals (Won Deals)
CREATE TABLE IF NOT EXISTS raw.leads_closed (
    mql_id TEXT NOT NULL,
    seller_id TEXT,
    sdr_id TEXT,
    sr_id TEXT,
    won_date TIMESTAMP(0) WITHOUT TIME ZONE,
    business_segment TEXT,
    lead_type TEXT,
    lead_behaviour_profile TEXT,
    has_company TEXT,
    has_gtin TEXT,
    average_stock TEXT,
    business_type TEXT,
    declared_product_catalog_size NUMERIC(10,2),
    declared_monthly_revenue NUMERIC(10,2),
    CONSTRAINT pk_leads_closed PRIMARY KEY (mql_id),
    CONSTRAINT fk_leads_closed_mql FOREIGN KEY (mql_id) REFERENCES raw.leads_qualified (mql_id)
);