from types import SimpleNamespace

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker

from backend.app.catalog.search_index import drop_index, ensure_index, matching_product_ids


@pytest.fixture
def database(tmp_path):
    engine = create_engine(f"sqlite:///{tmp_path/'search.db'}")
    with engine.begin() as connection:
        connection.exec_driver_sql("CREATE TABLE catalog_products (id TEXT PRIMARY KEY, search_text TEXT NOT NULL)")
        connection.exec_driver_sql("INSERT INTO catalog_products VALUES ('one', 'warm wooden lamps'), ('two', 'metal chair'), ('three', 'wooden armchair')")
    yield engine, sessionmaker(engine)
    engine.dispose()


def matches(factory, query):
    with factory() as db:
        statement = matching_product_ids(db, query)
        return None if statement is None else sorted(db.scalars(statement).all())


def test_absent_index_falls_back_then_rebuild_indexes_existing_rows(database):
    engine, factory = database
    assert matches(factory, "lamp") is None
    with engine.begin() as connection:
        assert ensure_index(connection)
        assert ensure_index(connection)
    assert matches(factory, "wooden lamp") == ["one"]
    assert matches(factory, "chair") == ["two"]  # Token prefix, not an internal substring.


def test_insert_update_delete_and_rollback_keep_index_in_step(database):
    engine, factory = database
    with engine.begin() as connection:
        ensure_index(connection)
        connection.exec_driver_sql("INSERT INTO catalog_products VALUES ('new', 'blue lamp')")
    assert matches(factory, "blue") == ["new"]
    with engine.begin() as connection:
        connection.exec_driver_sql("UPDATE catalog_products SET search_text='red desk' WHERE id='new'")
    assert matches(factory, "blue") == [] and matches(factory, "red") == ["new"]
    with pytest.raises(RuntimeError):
        with engine.begin() as connection:
            connection.exec_driver_sql("DELETE FROM catalog_products WHERE id='new'")
            connection.exec_driver_sql("INSERT INTO catalog_products VALUES ('rolled-back', 'red lamp')")
            raise RuntimeError("cancel replacement")
    assert matches(factory, "red") == ["new"]
    with engine.begin() as connection:
        connection.exec_driver_sql("DELETE FROM catalog_products WHERE id='new'")
    assert matches(factory, "red") == []


@pytest.mark.parametrize("query", ["lamp OR chair", "NEAR", "NOT", "AND"])
def test_fts_keywords_are_quoted_literal_terms(database, query):
    engine, factory = database
    with engine.begin() as connection:
        ensure_index(connection)
    assert matches(factory, query) == []


@pytest.mark.parametrize("query", ['lamp" OR chair', "lamp*", "100%", "x_y", "reader\'s lamp", "読書灯", "café", "Straße", "K", "lamp\nchair", "", "x" * 101])
def test_punctuation_nonascii_and_invalid_queries_use_literal_fallback(database, query):
    engine, factory = database
    with engine.begin() as connection:
        ensure_index(connection)
    assert matches(factory, query) is None


def test_partial_index_install_repairs_missing_triggers_and_rebuilds(database):
    engine, factory = database
    with engine.begin() as connection:
        ensure_index(connection)
        connection.exec_driver_sql("DROP TRIGGER catalog_fts_insert")
        connection.exec_driver_sql("INSERT INTO catalog_products VALUES ('missing', 'brass pendant')")
    assert matches(factory, "brass") == []
    with engine.begin() as connection:
        ensure_index(connection)
    assert matches(factory, "brass") == ["missing"]


def test_drop_restores_fallback_and_keeps_product_data(database):
    engine, factory = database
    with engine.begin() as connection:
        ensure_index(connection)
        drop_index(connection)
        assert connection.scalar(text("SELECT COUNT(*) FROM catalog_products")) == 3
        assert connection.scalar(text("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'catalog_fts%'")) == 0
    assert matches(factory, "lamp") is None


def test_postgresql_is_a_noop():
    connection = SimpleNamespace(dialect=SimpleNamespace(name="postgresql"))
    assert ensure_index(connection) is False
    drop_index(connection)
    assert matching_product_ids(SimpleNamespace(get_bind=lambda: connection), "lamp") is None


def test_service_keeps_sources_and_offer_freshness_scoped_with_fts(tmp_path):
    from backend.app.catalog.service import CatalogError, import_dataset, import_snapshot, revoke_feed, search_feed
    from backend.app.db import Base, make_database
    engine, factory = make_database(f"sqlite:///{tmp_path/'indexed-service.db'}")
    Base.metadata.create_all(engine)
    with engine.begin() as connection:
        ensure_index(connection)

    def row(source, kind="open_dataset"):
        return {"source_id": source, "source_record_id": "same-source-local-id", "data_kind": kind,
                "title": "Wooden lamp", "merchant": {"id": None, "name": None, "platform": source},
                "offer": {"id": "offer-id", "environment": "local"}, "provenance": {}}

    import_dataset(factory, "wands", [row("wands")], version="test", checksum="a" * 64)
    import_dataset(factory, "abo", [row("abo")], version="test", checksum="b" * 64)
    merchant = row("impact", "merchant_feed")
    merchant["merchant"].update(id="seller", name="Source merchant")
    merchant["offer"].update(environment="production", url="https://merchant.example.com/product")
    merchant["provenance"]["catalog_id"] = "feed"
    import_snapshot(factory, "impact", "feed", [merchant], approval_reference="test permission",
                    source_observed_at=100, freshness_seconds=60, now=100)
    with factory() as db:
        results = search_feed(db, "wands", "lamp", now=170)
        assert results["total"] == 1 and results["items"][0]["source_id"] == "wands"
        assert search_feed(db, "impact", "lamp", now=170)["items"] == []
        assert search_feed(db, "impact", "lamp", now=150)["total"] == 1
    revoke_feed(factory, "wands", "local-dataset")
    with factory() as db:
        with pytest.raises(CatalogError):
            search_feed(db, "wands", "lamp")
        assert search_feed(db, "abo", "lamp")["total"] == 1
    engine.dispose()
