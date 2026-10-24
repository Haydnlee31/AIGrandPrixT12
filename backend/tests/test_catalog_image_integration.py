"""Native recommendation routes retain only the exact imported Amazon photos."""
import json

from fastapi.testclient import TestClient

from backend.app.capture_preview import create_app
from backend.app.local_recommendations import LocalRecommendationService
from backend.tests.test_local_recommendations import database, request, find


def test_photo_hook_cannot_replace_amazon_product_images_or_order(database):
    factory, _ = database
    seen = []
    def unrelated(items):
        seen.append(items)
        return [{**item, "image_url": "https://other.example.org/random.jpg"} for item in reversed(items)]
    service = LocalRecommendationService(factory, image_enricher=unrelated)
    first = service.recommendations(request(find(intents=["blue"])))
    result = json.loads(first.body)
    assert not seen
    assert result["items"][0]["source_record_id"] == "blue-watch"
    assert all(item["image_url"].endswith("/ab/abcdef01.jpg") for item in result["items"])
    assert service.recommendations(request(find(intents=["blue"]))).body == first.body


def test_explore_and_radar_share_exact_amazon_record_images_and_links(database):
    factory, _ = database
    app = create_app(api_key="unused-test-key", token="test-photo-access-token", recommendation_factory=factory)
    headers = {"Authorization": "Bearer test-photo-access-token"}
    with TestClient(app) as client:
        explore = client.post("/v1/recommendations", headers=headers, json={"finds": [find()]}).json()
        radar = client.post("/v1/radar", headers=headers, json={"finds": [find()], "intention": "A daily watch"}).json()
    assert explore["items"] and radar["items"]
    for item in explore["items"] + radar["items"]:
        assert item["source_id"] == "abo"
        assert item["image_url"].endswith("/ab/abcdef01.jpg")
        assert item["product_url"].startswith("https://www.amazon.com/dp/")
        assert item["price_minor"] is None and item["availability"] == "unknown"
