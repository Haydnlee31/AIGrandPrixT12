"""Local catalog behavior, separate from private Library and fabricated offers."""
from copy import deepcopy
import hashlib
import json

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError
from sqlalchemy import func, select

from backend.app.catalog.schemas import CatalogRecord
from backend.app.catalog.service import CatalogError, import_dataset, revoke_feed
from backend.app.catalog.synthetic import iter_synthetic
from backend.app.db import CatalogImport, CatalogMerchant, CatalogProduct, SavedItem
from backend.app.main import create_app


@pytest.fixture
def api(tmp_path):
    app = create_app(f"sqlite:///{tmp_path/'catalog.db'}", embedded_worker=False,
                     tokens={"catalog-user": "alice"}, demo_mode=False)
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer catalog-user"
        yield client


def real_record(source="wands", record_id="17", title="Reading lamp"):
    row = next(iter_synthetic(1))
    row.update(source_id=source, source_record_id=record_id, data_kind="open_dataset", title=title)
    row["merchant"] = {"id": None, "name": None, "platform": source}
    row["offer"].update(id=record_id, price_minor=None, currency=None, shipping_minor=None, availability="unknown")
    row["provenance"] = {"original_product_id": record_id}
    return row


def ingest(api, rows, source="wands", checksum="a"*64, version="test-v1"):
    return import_dataset(api.app.state.factory, source, rows, version=version, checksum=checksum)


def count(api, model):
    with api.app.state.factory() as db:
        return db.scalar(select(func.count()).select_from(model))


def test_historical_metadata_search_detail_and_export_preserve_unknowns_and_license(api):
    ingest(api, [real_record()])
    response = api.get("/v1/commerce/search", params={"source": "wands", "q": "reading lamp"})
    assert response.status_code == 200, response.text
    page = response.json()
    assert page["retrieval"] == "local_dataset" and page["environment"] == "local" and page["expires_at"] is None
    row = page["items"][0]
    assert row["data_kind"] == "open_dataset"
    assert row["merchant"]["id"] is None and row["merchant"]["name"] is None
    assert row["offer"]["price_minor"] is None and row["offer"]["url"] is None and row["offer"]["observed_at"] is None
    assert row["provenance"]["is_current_offer"] is False and row["provenance"]["license_id"] == "MIT"
    assert count(api, CatalogMerchant) == 0
    assert api.get("/v1/commerce/items/wands/17").json() == row
    export = api.get("/v1/commerce/datasets/wands/export")
    assert export.status_code == 200 and export.headers["cache-control"] == "no-store"
    assert 'rel="license"' in export.headers["link"]
    assert json.loads(export.text) == row


def test_registry_exposes_only_configured_local_sources_and_removes_ebay(api):
    ingest(api, [real_record()])
    sources = {row["source_id"]: row for row in api.get("/v1/commerce/sources").json()["items"]}
    assert "ebay" not in sources
    assert sources["wands"]["record_count"] == 1 and sources["wands"]["fresh_records"] is None
    assert sources["wands"]["license_id"] == "MIT" and not sources["abo"]["configured"]
    assert api.get("/v1/commerce/search", params={"source": "ebay", "q": "lamp"}).status_code == 422
    assert api.get("/v1/commerce/ebay/items/v1%7C1%7C0").status_code == 404


def test_local_dataset_replay_replacement_and_revocation(api):
    first = ingest(api, [real_record()])
    assert ingest(api, [real_record()]) == {**first, "unchanged": True}
    assert count(api, CatalogImport) == 1
    ingest(api, [real_record(record_id="18", title="Blue chair")], checksum="b"*64)
    assert count(api, CatalogProduct) == 1
    assert api.get("/v1/commerce/items/wands/17").status_code == 404
    revoke_feed(api.app.state.factory, "wands", "local-dataset")
    assert api.get("/v1/commerce/items/wands/18").status_code == 404
    assert api.get("/v1/commerce/datasets/wands/export").status_code == 503
    with pytest.raises(CatalogError, match="reactivate"):
        ingest(api, [real_record(record_id="18")], checksum="b"*64)
    assert count(api, CatalogProduct) == 0


def test_failure_after_a_bulk_flush_rolls_back_all_replacement_content(api):
    ingest(api, [real_record()])
    def bad_rows():
        for index in range(1001):
            yield real_record(record_id=str(index))
        bad = real_record(record_id="invalid")
        bad["offer"]["price_minor"] = True
        yield bad
    with pytest.raises(ValidationError):
        ingest(api, bad_rows(), checksum="b"*64)
    assert count(api, CatalogProduct) == 1 and count(api, CatalogImport) == 1
    assert api.get("/v1/commerce/items/wands/17").status_code == 200


@pytest.mark.parametrize("mutate", [
    lambda row: row["offer"].update(price_minor=100, currency="USD"),
    lambda row: row["merchant"].update(id="invented", name="Invented merchant"),
    lambda row: row["offer"].update(availability="in_stock"),
    lambda row: row["offer"].update(url="https://example.com/buy"),
    lambda row: row["offer"].update(observed_at=1),
])
def test_real_dataset_cannot_gain_fabricated_live_offer_facts(api, mutate):
    row = real_record()
    mutate(row)
    with pytest.raises(CatalogError):
        ingest(api, [row])
    assert count(api, CatalogProduct) == 0


def test_source_isolation_and_private_library_are_preserved(api):
    ingest(api, [real_record()])
    ingest(api, [real_record("abo", "17", "Wooden table")], source="abo")
    api.post("/v1/saves", json={"url": "https://example.com/private", "title": "Private lamp note"}, headers={"Idempotency-Key": "save"})
    assert count(api, SavedItem) == 1
    assert api.get("/v1/commerce/items/abo/17").json()["title"] == "Wooden table"
    exported = api.get("/v1/commerce/datasets/wands/export").text
    assert "Wooden table" not in exported and "Private" not in exported
    assert api.get("/v1/commerce/datasets/wands/export", headers={"Authorization": ""}).status_code == 401
    assert api.get("/v1/commerce/datasets/impact/export").status_code == 422


def test_generated_products_are_reproducible_and_separate_from_real_sources(api):
    one, two = list(iter_synthetic(101, 42)), list(iter_synthetic(101, 42))
    assert one == two
    assert len({item["source_record_id"] for item in one}) == 101
    assert {item["offer"]["currency"] for item in one} == {"SGD", "USD", "EUR"}
    for item in one:
        CatalogRecord.model_validate(item)
        assert item["data_kind"] == "synthetic" and item["provenance"]["merchant_is_fictional"]
        assert item["offer"]["url"] is None and item["offer"]["image_url"] is None
    ingest(api, one, source="synthetic")
    source = next(row for row in api.get("/v1/commerce/sources").json()["items"] if row["source_id"] == "synthetic")
    assert source["record_count"] == 101 and source["data_kind"] == "synthetic"
    assert count(api, CatalogMerchant) == 24


def test_added_license_metadata_is_validated_before_commit(api):
    row = real_record()
    row["provenance"] = {"large": "x" * 31950}
    # Input alone fits; the admission layer must also validate after appending
    # its mandatory source license/version metadata.
    CatalogRecord.model_validate(row)
    with pytest.raises(ValidationError):
        ingest(api, [row])
    assert count(api, CatalogProduct) == 0


def test_portable_normalized_gzip_can_be_loaded_without_network(api, tmp_path):
    import gzip
    from backend.app.catalog.datasets import load_source
    source = tmp_path / "reviewed.jsonl.gz"
    with gzip.open(source, "wt", encoding="utf-8") as handle:
        handle.write(json.dumps(real_record()) + "\n")
    result = load_source(api.app.state.factory, "wands", source, normalized=True, version="portable-v1")
    assert result["row_count"] == 1
    item = api.get("/v1/commerce/items/wands/17").json()
    assert item["provenance"]["dataset_version"] == "portable-v1"
    assert item["provenance"]["license_id"] == "MIT"


def test_api_uses_indexed_candidates_without_crossing_source_or_revocation(api):
    from backend.app.catalog.search_index import ensure_index
    engine = api.app.state.factory.kw["bind"]
    with engine.begin() as connection:
        ensure_index(connection)
    ingest(api, [real_record(title="Reading lamps")])
    ingest(api, [real_record("abo", title="Different lamp")], source="abo")
    response = api.get("/v1/commerce/search", params={"source": "wands", "q": "read lamp"})
    assert response.status_code == 200, response.text
    assert response.json()["total"] == 1 and response.json()["items"][0]["title"] == "Reading lamps"
    revoke_feed(api.app.state.factory, "wands", "local-dataset")
    assert api.get("/v1/commerce/items/wands/17").status_code == 404
    assert api.get("/v1/commerce/search", params={"source": "abo", "q": "lamp"}).json()["total"] == 1
