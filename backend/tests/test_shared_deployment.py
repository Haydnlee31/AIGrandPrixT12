import pytest
from sqlalchemy.engine import make_url

from backend.app.db import database_url
from scripts.run_shared import configure


@pytest.mark.parametrize("prefix", ["postgres://", "postgresql://", "postgresql+psycopg://"])
def test_hosted_database_url_preserves_credentials_and_tls(prefix):
    value = database_url(prefix + "user:p%40ss%25word@db.example:5432/mynah?sslmode=require")
    parsed = make_url(value)
    assert parsed.drivername == "postgresql+psycopg"
    assert parsed.password == "p@ss%word"
    assert parsed.query["sslmode"] == "require"


@pytest.mark.parametrize("settings", [
    {},
    {"DATABASE_URL": "sqlite:///temporary.db", "MYNAH_ACCOUNT_TOKEN": "a" * 43},
    {"DATABASE_URL": "postgres://host/mynah", "API_TOKENS": '{"demo-alex":"alex"}'},
    {"DATABASE_URL": "postgres://host/mynah", "API_TOKENS": '[]'},
    {"DATABASE_URL": "postgres://host/mynah", "API_TOKENS": '{invalid'},
    {"DATABASE_URL": "postgres://host/mynah", "MYNAH_ACCOUNT_TOKEN": "a" * 43, "MYNAH_ACCOUNT_ID": ""},
])
def test_shared_service_refuses_ephemeral_storage_and_default_access(settings):
    original = dict(settings)
    with pytest.raises(ValueError):
        configure(settings)
    assert settings == original


def test_shared_service_disables_demo_and_keeps_the_provisioned_account():
    import json
    settings = {"DATABASE_URL": "postgres://host/mynah", "MYNAH_ACCOUNT_TOKEN": "a" * 43,
                "MYNAH_ACCOUNT_ID": "chime", "DEMO_MODE": "true"}
    configure(settings)
    assert settings["DEMO_MODE"] == "false"
    assert settings["DATABASE_URL"] == "postgresql+psycopg://host/mynah"
    assert json.loads(settings["API_TOKENS"]) == {"a" * 43: "chime"}
    assert settings["MULTIMODAL_ENABLED"] == "true"


def test_managed_login_can_run_without_legacy_library_keys():
    settings = {"DATABASE_URL": "postgres://host/mynah", "NEON_AUTH_URL": "https://auth.example.org/db/auth"}
    configure(settings)
    assert settings["API_TOKENS"] == "{}"
    assert settings["MULTIMODAL_ENABLED"] == "true"


def test_emergency_multimodal_disable_remains_available():
    settings = {"DATABASE_URL": "postgres://host/mynah", "MYNAH_ACCOUNT_TOKEN": "a" * 43,
                "MULTIMODAL_ENABLED": "false"}
    configure(settings)
    assert settings["MULTIMODAL_ENABLED"] == "false"
