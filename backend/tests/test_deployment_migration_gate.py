from contextlib import contextmanager
from types import SimpleNamespace

import pytest

from scripts import migrate_deployment as gate


@pytest.mark.parametrize("env", [{}, {"VERCEL_ENV": "development"},
    {"VERCEL_ENV": "production"}, {"VERCEL_ENV": "production", "DATABASE_URL": "sqlite:///private.db"}])
def test_gate_refuses_implicit_target_and_ephemeral_database(env):
    with pytest.raises(gate.MigrationGateError):
        gate.run(env)


@pytest.fixture
def migration(monkeypatch):
    calls = []
    class Connection:
        def execute(self, statement, params=None): calls.append((str(statement), params))
    connection = Connection()
    current = {"heads": []}
    monkeypatch.setattr(gate.ScriptDirectory, "from_config", lambda config: SimpleNamespace(get_heads=lambda: ["current"]))
    monkeypatch.setattr(gate.MigrationContext, "configure", lambda supplied: SimpleNamespace(get_current_heads=lambda: current["heads"]))
    def upgrade(config, target):
        assert config.attributes["connection"] is connection
        calls.append(("upgrade", target))
        current["heads"] = ["current"]
    monkeypatch.setattr(gate.command, "upgrade", upgrade)
    return connection, calls, current


def test_production_migration_holds_lock_on_same_connection(migration):
    connection, calls, _ = migration
    gate.check_or_upgrade(connection, production=True)
    assert calls == [("SET LOCAL lock_timeout = '15s'", None),
                     ("SELECT pg_advisory_xact_lock(:lock_id)", {"lock_id": gate.LOCK_ID}), ("upgrade", "head")]


def test_preview_never_migrates_and_requires_exact_schema(migration):
    connection, calls, current = migration
    with pytest.raises(gate.MigrationGateError, match="Database schema is behind"):
        gate.check_or_upgrade(connection, production=False)
    assert calls == [("SET TRANSACTION READ ONLY", None)]
    current["heads"] = ["current"]
    gate.check_or_upgrade(connection, production=False)
    assert all(statement == "SET TRANSACTION READ ONLY" for statement, _ in calls)


def test_connection_failures_are_sanitized_and_engine_disposed(monkeypatch):
    disposed = []
    class Engine:
        @contextmanager
        def begin(self):
            raise RuntimeError("postgres://secret-user:do-not-expose@private-host/database")
            yield
        def dispose(self): disposed.append(True)
    monkeypatch.setattr(gate, "create_engine", lambda *args, **kwargs: Engine())
    with pytest.raises(gate.MigrationGateError) as error:
        gate.run({"VERCEL_ENV": "production", "DATABASE_URL": "postgres://configured-host/db"})
    assert "do-not-expose" not in str(error.value) and "private-host" not in str(error.value)
    assert disposed == [True]
