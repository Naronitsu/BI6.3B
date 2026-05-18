# Part 3

import os
import sys
from datetime import datetime
from pathlib import Path

import pyodbc
import psycopg2
from dotenv import load_dotenv
from psycopg2.extras import execute_values

load_dotenv(Path(__file__).resolve().parent / ".env", override=True)


def _require(name: str) -> str:
    v = os.getenv(name)
    if not v:
        print(f"missing {name}")
        sys.exit(1)
    return v


def _pg_connect():
    return psycopg2.connect(
        host=_require("SUPABASE_HOST"),
        port=_require("SUPABASE_PORT"),
        dbname=_require("SUPABASE_DB"),
        user=_require("SUPABASE_USER"),
        password=_require("SUPABASE_PASSWORD"),
        sslmode="require",
    )


def _mssql_connect():
    driver = os.getenv("MSSQL_ODBC_DRIVER", "ODBC Driver 17 for SQL Server")
    server = _require("MSSQL_SERVER").strip().replace("/", "\\")
    database = _require("MSSQL_DATABASE")
    user = os.getenv("MSSQL_USER", "")
    password = os.getenv("MSSQL_PASSWORD", "")
    tail = "Encrypt=yes;TrustServerCertificate=yes;Connection Timeout=60"
    if user.strip():
        conn_str = (
            f"DRIVER={{{driver}}};SERVER={server};DATABASE={database};"
            f"UID={user};PWD={password};{tail}"
        )
    else:
        conn_str = (
            f"DRIVER={{{driver}}};SERVER={server};DATABASE={database};"
            f"Trusted_Connection=yes;{tail}"
        )
    return pyodbc.connect(conn_str, timeout=60)


def _as_bool(v):
    if v is None:
        return False
    if isinstance(v, bool):
        return v
    return bool(int(v))


def _watermark(pg_cur, schema_table: str):
    pg_cur.execute(f"SELECT MAX(last_updated) FROM {schema_table}")
    row = pg_cur.fetchone()
    ts = row[0]
    if ts is None:
        return datetime(1900, 1, 1)
    return ts


def _fmt_ts(ts: datetime) -> str:
    return ts.strftime("%Y-%m-%d %H:%M:%S") + f".{ts.microsecond:06d}"


def _sync_dim_date(mssql_cur, pg_conn):
    name = "dim_date"
    print(f"[{name}] Starting sync...")
    pg_cur = pg_conn.cursor()
    wm = _watermark(pg_cur, "dw.dim_date")
    print(f"[{name}] Fetching records updated after {_fmt_ts(wm)}")
    mssql_cur.execute(
        """
        SELECT date_key, full_date, year, quarter, month, month_name,
               day_of_month, day_of_week, is_weekend, last_updated
        FROM dw.dim_date
        WHERE last_updated > ?
        """,
        wm,
    )
    rows = mssql_cur.fetchall()
    if not rows:
        print(f"[{name}] No new records found.")
        pg_cur.close()
        return
    tuples = [
        (
            r.date_key,
            r.full_date,
            r.year,
            r.quarter,
            r.month,
            r.month_name,
            r.day_of_month,
            r.day_of_week,
            _as_bool(r.is_weekend),
            r.last_updated,
        )
        for r in rows
    ]
    sql = """
        INSERT INTO dw.dim_date (
            date_key, full_date, year, quarter, month, month_name,
            day_of_month, day_of_week, is_weekend, last_updated
        ) VALUES %s
        ON CONFLICT (date_key) DO UPDATE SET
            full_date = EXCLUDED.full_date,
            year = EXCLUDED.year,
            quarter = EXCLUDED.quarter,
            month = EXCLUDED.month,
            month_name = EXCLUDED.month_name,
            day_of_month = EXCLUDED.day_of_month,
            day_of_week = EXCLUDED.day_of_week,
            is_weekend = EXCLUDED.is_weekend,
            last_updated = EXCLUDED.last_updated
    """
    execute_values(pg_cur, sql, tuples, page_size=500)
    pg_conn.commit()
    print(f"[{name}] Upserted {len(tuples)} rows.")
    pg_cur.close()


def _sync_dim_facility(mssql_cur, pg_conn):
    name = "dim_facility"
    print(f"[{name}] Starting sync...")
    pg_cur = pg_conn.cursor()
    wm = _watermark(pg_cur, "dw.dim_facility")
    print(f"[{name}] Fetching records updated after {_fmt_ts(wm)}")
    mssql_cur.execute(
        """
        SELECT facility_key, facility_id_source, facility_name, facility_type,
               country_name, region_name, last_updated
        FROM dw.dim_facility
        WHERE last_updated > ?
        """,
        wm,
    )
    rows = mssql_cur.fetchall()
    if not rows:
        print(f"[{name}] No new records found.")
        pg_cur.close()
        return
    tuples = [
        (
            r.facility_key,
            r.facility_id_source,
            r.facility_name,
            r.facility_type,
            r.country_name,
            r.region_name,
            r.last_updated,
        )
        for r in rows
    ]
    sql = """
        INSERT INTO dw.dim_facility (
            facility_key, facility_id_source, facility_name, facility_type,
            country_name, region_name, last_updated
        ) VALUES %s
        ON CONFLICT (facility_key) DO UPDATE SET
            facility_id_source = EXCLUDED.facility_id_source,
            facility_name = EXCLUDED.facility_name,
            facility_type = EXCLUDED.facility_type,
            country_name = EXCLUDED.country_name,
            region_name = EXCLUDED.region_name,
            last_updated = EXCLUDED.last_updated
    """
    execute_values(pg_cur, sql, tuples, page_size=500)
    pg_conn.commit()
    print(f"[{name}] Upserted {len(tuples)} rows.")
    pg_cur.close()


def _sync_dim_product(mssql_cur, pg_conn):
    name = "dim_product"
    print(f"[{name}] Starting sync...")
    pg_cur = pg_conn.cursor()
    wm = _watermark(pg_cur, "dw.dim_product")
    print(f"[{name}] Fetching records updated after {_fmt_ts(wm)}")
    mssql_cur.execute(
        """
        SELECT product_key, product_id_source, product_name, category_name,
               unit_price, is_active, row_start_date, row_end_date, is_current,
               last_updated
        FROM dw.dim_product
        WHERE last_updated > ?
        """,
        wm,
    )
    rows = mssql_cur.fetchall()
    if not rows:
        print(f"[{name}] No new records found.")
        pg_cur.close()
        return
    tuples = [
        (
            r.product_key,
            r.product_id_source,
            r.product_name,
            r.category_name,
            r.unit_price,
            _as_bool(r.is_active),
            r.row_start_date,
            r.row_end_date,
            _as_bool(r.is_current),
            r.last_updated,
        )
        for r in rows
    ]
    sql = """
        INSERT INTO dw.dim_product (
            product_key, product_id_source, product_name, category_name,
            unit_price, is_active, row_start_date, row_end_date, is_current,
            last_updated
        ) VALUES %s
        ON CONFLICT (product_key) DO UPDATE SET
            product_id_source = EXCLUDED.product_id_source,
            product_name = EXCLUDED.product_name,
            category_name = EXCLUDED.category_name,
            unit_price = EXCLUDED.unit_price,
            is_active = EXCLUDED.is_active,
            row_start_date = EXCLUDED.row_start_date,
            row_end_date = EXCLUDED.row_end_date,
            is_current = EXCLUDED.is_current,
            last_updated = EXCLUDED.last_updated
    """
    execute_values(pg_cur, sql, tuples, page_size=500)
    pg_conn.commit()
    print(f"[{name}] Upserted {len(tuples)} rows.")
    pg_cur.close()


def _sync_fact_orders(mssql_cur, pg_conn):
    name = "fact_orders"
    print(f"[{name}] Starting sync...")
    pg_cur = pg_conn.cursor()
    wm = _watermark(pg_cur, "dw.fact_orders")
    print(f"[{name}] Fetching records updated after {_fmt_ts(wm)}")
    mssql_cur.execute(
        """
        SELECT order_line_key, date_key, facility_key, product_key, order_id,
               quantity, unit_price_sold, line_total, last_updated
        FROM dw.fact_orders
        WHERE last_updated > ?
        """,
        wm,
    )
    rows = mssql_cur.fetchall()
    if not rows:
        print(f"[{name}] No new records found.")
        pg_cur.close()
        return
    tuples = [
        (
            r.order_line_key,
            r.date_key,
            r.facility_key,
            r.product_key,
            r.order_id,
            r.quantity,
            r.unit_price_sold,
            r.line_total,
            r.last_updated,
        )
        for r in rows
    ]
    sql = """
        INSERT INTO dw.fact_orders (
            order_line_key, date_key, facility_key, product_key, order_id,
            quantity, unit_price_sold, line_total, last_updated
        ) VALUES %s
        ON CONFLICT (order_line_key) DO UPDATE SET
            date_key = EXCLUDED.date_key,
            facility_key = EXCLUDED.facility_key,
            product_key = EXCLUDED.product_key,
            order_id = EXCLUDED.order_id,
            quantity = EXCLUDED.quantity,
            unit_price_sold = EXCLUDED.unit_price_sold,
            line_total = EXCLUDED.line_total,
            last_updated = EXCLUDED.last_updated
    """
    execute_values(pg_cur, sql, tuples, page_size=500)
    pg_conn.commit()
    print(f"[{name}] Upserted {len(tuples)} rows.")
    pg_cur.close()


def main():
    print("Connecting to source (SQL Server)...")
    mssql = _mssql_connect()
    mssql_cur = mssql.cursor()
    print("Connecting to target (PostgreSQL/Supabase)...")
    pg = _pg_connect()
    try:
        _sync_dim_date(mssql_cur, pg)
        _sync_dim_facility(mssql_cur, pg)
        _sync_dim_product(mssql_cur, pg)
        _sync_fact_orders(mssql_cur, pg)
    finally:
        mssql_cur.close()
        mssql.close()
        pg.close()


if __name__ == "__main__":
    main()
