"""Quick Supabase / Postgres connection test using .env in this folder."""
import os
import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent / ".env", override=True)

required = ["SUPABASE_HOST", "SUPABASE_PORT", "SUPABASE_DB", "SUPABASE_USER", "SUPABASE_PASSWORD"]
missing = [k for k in required if not os.getenv(k)]
if missing:
    print("Missing in .env:", ", ".join(missing))
    sys.exit(1)

password = os.environ["SUPABASE_PASSWORD"]
if "your-password" in password.lower():
    print("Fix .env: SUPABASE_PASSWORD should be ONLY your Supabase DB password.")
    print("  (Remove any pasted placeholder text like 'your-password-here'.)")
    sys.exit(1)

try:
    import psycopg2
except ImportError:
    print("Install dependencies: pip install psycopg2-binary python-dotenv")
    sys.exit(1)

print("Connecting to target (PostgreSQL/Supabase)...")
print(f"  Host: {os.environ['SUPABASE_HOST']}")
print(f"  Port: {os.environ['SUPABASE_PORT']}")
print(f"  User: {os.environ['SUPABASE_USER']}")
print(f"  DB:   {os.environ['SUPABASE_DB']}")

try:
    conn = psycopg2.connect(
        host=os.environ["SUPABASE_HOST"],
        port=os.environ["SUPABASE_PORT"],
        dbname=os.environ["SUPABASE_DB"],
        user=os.environ["SUPABASE_USER"],
        password=password,
        sslmode="require",
    )
    cur = conn.cursor()

    cur.execute("SELECT version()")
    print("\nConnected OK.")
    print("Postgres:", cur.fetchone()[0][:60], "...")

    cur.execute(
        """
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'dw'
        ORDER BY table_name
        """
    )
    tables = [r[0] for r in cur.fetchall()]
    print("\nTables in schema 'dw':", tables if tables else "(none — run Part 1 SQL in Supabase)")

    for table in ("dim_date", "dim_facility", "dim_product", "fact_orders"):
        if table in tables:
            cur.execute(f"SELECT COUNT(*) FROM dw.{table}")
            print(f"  dw.{table}: {cur.fetchone()[0]} rows")

    cur.close()
    conn.close()
    print("\nTest passed.")

except Exception as e:
    print("\nConnection failed:")
    print(f"  {type(e).__name__}: {e}")
    print("\nChecks:")
    print("  - SUPABASE_PASSWORD is only your Supabase DB password (no extra text)")
    print("  - Project is Active in Supabase dashboard")
    print("  - Part 1 tables created (SQL Editor)")
    if "translate host name" in str(e).lower() or "network is unreachable" in str(e).lower():
        print("\nIPv4 / DNS fix (common on Windows):")
        print("  Supabase → Project Settings → Database → Connection string")
        print("  Choose 'Session pooler' (not Direct), copy host + user into .env:")
        print("    SUPABASE_HOST=aws-0-xx-xxxx.pooler.supabase.com")
        print("    SUPABASE_USER=postgres.<your-project-ref>")
        print("    SUPABASE_PORT=5432")
    sys.exit(1)
