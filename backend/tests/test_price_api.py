from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from backend.app.capture_preview import create_app
from backend.tests.test_price_tracking import Checker, observation, URL


@pytest.fixture
def app(tmp_path):
    return create_app(api_key="isolated-provider-fixture", token="isolated-price-fixture", price_checker=Checker(observation()),
                      price_store=tmp_path / "prices.db", price_background=False)


@pytest.mark.parametrize("path", ["/v1/price-check", "/v1/price-watch"])
def test_price_routes_authenticate_before_parsing_or_fetching(app, path):
    with TestClient(app) as client:
        assert client.post(path, content="not json").status_code == 401
        assert client.post(path, content="x" * 9000).status_code == 401
        oversized = client.post(path, content="x" * 9000, headers={"Authorization": "Bearer isolated-price-fixture"})
        assert oversized.status_code == 413
        invalid = client.post(path, json={"private_note": "must not appear"}, headers={"Authorization": "Bearer isolated-price-fixture"})
        assert invalid.status_code == 422 and "must not appear" not in invalid.text
        assert not app.state.price_tracking_service.path.exists()


def test_live_price_routes_preserve_discount_basis_no_cache_and_owner_scope(app):
    headers = {"Authorization": "Bearer isolated-price-fixture"}
    with TestClient(app) as client:
        result = client.post("/v1/price-check", json={"product_url": URL}, headers=headers)
        assert result.status_code == 200 and result.headers["cache-control"] == "no-store"
        assert result.json()["discount_percent"] == 61 and result.json()["reference_label"] == "MRP"
        owner = str(uuid4())
        saved = client.post("/v1/price-watch", json={"action": "save", "owner_id": owner, "product_url": URL,
            "title": "Exact watch", "target_minor": 640000, "currency": "INR"}, headers=headers)
        assert saved.status_code == 200 and saved.headers["cache-control"] == "no-store"
        watch = saved.json()["watches"][0]
        assert watch["target_reached"] is True and len(watch["history"]) == 1
        assert client.post("/v1/price-watch", json={"action": "list", "owner_id": str(uuid4())}, headers=headers).json() == {"watches": []}
        assert client.post("/v1/price-watch", json={"action": "delete", "owner_id": owner, "watch_id": watch["id"]}, headers=headers).json() == {"watches": []}
