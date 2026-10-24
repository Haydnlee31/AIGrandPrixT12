"""Intent retrieval against isolated real-shape catalog fixtures; provider mocked."""
import json

import httpx
import pytest
from fastapi.testclient import TestClient

from backend.app.capture_preview import create_app, MAX_BODY_BYTES
from backend.app.catalog.recommendation_index import ensure_recommendation_index
from backend.app.catalog.search_index import ensure_index
from backend.app.catalog.service import import_dataset
from backend.app.db import Base, make_database
from backend.tests.test_local_recommendations import record, find

TOKEN = "radar-test-private-access-token"
AUTH = {"Authorization": "Bearer " + TOKEN}


@pytest.fixture
def factory(tmp_path):
    engine, factory = make_database("sqlite:///" + str(tmp_path / "radar.db"))
    Base.metadata.create_all(engine)
    with engine.begin() as connection:
        ensure_index(connection)
        ensure_recommendation_index(connection)
    import_dataset(factory, "abo", [
        record("black-watch", "Black retro digital watch", "Watches", brand="Casio"),
        record("blue-watch", "Blue digital watch", "Watches", brand="Casio"),
        record("lamp", "Small desk lamp", "Lamps"),
        record("phone", "Samsung Galaxy smartphone", "Smartphones", offer={"id": "phone", "environment": "local", "image_url": None}),
        record("landline", "AmazonBasics DECT Home Telephone Set 3", "PHONE"),
        record("phone-case", "Smartphone case", "Phone cases"),
    ], version="radar-fixture", checksum="8" * 64)
    yield factory
    engine.dispose()


def interpretation(**changes):
    return {"product_name": "Digital watch", "category_path": ["Accessories", "Watches", "Digital watches"],
            "brand": None, "preferences": ["Black", "Retro", "Digital"], **changes}


def envelope(value=None):
    return {"status": "completed", "output": [{"type": "message", "role": "assistant", "status": "completed",
        "content": [{"type": "output_text", "text": json.dumps(value if value is not None else interpretation())}]}]}


def application(factory, handler=None, **kwargs):
    return create_app(api_key="test-radar-provider-secret", token=TOKEN,
        transport=httpx.MockTransport(handler or (lambda _: httpx.Response(200, json=envelope()))),
        recommendation_factory=factory, **kwargs)


def post(client, **changes):
    return client.post("/v1/radar", headers=AUTH, json={
        "intention": "I want a small black retro watch for everyday wear", "finds": [], "limit": 12, **changes})


def test_auth_precedes_parsing_and_limits_never_echo_private_input(factory):
    called = []
    with TestClient(application(factory, lambda r: called.append(r))) as client:
        assert client.post("/v1/radar", content=b"not json").status_code == 401
        assert client.post("/v1/radar", content=b"x" * (MAX_BODY_BYTES + 1), headers=AUTH).status_code == 413
        response = post(client, preferences=["private-value" * 100])
        assert response.status_code == 422
        assert "private-value" not in response.text and not called
        assert TOKEN not in response.text and "test-radar-provider-secret" not in response.text


def test_typed_need_without_saved_examples_returns_sourced_images(factory):
    calls = []
    def handler(request):
        body = json.loads(request.content)
        calls.append(body)
        assert body["store"] is False and body["text"]["format"]["strict"] is True
        assert body["text"]["format"]["name"] == "mynah_radar_intent"
        assert "untrusted data" in body["instructions"]
        context = json.loads(body["input"][0]["content"][0]["text"])
        assert context["selected_examples"] == []
        return httpx.Response(200, json=envelope())
    with TestClient(application(factory, handler)) as client:
        response = post(client)
        assert response.status_code == 200
        result = response.json()
        assert result["status"] == "ready"
        assert result["items"][0]["source_record_id"] == "black-watch"
        assert {item["source_record_id"] for item in result["items"]} == {"black-watch"}
        assert all(item["image_url"] and item["source_url"] and item["license_url"] for item in result["items"])
        assert all(item["price_minor"] is None and item["product_url"].startswith("https://www.amazon.com/dp/") for item in result["items"])
        assert all(reason["find_id"] == "radar-request" and reason["find_title"] == "Your request"
                   for item in result["items"] for reason in item["reasons"])
        assert "saved find" not in response.text
        assert post(client).json() == result and len(calls) == 1


def test_selected_source_category_wins_and_conversational_query_is_not_an_and_filter(factory):
    calls = []
    with TestClient(application(factory, lambda r: calls.append(r))) as client:
        response = post(client, intention="I love the compact retro dial for everyday wear",
            query="something small and black for daily wear", finds=[find("selected-watch")])
        assert response.status_code == 200 and not calls
        items = response.json()["items"]
        assert {item["source_record_id"] for item in items} == {"black-watch"}
        assert items[0]["source_record_id"] == "black-watch"
        assert all(reason["find_id"] == "selected-watch" for item in items for reason in item["reasons"])


def test_selected_unanalyzed_source_is_used_instead_of_other_library_items(factory):
    seen = []
    def handler(request):
        context = json.loads(json.loads(request.content)["input"][0]["content"][0]["text"])
        seen.extend(context["selected_examples"])
        return httpx.Response(200, json=envelope(interpretation(product_name="Desk lamp", category_path=["Lamps"], preferences=["Small"])))
    with TestClient(application(factory, handler)) as client:
        raw = {"id": "selected-lamp", "title": "A desk lamp", "note": "For reading", "text": "", "intents": []}
        result = post(client, intention="More like this for a small desk", finds=[raw]).json()
        assert [item["source_record_id"] for item in result["items"]] == ["lamp"]
        assert len(seen) == 1 and seen[0]["title"] == "A desk lamp"
        assert result["items"][0]["reasons"][0]["find_id"] == "selected-lamp"


def test_category_tracking_uses_edited_target_without_falsely_citing_old_save(factory):
    seen = []
    def handler(request):
        context = json.loads(json.loads(request.content)["input"][0]["content"][0]["text"])
        seen.append(context)
        return httpx.Response(200, json=envelope(interpretation(product_name="Desk lamp",
            category_path=["Home", "Lighting", "Desk lamps"], preferences=["Small"])))
    with TestClient(application(factory, handler)) as client:
        result = post(client, intention="I like this watch dial", finds=[find("old-watch")],
            scope="category", target="Desk lamps", preferences=["Small"]).json()
        assert [item["source_record_id"] for item in result["items"]] == ["lamp"]
        assert seen[0]["intention"] == "Desk lamps" and seen[0]["target"] == "Desk lamps"
        assert seen[0]["selected_examples"] == []
        assert all(reason["find_id"] == "radar-request" and reason["find_title"] == "Your request"
                   for item in result["items"] for reason in item["reasons"])
        assert "old-watch" not in json.dumps(result) and "saved find" not in json.dumps(result)


def test_smartphone_need_never_fills_missing_photos_with_telephones(factory):
    response = envelope(interpretation(product_name="Smartphone", category_path=["Electronics", "Smartphones"], preferences=[]))
    with TestClient(application(factory, lambda _: httpx.Response(200, json=response))) as client:
        result = post(client, intention="I need a mobile phone for everyday use").json()
        assert result["status"] == "no_matches" and not result["items"]


def test_unclear_or_nonshopping_request_never_returns_filler_products(factory):
    response = envelope(interpretation(product_name=None, category_path=[], preferences=[]))
    with TestClient(application(factory, lambda _: httpx.Response(200, json=response))) as client:
        result = post(client, intention="Explain politics").json()
        assert result["status"] == "needs_clarification" and not result["items"]


@pytest.mark.parametrize("status", [401, 429, 503])
def test_provider_failures_do_not_fabricate_matches_or_echo_secrets(factory, status):
    with TestClient(application(factory, lambda _: httpx.Response(status, text="private-upstream-value"))) as client:
        response = post(client)
        assert response.status_code >= 400
        assert "items" not in response.json()
        assert "private-upstream-value" not in response.text and "test-radar-provider-secret" not in response.text


def test_invented_brand_rejected_and_model_refusal_is_safe(factory):
    with TestClient(application(factory, lambda _: httpx.Response(200, json=envelope(interpretation(brand="InventedBrand"))))) as client:
        assert post(client).json()["error"]["code"] == "ungrounded_intent"
    refusal = {"status": "completed", "output": [{"type": "message", "role": "assistant", "status": "completed",
        "content": [{"type": "refusal", "refusal": "private-refusal"}]}]}
    with TestClient(application(factory, lambda _: httpx.Response(200, json=refusal))) as client:
        response = post(client)
        assert response.status_code == 422 and "private-refusal" not in response.text


def test_interpretation_rate_limit_is_shared_across_distinct_uncached_needs(factory):
    with TestClient(application(factory, rate_limit=1)) as client:
        assert post(client).status_code == 200
        assert post(client, intention="A different watch need").status_code == 429


def test_budget_is_context_not_an_invented_live_price_filter(factory):
    seen = []
    def handler(request):
        body = json.loads(request.content)
        seen.append(json.loads(body["input"][0]["content"][0]["text"]))
        assert "no verified current prices" in body["instructions"]
        return httpx.Response(200, json=envelope())
    with TestClient(application(factory, handler)) as client:
        response = post(client, budget=250, currency="SGD")
        assert response.status_code == 200 and response.json()["items"]
        assert seen[0]["budget"] == 250 and seen[0]["currency"] == "SGD"
        assert all(item["price_minor"] is None and item["currency"] is None for item in response.json()["items"])
        assert post(client, budget=-1).status_code == 422
        assert post(client, currency="INVALID").status_code == 422
