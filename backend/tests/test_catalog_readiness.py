"""Relay diagnostics cover catalog setup independently of paid AI access."""
import sqlite3

from fastapi.testclient import TestClient
import httpx
import pytest
from sqlalchemy import delete, event

from backend.app.capture_preview import create_app
from backend.app.catalog.service import import_dataset, revoke_feed
from backend.app.db import Base, CatalogOffer, CatalogProduct, SavedItem, make_database


TOKEN = "readiness-test-relay-token"
AUTH = {"Authorization": "Bearer " + TOKEN}
UNAVAILABLE = {"status": "catalog_unavailable", "catalog_count": 0, "sources": []}


def record(source, identity):
    return {"source_id": source, "source_record_id": identity,
            "data_kind": "synthetic" if source == "synthetic" else "open_dataset",
            "title": "A public catalog product", "category": "Watches",
            "merchant": {"platform": source}, "offer": {"id": identity, "environment": "local"}}


def load(factory, source, count, version="first"):
    return import_dataset(factory, source, [record(source, str(index)) for index in range(count)],
                          version=version, checksum="a" * 64)


def app_for(path=None, factory=None, *, api_key=""):
    def reject_upstream(_request):
        raise AssertionError("Catalog readiness must not call an AI or merchant provider")

    app = create_app(api_key=api_key, token=TOKEN, recommendation_factory=factory,
                     transport=httpx.MockTransport(reject_upstream))
    if path is not None:
        app.state.recommendation_service.path = path
    return app


@pytest.fixture
def database(tmp_path):
    path = tmp_path / "catalog.db"
    engine, factory = make_database("sqlite:///" + str(path))
    Base.metadata.create_all(engine)
    yield engine, factory, path
    engine.dispose()


def test_status_requires_relay_auth_before_database_access(tmp_path, monkeypatch):
    app = app_for(tmp_path / "not-created.db", api_key="private-provider-key")
    called = []
    monkeypatch.setattr(app.state.recommendation_service, "catalog_status", lambda: called.append(True))
    with TestClient(app) as client:
        for headers in ({}, {"Authorization": "Bearer wrong"}):
            response = client.get("/v1/catalog/status", headers=headers)
            assert response.status_code == 401
            assert response.json()["error"]["code"] == "unauthorized"
            assert response.headers["cache-control"] == "no-store"
            assert TOKEN not in response.text and "private-provider-key" not in response.text
        assert not called
        # Catalog readiness is separate from this existing AI configuration check.
        assert client.get("/health").json() == {"ready": True}


def test_ready_reports_only_public_eligible_source_counts(database):
    engine, factory, _ = database
    load(factory, "abo", 2)
    load(factory, "open_products_facts", 1)
    load(factory, "synthetic", 3)
    with factory.begin() as db:
        db.add(SavedItem(id="private-find", user_id="private-user", original_url="https://example.org/private",
                         canonical_url="https://example.org/private", title="PRIVATE_LIBRARY_TITLE", source="web"))
    statements = []

    def observe(_connection, _cursor, statement, _parameters, _context, _many):
        statements.append(statement.casefold())

    event.listen(engine, "before_cursor_execute", observe)
    try:
        with TestClient(app_for(factory=factory)) as client:
            response = client.get("/v1/catalog/status", headers=AUTH)
            assert response.status_code == 200
            assert response.json() == {
                "status": "ready", "catalog_count": 3,
                "sources": [{"source_id": "abo", "record_count": 2},
                            {"source_id": "open_products_facts", "record_count": 1}],
            }
            assert response.headers["cache-control"] == "no-store"
            assert "PRIVATE_LIBRARY_TITLE" not in response.text
            assert client.get("/health").json() == {"ready": False}
        assert not any("saved_items" in statement or "evidence" in statement for statement in statements)
        assert not any(statement.lstrip().startswith(("insert", "update", "delete")) for statement in statements)
    finally:
        event.remove(engine, "before_cursor_execute", observe)


@pytest.mark.parametrize("state", ["missing", "empty", "corrupt", "wrong_schema"])
def test_unprepared_database_returns_safe_unavailable_state(tmp_path, state):
    path = tmp_path / "private-catalog-location.db"
    if state == "empty":
        path.touch()
    elif state == "corrupt":
        path.write_bytes(b"not a SQLite database containing PRIVATE_CONTENT")
    elif state == "wrong_schema":
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE unrelated (value TEXT)")
    app = app_for(path, api_key="private-provider-key")
    try:
        with TestClient(app) as client:
            response = client.get("/v1/catalog/status", headers=AUTH)
            assert response.status_code == 200 and response.json() == UNAVAILABLE
            assert response.headers["cache-control"] == "no-store"
            assert str(path) not in response.text and "PRIVATE_CONTENT" not in response.text
            assert client.get("/health").json() == {"ready": True}
        if state == "missing":
            assert not path.exists()  # A diagnostic must not create an empty database.
    finally:
        engine = app.state.recommendation_service.engine
        if engine is not None:
            engine.dispose()


def test_empty_imported_schema_and_missing_product_rows_are_not_ready(database):
    _, factory, _ = database
    with TestClient(app_for(factory=factory)) as client:
        assert client.get("/v1/catalog/status", headers=AUTH).json() == UNAVAILABLE
        load(factory, "abo", 1)
        # An audit count alone cannot claim usable products after content loss.
        with factory.begin() as db:
            db.execute(delete(CatalogOffer))
            db.execute(delete(CatalogProduct))
        assert client.get("/v1/catalog/status", headers=AUTH).json() == UNAVAILABLE


def test_download_import_refresh_and_revocation_are_visible_without_restart(tmp_path):
    path = tmp_path / "downloaded-later.db"
    app = app_for(path)
    engine = None
    try:
        with TestClient(app) as client:
            assert client.get("/v1/catalog/status", headers=AUTH).json() == UNAVAILABLE
            engine, factory = make_database("sqlite:///" + str(path))
            Base.metadata.create_all(engine)
            load(factory, "abo", 1)
            assert client.get("/v1/catalog/status", headers=AUTH).json()["catalog_count"] == 1
            load(factory, "abo", 3, version="refreshed")
            assert client.get("/v1/catalog/status", headers=AUTH).json()["catalog_count"] == 3
            revoke_feed(factory, "abo", "local-dataset")
            assert client.get("/v1/catalog/status", headers=AUTH).json() == UNAVAILABLE
    finally:
        if app.state.recommendation_service.engine is not None:
            app.state.recommendation_service.engine.dispose()
        if engine is not None:
            engine.dispose()
