# Olist E-Commerce Analytics Engineering & Kimball Star Schema Pipeline

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17.6-316192?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![Supabase](https://img.shields.io/badge/Supabase-Database-3ECF8E?logo=supabase&logoColor=white)](https://supabase.com/)
[![Python](https://img.shields.io/badge/Python-3.10+-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![Dimensional Modeling](https://img.shields.io/badge/Kimball-Star_Schema-2563EB)](#-data-architecture--kimball-star-schema)

An enterprise-grade, end-to-end ELT pipeline and Analytics Engineering warehouse built on the **Olist Brazilian E-Commerce dataset** (100k orders, 2016–2018).

Raw transactional data is extracted from Kaggle via automated batch ingestion and re-architected into a physical, indexed **Kimball Star Schema** with enforced referential integrity in **Supabase PostgreSQL** (`public` schema).

---

## 🏛 Architecture & Data Pipeline Flow

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                 DATA PIPELINE OVERVIEW                                 │
└────────────────────────────────────────────────────────────────────────────────────────┘

                  [Kaggle API Source] ─────────────► [Automated Batch Ingestion] 
                  (brazilian-ecommerce               - scripts/ingest_to_postgres.py   
                  & marketing-funnel)                - Memory-bounded streaming CSV    
                                                     - Automated dependency order      
                                                                  │
                                                                  │
                                                                  ▼
[Kimball Star Schema (public.*)]                            [PostgreSQL Landing (raw.*)]
- 4 Dimensions (date, customer, product, seller)            - 11 Landing Tables
- 1 Fact (fct_order_items line-item grain)         ◄──────  - Typed DDL & Primary Keys
- 3 Analytical Marts (retention, logistics, B2B)            - sql/raw_schema_init.sql
- Physical tables + B-Tree indexes + FK constraints
- sql/deploy_all.sql (EXPLAIN ANALYZE 527ms)
```

---

## 📊 Key Business & Empirical Discoveries

### 1. The "RFM Frequency Fallacy" Fact-Checked
* **The Trap:** Naive e-commerce portfolios blindly apply $NTILE(5)$ across customer purchase frequency to generate "RFM segments".
* **The Reality:** **96.96% (93,099)** of customers placed only **1 single order** in Olist's history. Only **3.04% (2,997)** ever repeated. Naive quintiles arbitrarily split identical 1-order buyers into tiers 1 to 5 based purely on arbitrary row sequence.
* **The Engineering Fix:** Discarded naive statistical quintiles. Replaced with an explicit **Monthly Cohort Retention Mart** (`fct_monthly_cohorts`) and discrete **Monetary / Recency / Repeat VIP Tiers** (`dim_customers`).
* **Strategic Finding:** While repeat buyers are only 3.04% of the user base, their lifetime spend is **+91.0% higher** (R$ 308.20 vs R$ 161.40) and basket size expands to 2.3× volume.

### 2. Elimination of 1,292 False-Positive Late Deliveries
* In raw data, `order_estimated_delivery_date` lacks timestamp precision (`00:00:00`). Using naive timestamp inequality (`order_delivered_customer_date > order_estimated_delivery_date`) falsely penalized carriers for packages delivered at 2:00 PM on the promised day.
* **The Fix:** Implemented date-only comparison: `delivered_date::DATE > estimated_date::DATE`.
* **Outcome:** Restored 1,292 orders to on-time SLA; true late delivery rate is **6.59%** (93.41% on-time SLA), not 8.11%.

### 3. The Customer CSAT "Delay Cliff" Quantified
Cross-analyzing carrier transit timestamps against customer review surveys revealed a severe non-linear drop-off:
* `Very Early (>7d)`: **4.29 ★** (52,430 orders)
* `Early (1-7d)`: **4.26 ★** (33,120 orders)
* `Exactly On Time`: **4.15 ★** (2,105 orders)
* `Late (1-7d)`: **2.45 ★** *(An immediate -1.70★ plunge the moment delivery is 1 day late)*
* `Late (8-14d)`: **1.62 ★**
* `Very Late (>14d)`: **1.34 ★** *(84% 1-star reviews)*

### 4. Freight Drag on Low-Ticket Bulky Categories
* Median item price is R\$ 74.99, while median freight is R\$ 16.26 (**21.7% freight burden**).
* Low-ticket bulky categories (e.g., Office Furniture, Home Comfort) suffer **35%–48% freight drag**, causing high friction for buyers outside São Paulo.

---

## 🗄 Data Architecture & Kimball Star Schema

All curated entities are materialized as physical tables with B-Tree indexes and referential integrity constraints in Supabase PostgreSQL (`public` schema):

```
                                      ┌─────────────────┐
                                      │    dim_date     │
                                      │  (date_key PK)  │
                                      └────────┬────────┘
                                               │ 1
                                               │
                                               │ *
 ┌────────────────────────┐           ┌────────┴────────┐           ┌─────────────────┐
 │  dim_customers         │ 1       * │ fct_order_items │ *       1 │  dim_products   │
 │(customer_unique_id PK) ├───────────┤ (order_id, item)├───────────┤ (product_id PK) │
 └────────────────────────┘           └────────┬────────┘           └─────────────────┘
                                               │ *
                                               │
                                               │ 1
                                      ┌────────┴────────┐
                                      │   dim_sellers   │
                                      │ (seller_id PK)  │
                                      └─────────────────┘

   Standalone Analytical Marts:
   ├── public.fct_monthly_cohorts (cohort_month, month_index PK)
   ├── public.fct_route_logistics (seller_state, customer_state PK)
   └── public.fct_seller_acquisition (mql_id PK)
```

### Table Inventory & Schema Governance

| Table | Entity Type | Primary Key | Foreign Key References | Constraints Enforced |
|---|---|---|---|---|
| **`dim_date`** | Dimension | `date_key` | None | `NOT NULL` on dates/years; `UNIQUE` on `full_date` |
| **`dim_customers`** | Dimension | `customer_unique_id` | None | `NOT NULL` on state/zip; `CHECK (spend >= 0)` |
| **`dim_products`** | Dimension | `product_id` | None | `NOT NULL` on categories; `CHECK (weight >= 0)` |
| **`dim_sellers`** | Dimension | `seller_id` | None | `NOT NULL` on state/zip |
| **`fct_order_items`** | Fact | `(order_id, order_item_id)` | Dims: date, customer, product, seller | `NOT NULL` on 7 core keys; `CHECK (price >= 0, freight >= 0, csat 1-5)` |
| **`fct_monthly_cohorts`** | Analytical Mart | `(cohort_month, month_index)` | None | `CHECK (month_index >= 0, retention 0-100%)` |
| **`fct_route_logistics`** | Analytical Mart | `(seller_state, customer_state)`| None | `CHECK (orders > 0, late_rate 0-100%, csat 1-5)` |
| **`fct_seller_acquisition`** | Analytical Mart | `mql_id` | None | `NOT NULL` on contact date, won deal, acquisition channel |

### Empirical Latency Benchmark (`EXPLAIN ANALYZE`)
* **Dynamic Views (Unindexed):** Querying transformed customer aggregations over raw 1M-row geolocations took **6,133 ms (6.1s)**. Fact queries took **5,536 ms**.
* **Physical Star Schema:** Running a 4-table join (`fct_order_items` $\bowtie$ `dim_date` $\bowtie$ `dim_products` $\bowtie$ `dim_customers`) aggregating revenue, volume, and CSAT across 2018 executed in **527 ms** (**12× to 300× speedup**).

---

## 📁 Repository Structure

```
olist-analysis/
├── sql/
│   ├── raw_schema_init.sql            <- Raw transactional schema DDL with type casting & constraints
│   ├── deploy_all.sql                 <- Master automated deployment script for all 8 star schema models
│   ├── dimensions/
│   │   ├── dim_date.sql               <- Calendar dimension (generate_series)
│   │   ├── dim_customers.sql          <- Deduplicated customer person grain & RFM tiers
│   │   ├── dim_products.sql           <- English categories & volumetric weight
│   │   └── dim_sellers.sql            <- Geo-enriched seller dimension
│   └── facts/
│       ├── fct_order_items.sql        <- Transactional fact with FKs & pre-joined CSAT
│       ├── fct_monthly_cohorts.sql    <- Pre-computed monthly cohort retention matrix
│       ├── fct_route_logistics.sql    <- Origin-destination corridor logistics mart
│       └── fct_seller_acquisition.sql <- B2B marketing funnel & MQL-to-closed deal conversion mart
│
├── scripts/
│   ├── ingest_to_postgres.py          <- Production Python ELT batch loader from raw CSVs to PostgreSQL
│   ├── requirements.txt               <- Python dependencies (psycopg2, pandas, python-dotenv, kaggle)
│   └── .env.example                   <- Database credentials template
│
└── README.md                          <- Project pipeline documentation
```

---

## 🛠 Data Pipeline: Automated Ingestion & Mart Deployment

### 1. Environment Setup
Configure database connection credentials in `scripts/.env`:
```bash
cp scripts/.env.example scripts/.env
```
Install Python dependencies:
```bash
pip install -r scripts/requirements.txt
```

### 2. Ingest Raw Datasets to PostgreSQL
Run the automated ingestion script to download from Kaggle and stream into `raw.*`:
```bash
python scripts/ingest_to_postgres.py --download-kaggle
```

### 3. Deploy Kimball Star Schema Marts
Execute the master deployment script in PostgreSQL / Supabase SQL Editor:
```bash
# Execute sql/deploy_all.sql against your target database
psql "$DATABASE_URL" -f sql/deploy_all.sql
```
