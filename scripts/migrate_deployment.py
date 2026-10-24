"""Deployment build gate: locked production migration, read-only preview check.

No HTTP migration endpoint, local .env loading, database URLs or raw SQL errors
are exposed. A failed gate stops the new deployment before promotion.
"""
from pathlib import Path
import os
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from alembic import command
from alembic.config import Config
from alembic.runtime.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine, text

from backend.app.db import database_url

LOCK_ID = 681904735210


class MigrationGateError(RuntimeError):
    pass


def configuration():
    config = Config(str(ROOT / "alembic.ini"))
    config.set_main_option("script_location", str(ROOT / "backend/migrations"))
    return config


def check_or_upgrade(connection, *, production, config=None):
    config = config or configuration()
    expected = set(ScriptDirectory.from_config(config).get_heads())
    if len(expected) != 1:
        raise MigrationGateError("Resolve migration branches before deploying.")
    if production:
        # Held on the exact connection used by Alembic, until the outer build
        # transaction commits. Concurrent production builds cannot race DDL.
        connection.execute(text("SET LOCAL lock_timeout = '15s'"))
        connection.execute(text("SELECT pg_advisory_xact_lock(:lock_id)"), {"lock_id": LOCK_ID})
        config.attributes["connection"] = connection
        command.upgrade(config, "head")
    else:
        connection.execute(text("SET TRANSACTION READ ONLY"))
    actual = set(MigrationContext.configure(connection).get_current_heads())
    if actual != expected:
        raise MigrationGateError("Database schema is behind this release. Migrate the production database, or prepare an isolated preview database, before deploying.")


def run(environment=None):
    environment = os.environ if environment is None else environment
    target = environment.get("VERCEL_ENV")
    if target not in {"production", "preview"}:
        raise MigrationGateError("Deployment schema gate requires VERCEL_ENV=production or preview. Use alembic for local databases.")
    raw = environment.get("DATABASE_URL")
    if not raw or not database_url(raw).startswith("postgresql+psycopg://"):
        raise MigrationGateError("Configure the deployment PostgreSQL DATABASE_URL before building.")
    engine = create_engine(database_url(raw), pool_pre_ping=True, connect_args={"connect_timeout": 10})
    try:
        with engine.begin() as connection:
            check_or_upgrade(connection, production=target == "production")
    except MigrationGateError:
        raise
    except Exception:
        # Database exceptions can embed URLs, query parameters and private rows.
        raise MigrationGateError("Deployment schema check failed; deployment stopped. Check database access, migration compatibility and competing builds.") from None
    finally:
        engine.dispose()
    return "Production schema migrated and verified." if target == "production" else "Preview schema verified without changes."


if __name__ == "__main__":
    try:
        print(run())
    except MigrationGateError as error:
        raise SystemExit(str(error)) from None
