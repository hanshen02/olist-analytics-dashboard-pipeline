"""
=============================================================================
SCRIPT:  scripts/ingest_to_postgres.py
PURPOSE: Production ELT Ingestion Script for Olist Brazilian E-Commerce
         Supports automated download from Kaggle API, schema initialization,
         and chunked batch streaming into PostgreSQL raw schema.
=============================================================================
"""

import os
import sys
import shutil
import logging
import argparse
from pathlib import Path
from typing import Dict, List

import pandas as pd
import psycopg2
from psycopg2 import sql
from psycopg2.extras import execute_batch
from dotenv import load_dotenv

# Logging Configuration
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger("olist_ingestion")

# CSV to Table Mapping Specification (ordered by relational dependency)
TABLE_FILE_MAP: Dict[str, str] = {
    # 1. Independent parent entities
    "customers": "olist_customers_dataset.csv",
    "sellers": "olist_sellers_dataset.csv",
    "products": "olist_products_dataset.csv",
    "product_category_name_translation": "product_category_name_translation.csv",
    "geolocation": "olist_geolocation_dataset.csv",
    "leads_qualified": "olist_marketing_qualified_leads_dataset.csv",

    # 2. Orders header (references customers)
    "orders": "olist_orders_dataset.csv",

    # 3. Dependent child line-items, payments & reviews (reference orders, products, sellers)
    "order_items": "olist_order_items_dataset.csv",
    "order_payments": "olist_order_payments_dataset.csv",
    "order_reviews": "olist_order_reviews_dataset.csv",

    # 4. Closed deals (references leads_qualified)
    "leads_closed": "olist_closed_deals_dataset.csv",
}

# Combines the two official Kaggle dataset for full E-Commerce + Marketing pipeline
KAGGLE_DATASETS: List[str] = [
    "olistbr/brazilian-ecommerce",       # 9 E-Commerce tables
    "olistbr/marketing-funnel-olist",     # 2 Marketing funnel tables
]

def ensure_directory(path: Path) -> Path:
    # Safely creates a directory and all parent directories.
    resolved = Path(path).resolve()
    if resolved.exists() and resolved.is_dir():
        return resolved

    try:
        os.makedirs(resolved, exist_ok=True)
        logger.info(f"Created directory: '{resolved}'")
        return resolved
    except OSError as err:
        logger.error(f"Failed to create target directory '{resolved}': {err}")
        logger.error("Please verify filesystem permissions or provide an alternative path via --data-dir.")
        sys.exit(1)

def download_from_kaggle(target_dir: Path) -> bool:
    # Downloads Olist datasets directly from Kaggle using kagglehub into target_dir.
    # Returns True if all datasets were downloaded and staged successfully.
    try:
        import kagglehub
    except ImportError:
        logger.error(
            "The 'kagglehub' package is required to download datasets directly from Kaggle.\n"
            "Install it via: pip install kagglehub"
        )
        return False

    target_path = ensure_directory(target_dir)
    logger.info(f"Target staging directory verified: '{target_path}'")
    logger.info("Initializing automated Kaggle dataset download...")

    overall_success = True
    for dataset_handle in KAGGLE_DATASETS:
        logger.info(f"Downloading dataset '{dataset_handle}' via Kaggle API...")
        try:
            download_path = kagglehub.dataset_download(dataset_handle)
            logger.info(f"Downloaded to local cache: {download_path}")

            source_path = Path(download_path)
            copied_count = 0
            for csv_file in source_path.glob("*.csv"):
                dest_file = target_path / csv_file.name
                shutil.copy2(csv_file, dest_file)
                copied_count += 1
                logger.info(f"Staged: {csv_file.name}")

            logger.info(f"Successfully staged {copied_count} CSV files from '{dataset_handle}'.")
        except Exception as e:
            logger.error(f"Failed to download '{dataset_handle}' from Kaggle: {e}")
            logger.warning(
                "Tip: If prompted for credentials, ensure you have ~/.kaggle/kaggle.json configured "
                "or set KAGGLE_USERNAME and KAGGLE_KEY environment variables."
            )
            overall_success = False

    return overall_success

def get_db_connection(args: argparse.Namespace):
    # Establishes connection to PostgreSQL using CLI args or environment variables.
    load_dotenv(Path(__file__).resolve().parent / ".env")
    load_dotenv(Path.cwd() / ".env")

    host = args.host or os.getenv("PGHOST")
    port = args.port or os.getenv("PGPORT")
    dbname = args.dbname or os.getenv("PGDATABASE")
    user = args.user or os.getenv("PGUSER")
    password = args.password or os.getenv("PGPASSWORD")

    if not all([host, user, password]):
        logger.error(
            "Missing required database connection parameters.\n"
            "Provide --host, --user, --password flags or configure your .env file."
        )
        sys.exit(1)

    logger.info(f"Connecting to PostgreSQL database '{dbname}' on {host}:{port or '5432'} as user '{user}'...")
    try:
        conn = psycopg2.connect(
            host=host,
            port=port,
            dbname=dbname,
            user=user,
            password=password,
            connect_timeout=15,
        )
        conn.autocommit = False
        return conn
    except psycopg2.OperationalError as e:
        logger.error(f"Failed to connect to database: {e}")
        sys.exit(1)

def stream_csv_to_postgres(conn, table_name: str, csv_path: Path, batch_size: int = 5000, truncate: bool = False):
    # Reads CSV in chunks and inserts records into raw.<table_name>.
    cursor = conn.cursor()
    schema_table = f"raw.{table_name}"

    # Check to prevent duplicate insertions if table already populated
    try:
        cursor.execute(f"SELECT COUNT(*) FROM {schema_table};")
        existing_count = cursor.fetchone()[0]
    except Exception:
        conn.rollback()
        existing_count = 0

    if existing_count > 0:
        if truncate:
            logger.info(f"Flag --truncate set. Truncating '{schema_table}' ({existing_count:,} rows)...")
            cursor.execute(f"TRUNCATE TABLE {schema_table} CASCADE;")
            conn.commit()
        else:
            logger.info(
                f"Table '{schema_table}' already contains {existing_count:,} rows. "
                "Skipping to prevent duplication (pass --truncate to overwrite)."
            )
            cursor.close()
            return

    logger.info(f"Reading '{csv_path.name}' -> target: '{schema_table}'...")

    try:
        first_chunk = pd.read_csv(csv_path, nrows=5, encoding="utf-8-sig")
    except Exception as e:
        logger.error(f"Failed to read header of '{csv_path.name}': {e}")
        cursor.close()
        return

    columns = [col.strip().lower() for col in first_chunk.columns]

    cols_sql = sql.SQL(", ").join([sql.Identifier(col) for col in columns])
    vals_sql = sql.SQL(", ").join([sql.Placeholder() for _ in columns])
    insert_query = sql.SQL("INSERT INTO {table} ({cols}) VALUES ({vals})").format(
        table=sql.SQL(schema_table),
        cols=cols_sql,
        vals=vals_sql,
    )

    total_rows = 0
    try:
        reader = pd.read_csv(
            csv_path,
            chunksize=batch_size,
            dtype=str,
            keep_default_na=False,
            encoding="utf-8-sig",
        )

        for chunk_idx, chunk in enumerate(reader):
            # Convert empty strings to None for NULL handling
            chunk = chunk.where(pd.notnull(chunk), None)
            chunk = chunk.replace("", None)

            records = [tuple(row) for row in chunk.values]
            execute_batch(cursor, insert_query.as_string(conn), records, page_size=batch_size)
            total_rows += len(records)

            if (chunk_idx + 1) % 5 == 0 or len(records) < batch_size:
                logger.info(f"Loaded {total_rows:,} rows into {schema_table}...")

        conn.commit()
        logger.info(f"Successfully loaded {total_rows:,} rows into '{schema_table}'.")
    except Exception as e:
        conn.rollback()
        logger.error(f"Failed while streaming '{csv_path.name}' into '{schema_table}': {e}")
    finally:
        cursor.close()

def main():
    parser = argparse.ArgumentParser(
        description="Ingest Olist CSV datasets into Supabase / PostgreSQL raw schema."
    )
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=Path("./data"),
        help="Directory containing or staging raw CSV files (default: ./data)",
    )
    parser.add_argument(
        "--download-kaggle",
        action="store_true",
        help="Automatically download datasets from Kaggle API into --data-dir before ingestion",
    )
    parser.add_argument(
        "--download-only",
        action="store_true",
        help="Only download datasets from Kaggle into --data-dir without database connection",
    )
    parser.add_argument("--host", type=str, help="PostgreSQL host")
    parser.add_argument("--port", type=str, help="PostgreSQL port")
    parser.add_argument("--dbname", type=str, help="Database name")
    parser.add_argument("--user", type=str, help="PostgreSQL username")
    parser.add_argument("--password", type=str, help="PostgreSQL password")
    parser.add_argument(
        "--schema-only",
        action="store_true",
        help="Initialize raw schema tables without loading data",
    )
    parser.add_argument(
        "--truncate",
        action="store_true",
        help="Truncate existing raw tables before streaming data (overwrites existing rows)",
    )

    args = parser.parse_args()

    # 1. Safely resolve and ensure target directory
    data_dir = ensure_directory(args.data_dir)
    csv_files_present = any(data_dir.glob("*.csv"))

    # 2. Handle Kaggle download
    if args.download_only or args.download_kaggle or (not csv_files_present and not args.schema_only):
        if args.download_only or args.download_kaggle:
            logger.info("Fetching fresh dataset from Kaggle...")
            success = download_from_kaggle(data_dir)
            if args.download_only:
                if success:
                    logger.info("Kaggle download completed. Exiting (--download-only mode).")
                else:
                    logger.error("Kaggle download encountered errors.")
                return
        elif not csv_files_present:
            logger.info(f"No CSV files found in '{data_dir}'. Attempting automated Kaggle download...")
            download_from_kaggle(data_dir)

    # 3. Connect to PostgreSQL
    conn = get_db_connection(args)

    # 4. Initialize Raw Schema DDL
    schema_init_path = Path("./sql/raw_schema_init.sql").resolve()
    if schema_init_path.exists():
        logger.info("Initializing raw schema structure from sql/raw_schema_init.sql...")
        with open(schema_init_path, "r", encoding="utf-8-sig") as f:
            ddl_sql = f.read().lstrip("\ufeff").strip()
        with conn.cursor() as cur:
            cur.execute(ddl_sql)
        conn.commit()
        logger.info("Raw schema initialized successfully.")

    if args.schema_only:
        logger.info("--schema-only flag provided. Exiting without data ingestion.")
        conn.close()
        return

    # 5. Stream CSV files into raw tables
    csv_files = list(data_dir.glob("*.csv"))
    if not csv_files:
        logger.warning(
            f"No CSV files found in '{data_dir}'. "
            f"Run with --download-kaggle or place CSVs in '{data_dir}' to load data."
        )
        conn.close()
        return

    logger.info(f"Found {len(csv_files)} CSV files in '{data_dir}'. Beginning database ingestion...")
    for table_name, filename in TABLE_FILE_MAP.items():
        csv_file = data_dir / filename
        if csv_file.exists():
            stream_csv_to_postgres(conn, table_name, csv_file, truncate=args.truncate)
        else:
            logger.warning(f"File not found: '{filename}'. Skipping table '{table_name}'.")

    conn.close()
    logger.info("Ingestion pipeline completed successfully.")

if __name__ == "__main__":
    main()
