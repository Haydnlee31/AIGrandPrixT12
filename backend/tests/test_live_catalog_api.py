"""Live-provider failure isolation and source-aware public API contracts."""
import pytest
from fastapi.testclient import TestClient

from backend.app.catalog.service import CatalogError, import_dataset
from backend.app.main import create_app


class FakeRakuten:
    def __init__(self):
        self.calls = []
        self.closed = False
        self.error = None

    def status(self):
        return {
            "source_id": "rakuten", "configured": False, "enabled_feeds": 0,
            "fresh_records": None, "record_count": 0, "data_kind": "merchant_api",
            "name": "Rakuten Ichiba", "environment": "production", "marketplace": "JP",
            "retrieval": "live_api", "allowed_uses": [], "ai_use": "disabled", "persistence": "none",
        }

    def search(self, query, **kwargs):
        self.calls.append(("search", query, kwargs))
        if self.error:
            raise self.error
        return {"items": [], "source_id": "rakuten", "total": 0, "next_offset": None,
                "fetched_at": 1.0, "expires_at": None, "environment": "production",
                "marketplace": "JP", "retrieval": "live_api"}

    def get_item(self, record_id):
        self.calls.append(("item", record_id))
        raise self.error or CatalogError("catalog_record_not_found", "Item is no longer available")

    def close(self):
        self.closed = True


@pytest.fixture
def api(tmp_path):
    provider = FakeRakuten()
    app = create_app(f"sqlite:///{tmp_path / 'catalog.db'}", embedded_worker=False,
                     demo_mode=False, tokens={"test-token": "alex"}, rakuten_client=provider)
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer test-token"
        import_dataset(app.state.factory, "abo", [{
            "source_id": "abo", "source_record_id": "test-watch", "data_kind": "open_dataset",
            "title": "Test analog watch", "merchant": {"platform": "abo"},
            "offer": {"id": "test-watch", "environment": "local"},
        }], version="test", checksum="0" * 64)
        yield client, provider
    assert provider.closed


def test_live_source_is_discoverable_without_credentials_or_network(api):
    client, provider = api
    response = client.get("/v1/commerce/sources")
    assert response.status_code == 200
    item = next(row for row in response.json()["items"] if row["source_id"] == "rakuten")
    assert not item["configured"] and item["record_count"] == 0
    assert item["retrieval"] == "live_api" and item["persistence"] == "none"
    assert provider.calls == []
    assert response.headers["Cache-Control"] == "no-store"


def test_live_search_dispatch_and_item_error_preserve_generic_client_contract(api):
    client, provider = api
    response = client.get("/v1/commerce/search", params={"source": "rakuten", "q": "watch", "delivery_country": "SG"})
    assert response.status_code == 200 and response.json()["retrieval"] == "live_api"
    assert provider.calls == [("search", "watch", {"limit": 20, "offset": 0, "delivery_country": "SG"})]
    detail = client.get("/v1/commerce/items/rakuten/shop:123")
    assert detail.status_code == 404
    assert detail.json()["error"]["code"] == "catalog_record_not_found"
    assert not detail.json()["error"]["retryable"]


@pytest.mark.parametrize("code,status,retryable", [
    ("rakuten_credentials_missing", 503, False),
    ("rakuten_authentication_failed", 503, False),
    ("rakuten_invalid_response", 503, False),
    ("rakuten_rate_limited", 429, True),
    ("rakuten_unavailable", 503, True),
    ("invalid_catalog_pagination", 422, False),
])
def test_live_errors_are_classified_without_breaking_local_sources(api, code, status, retryable):
    client, provider = api
    provider.error = CatalogError(code, "Safe provider message")
    result = client.get("/v1/commerce/search?source=rakuten&q=watch")
    assert result.status_code == status
    error = result.json()["error"]
    assert error["code"] == code and error["retryable"] is retryable
    assert error["request_id"] == result.headers["X-Request-ID"]
    # A provider outage does not affect local catalog configuration or retrieval.
    local = client.get("/v1/commerce/search?source=abo&q=watch")
    assert local.status_code == 200
    assert local.json()["items"][0]["source_record_id"] == "test-watch"
    assert client.get("/v1/commerce/sources").status_code == 200


def test_live_content_cannot_be_exported_or_used_as_local_explore(api):
    client, provider = api
    response = client.get("/v1/commerce/datasets/rakuten/export")
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "source_not_exportable"
    assert client.get("/v1/explore?source=rakuten&q=watch").status_code == 422
    assert provider.calls == []


def test_api_authentication_precedes_provider_calls(api):
    client, provider = api
    client.headers.pop("Authorization")
    for path in ("/v1/commerce/search?source=rakuten&q=watch", "/v1/commerce/items/rakuten/shop:123", "/v1/commerce/sources"):
        assert client.get(path).status_code == 401
    assert provider.calls == []
