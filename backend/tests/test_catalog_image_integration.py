"""Both native recommendation routes use the same bounded photo enrichment hook."""
import json

from fastapi.testclient import TestClient

from backend.app.capture_preview import create_app
from backend.app.local_recommendations import LocalRecommendationService
from backend.tests.test_local_recommendations import database, request, find


def test_photo_enrichment_preserves_qualified_results_and_caches(database):
    factory, _ = database
    seen = []
    def enrich(items):
        seen.append(items)
        return [{**item, "image_url": "https://catalog.example.org/exact-record.jpg",
                 "attribution": item["attribution"] + " Verified image source.",
                 "title": "Must not override product identity", "price_minor": 123} for item in items]
    service = LocalRecommendationService(factory, image_enricher=enrich)
    first = service.recommendations(request(find()))
    result = json.loads(first.body)
    assert len(seen) == 1
    assert {item["source_record_id"] for item in result["items"]} == {"black-watch", "blue-watch", "silver-watch"}
    assert all(item["image_url"].endswith("exact-record.jpg") and "Verified image source." in item["attribution"]
               for item in result["items"])
    assert all(item["title"] != "Must not override product identity" and item["price_minor"] is None for item in result["items"])
    assert all(reason["find_id"] == "saved-watch" for item in result["items"] for reason in item["reasons"])
    assert service.recommendations(request(find())).body == first.body and len(seen) == 1


def test_photo_source_failure_keeps_original_matches(database):
    factory, _ = database
    def unavailable(_):
        raise TimeoutError("public source unavailable")
    service = LocalRecommendationService(factory, image_enricher=unavailable)
    result = json.loads(service.recommendations(request(find())).body)
    assert result["status"] == "ready" and len(result["items"]) == 3
    assert all(item["image_url"] == "https://catalog.example.org/photo.jpg" for item in result["items"])


def test_explore_and_radar_share_photo_enrichment(database):
    factory, _ = database
    calls = []
    def enrich(items):
        calls.append(1)
        return [{**item, "image_url": "https://catalog.example.org/exact-record.jpg"} for item in items]
    app = create_app(api_key="unused-test-key", token="test-photo-access-token", recommendation_factory=factory)
    app.state.recommendation_service.image_enricher = enrich
    headers = {"Authorization": "Bearer test-photo-access-token"}
    with TestClient(app) as client:
        explore = client.post("/v1/recommendations", headers=headers, json={"finds": [find()]}).json()
        radar = client.post("/v1/radar", headers=headers, json={"finds": [find()], "intention": "A daily watch"}).json()
    assert len(calls) == 2
    assert explore["items"] and radar["items"]
    assert all(item["image_url"].endswith("exact-record.jpg") for item in explore["items"] + radar["items"])
