"""Prepare one OpCo's database on the shared PostgreSQL server. Idempotent.

Run by the db-init job with the server admin. Does what Terraform's azurerm
provider cannot express:

  1. a login role for this instance only (Open WebUI never uses the admin)
  2. REVOKE CONNECT ... FROM PUBLIC: by default every role on the server may
     connect to every database, so a second OpCo's role could read this one
  3. the vector extension (the app role is not allowed to create extensions)
  4. the right to create tables in schema public (not granted since PostgreSQL 15)

Uses psycopg 3, which the Open WebUI image ships.
"""

import os
import sys

import psycopg
from psycopg import sql

ADMIN_URL = os.environ["PG_ADMIN_URL"]  # .../postgres?sslmode=require
APP_DB = os.environ["APP_DB"]
APP_ROLE = os.environ["APP_ROLE"]
APP_DB_PASSWORD = os.environ["APP_DB_PASSWORD"]


def log(message: str) -> None:
    print(f"[db-init] {message}", flush=True)


def url_for_database(url: str, database: str) -> str:
    """Same server and credentials, different database."""
    base, _, query = url.partition("?")
    base = base.rsplit("/", 1)[0] + "/" + database
    return f"{base}?{query}" if query else base


def main() -> int:
    role = sql.Identifier(APP_ROLE)
    database = sql.Identifier(APP_DB)
    password = sql.Literal(APP_DB_PASSWORD)

    with psycopg.connect(ADMIN_URL, autocommit=True) as conn:
        exists = conn.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (APP_ROLE,)).fetchone()
        if exists:
            # Keep the role in step with Key Vault (password rotation = re-run).
            conn.execute(sql.SQL("ALTER ROLE {} LOGIN PASSWORD {}").format(role, password))
            log(f"role {APP_ROLE} exists, password set")
        else:
            conn.execute(sql.SQL("CREATE ROLE {} LOGIN PASSWORD {}").format(role, password))
            log(f"role {APP_ROLE} created")

        conn.execute(sql.SQL("REVOKE CONNECT ON DATABASE {} FROM PUBLIC").format(database))
        conn.execute(sql.SQL("GRANT CONNECT, CREATE, TEMPORARY ON DATABASE {} TO {}").format(database, role))
        log(f"database {APP_DB}: CONNECT revoked from PUBLIC, granted to {APP_ROLE}")

    with psycopg.connect(url_for_database(ADMIN_URL, APP_DB), autocommit=True) as conn:
        conn.execute("CREATE EXTENSION IF NOT EXISTS vector")
        conn.execute(sql.SQL("GRANT ALL ON SCHEMA public TO {}").format(role))
        version = conn.execute("SELECT extversion FROM pg_extension WHERE extname = 'vector'").fetchone()
        log(f"extension vector {version[0] if version else '?'} ready, schema public granted")

    log("DB_INIT_OK")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001
        log(f"FAILED: {exc}")
        sys.exit(1)
