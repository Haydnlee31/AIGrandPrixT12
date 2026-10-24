"""Catalog integration checks using invented records and local retrieval."""
import time

import httpx
import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError
from sqlalchemy import event, func, select

from backend.app.catalog.schemas import CatalogRecord
from backend.app.catalog.service import CatalogError, import_snapshot, revoke_feed, search_feed
from backend.app.db import (
    CatalogFeed, CatalogImport, CatalogMerchant, CatalogOffer, CatalogProduct,
    Evidence, Job, SavedItem, Suggestion, UserEvent,
)
from backend.app.main import create_app


def record(source="impact", catalog="invented-feed", sku="invented-sku", title="Invented warm desk lamp"):
    return {
        "source_id": source,
        "source_record_id": sku,
        "title": title,
        "description": None,
        "category": None,
        "brand": None,
        "attributes": {},
        "product_key": None,
        "variant_key": None,
        "merchant": {"id": "invented-merchant", "name": "Invented Merchant", "platform": source},
        "offer": {
            "id": sku,
            "price_minor": None,
            "currency": None,
            "shipping_minor": None,
            "availability": "unknown",
            "condition": None,
            "url": f"https://shop.example.com/items/{sku}",
            "image_url": None,
            "observed_at": 1,
            "expires_at": 2,
            "marketplace_id": None,
            "environment": "production",
        },
        "provenance": {"catalog_id": catalog, "source": "synthetic-test"},
    }


def import_records(factory, records=None, *, source="impact", catalog="invented-feed", observed=None, now=None, freshness=3600):
    now = time.time() if now is None else now
    return import_snapshot(
        factory, source, catalog, records if records is not None else [record(source, catalog)],
        approval_reference="invented-approval-reference", source_observed_at=now if observed is None else observed,
        freshness_seconds=freshness, now=now,
    )


def counts(factory, models=(CatalogFeed, CatalogImport, CatalogMerchant, CatalogProduct, CatalogOffer)):
    with factory() as db:
        return tuple(db.scalar(select(func.count()).select_from(model)) for model in models)


@pytest.fixture
def api(tmp_path):
    app = create_app(f"sqlite:///{tmp_path / 'catalog.db'}", embedded_worker=False,
                     demo_mode=False, tokens={"alex-token": "alex", "sam-token": "sam"})
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer alex-token"
        yield client


def test_snapshot_replay_preserves_expiry_and_search_filters_stale_rows(api):
    factory = api.app.state.factory
    now = time.time()
    first = import_records(factory, now=now, freshness=60)
    replay = import_records(factory, observed=now, now=now + 20, freshness=60)
    assert replay == {**first, "unchanged": True}
    assert counts(factory) == (1, 1, 1, 1, 1)
    with factory() as db:
        assert search_feed(db, "impact", "lamp", now=now + 59)["total"] == 1
        expired = search_feed(db, "impact", "lamp", now=now + 60)
        assert expired["items"] == [] and expired["expires_at"] is None
    with pytest.raises(CatalogError, match="expired") as caught:
        import_records(factory, observed=now, now=now + 60, freshness=60)
    assert caught.value.code == "expired_feed"
    assert counts(factory) == (1, 1, 1, 1, 1)


def test_replacement_removes_old_rows_and_rejects_out_of_order_exports(api):
    factory = api.app.state.factory
    now = time.time()
    import_records(factory, [record(sku="old-one"), record(sku="old-two")], now=now)
    replacement = import_records(factory, [record(sku="new-one", title="New chair")], observed=now + 1, now=now + 1)
    assert replacement["row_count"] == 1 and not replacement["unchanged"]
    assert counts(factory) == (1, 2, 1, 1, 1)
    with factory() as db:
        assert search_feed(db, "impact", "lamp", now=now + 2)["items"] == []
        assert search_feed(db, "impact", "chair", now=now + 2)["items"][0]["source_record_id"] == "new-one"
    with pytest.raises(CatalogError) as caught:
        import_records(factory, observed=now, now=now + 2)
    assert caught.value.code == "older_snapshot"


def test_failure_during_replacement_rolls_back_deleted_rows_and_new_import(api):
    factory = api.app.state.factory
    now = time.time()
    first = import_records(factory, now=now)

    def fail_insert(*_):
        raise RuntimeError("injected database failure")

    event.listen(CatalogOffer, "before_insert", fail_insert)
    try:
        with pytest.raises(RuntimeError, match="injected"):
            import_records(factory, [record(sku="replacement", title="Other product")], now=now + 1)
    finally:
        event.remove(CatalogOffer, "before_insert", fail_insert)
    assert counts(factory) == (1, 1, 1, 1, 1)
    with factory() as db:
        feed = db.scalar(select(CatalogFeed))
        assert feed.last_import_id == first["import_id"]
        assert search_feed(db, "impact", "lamp", now=now + 2)["total"] == 1


@pytest.mark.parametrize("invalid", ["duplicate", "wrong-source", "wrong-catalog", "extra-field"])
def test_invalid_batch_cannot_replace_existing_snapshot(api, invalid):
    factory = api.app.state.factory
    now = time.time()
    import_records(factory, now=now)
    second = record(sku="second")
    if invalid == "duplicate":
        second["source_record_id"] = "invented-sku"
    elif invalid == "wrong-source":
        second["source_id"] = second["merchant"]["platform"] = "cj"
    elif invalid == "wrong-catalog":
        second["provenance"]["catalog_id"] = "another-feed"
    else:
        second["unsupported_fact"] = True
    with pytest.raises((CatalogError, ValidationError)):
        import_records(factory, [record(), second], now=now + 1)
    assert counts(factory) == (1, 1, 1, 1, 1)


def test_revocation_purges_content_and_cannot_be_undone_by_replay(api):
    factory = api.app.state.factory
    now = time.time()
    import_records(factory, now=now)
    revoke_feed(factory, "impact", "invented-feed")
    assert counts(factory) == (1, 1, 0, 0, 0)
    with factory() as db:
        assert not db.scalar(select(CatalogFeed)).enabled
        with pytest.raises(CatalogError) as caught:
            search_feed(db, "impact", "lamp", now=now + 1)
        assert caught.value.code == "catalog_not_configured"
    with pytest.raises(CatalogError) as caught:
        import_records(factory, observed=now, now=now + 1)
    assert caught.value.code == "feed_revoked"
    import_records(factory, observed=now + 2, now=now + 2)
    assert counts(factory) == (1, 2, 1, 1, 1)


def test_ebay_is_never_a_persistable_snapshot_source(api):
    factory = api.app.state.factory
    with pytest.raises(CatalogError) as caught:
        import_records(factory, [record(source="ebay")], source="ebay")
    assert caught.value.code == "source_not_importable"
    assert counts(factory) == (0, 0, 0, 0, 0)


def test_source_specific_search_escapes_wildcards_and_preserves_unknown_facts(api):
    factory = api.app.state.factory
    impact_records = [record(sku="lamp", title="Desk lamp"), record(sku="sale", title="Desk 50%_off lamp")]
    import_records(factory, impact_records)
    import_records(factory, [record(source="cj", title="CJ-only desk lamp")], source="cj")
    response = api.get("/v1/commerce/search", params={"source": "impact", "q": "%_"})
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["source_id"] == "impact" and body["retrieval"] == "approved_feed"
    assert [row["source_record_id"] for row in body["items"]] == ["sale"]
    item = body["items"][0]
    assert item["description"] is None and item["brand"] is None and item["attributes"] == {}
    assert item["product_key"] is None and item["variant_key"] is None
    assert item["offer"]["availability"] == "unknown"
    assert item["offer"]["price_minor"] is None and item["offer"]["shipping_minor"] is None
    assert api.get("/v1/commerce/search", params={"source": "impact", "q": "CJ-only"}).json()["items"] == []
    assert api.get("/v1/commerce/search", params={"source": "impact", "q": "desk absent"}).json()["items"] == []
    page = api.get("/v1/commerce/search", params={"source": "impact", "q": "desk", "limit": 1}).json()
    second = api.get("/v1/commerce/search", params={"source": "impact", "q": "desk", "limit": 1, "offset": page["next_offset"]}).json()
    assert page["total"] == 2 and second["next_offset"] is None
    assert page["items"][0]["source_record_id"] != second["items"][0]["source_record_id"]


@pytest.mark.parametrize("source, code", [("impact", "catalog_not_configured"), ("cj", "catalog_not_configured"), ("abo", "catalog_not_configured")])
def test_missing_sources_fail_explicitly_without_fixture_fallback_or_retry(api, source, code):
    response = api.get("/v1/commerce/search", params={"source": source, "q": "lamp"})
    assert response.status_code == 503
    assert response.json()["error"]["code"] == code
    assert response.json()["error"]["retryable"] is False
    assert "items" not in response.json()
    status = api.get("/v1/commerce/sources").json()["items"]
    assert all(not item["configured"] and item["allowed_uses"] == [] for item in status)
    assert all(item["ai_use"] == "disabled" for item in status)


@pytest.mark.parametrize("params", [
    {"q": "lamp"}, {"source": "amazon", "q": "lamp"}, {"source": "impact", "q": " "},
    {"source": "impact", "q": "lamp\n"}, {"source": "impact", "q": "lamp", "limit": 0},
    {"source": "impact", "q": "lamp", "offset": -1},
    {"source": "impact", "q": "lamp", "delivery_country": "SG"},
])
def test_invalid_or_unestablished_search_constraints_fail_without_fallback(api, params):
    response = api.get("/v1/commerce/search", params=params)
    assert response.status_code == 422
    assert response.json()["error"]["retryable"] is False


def test_catalog_access_is_authenticated_and_does_not_import_or_expose_library_context(api):
    factory = api.app.state.factory
    import_records(factory)
    saved = api.post("/v1/saves", json={"url": "https://example.com/private", "title": "Private library secret", "selected_text": "Private selected context"}, headers={"Idempotency-Key": "capture"})
    assert saved.status_code == 201
    before = counts(factory, (SavedItem, Job, Suggestion, UserEvent, Evidence))
    for path in ("/v1/commerce/sources", "/v1/commerce/search?source=impact&q=lamp", "/v1/commerce/items/impact/invented-sku"):
        assert api.get(path, headers={"Authorization": "Bearer invalid"}).status_code == 401
    for token in ("alex-token", "sam-token"):
        response = api.get("/v1/commerce/search", params={"source": "impact", "q": "lamp"}, headers={"Authorization": f"Bearer {token}"})
        assert response.status_code == 200
        assert "Private" not in response.text and "alex" not in response.text
        response = api.get("/v1/commerce/search", params={"source": "impact", "q": "Private"}, headers={"Authorization": f"Bearer {token}"})
        assert response.json()["items"] == []
    assert counts(factory, (SavedItem, Job, Suggestion, UserEvent, Evidence)) == before




@pytest.mark.parametrize("location", ["record", "merchant", "offer"])
def test_unknown_normalized_fields_are_rejected(location):
    row = record()
    target = row if location == "record" else row[location]
    target["invented_fact"] = "must not be accepted"
    with pytest.raises(ValidationError):
        CatalogRecord.model_validate(row)


@pytest.mark.parametrize("url", ["https://127.1/item", "https://0x7f.0.0.1/item", "https://0177.0.0.1/item"])
def test_obfuscated_loopback_merchant_links_are_rejected(url):
    row = record()
    row["offer"]["url"] = url
    with pytest.raises(ValidationError):
        CatalogRecord.model_validate(row)


def test_boolean_is_not_a_monetary_amount():
    row = record()
    row["offer"].update(price_minor=True, currency="USD")
    with pytest.raises(ValidationError):
        CatalogRecord.model_validate(row)
