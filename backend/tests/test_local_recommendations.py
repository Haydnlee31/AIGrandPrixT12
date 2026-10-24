"""Actual retrieval against isolated catalogs; no paid provider calls."""
from copy import deepcopy

from fastapi.testclient import TestClient
import pytest

from backend.app.catalog.search_index import ensure_index
from backend.app.catalog.recommendation_index import ensure_recommendation_index
from backend.app.catalog.service import import_dataset, revoke_feed
from backend.app.db import Base, SavedItem, make_database
from backend.app.local_recommendations import RecommendationRequest, LocalRecommendationService, recommend
from sqlalchemy import func, select


def record(identity, title, category, **changes):
    row = {"source_id": "abo", "source_record_id": identity, "data_kind": "open_dataset",
           "title": title, "description": title, "category": category, "brand": None,
           "attributes": {}, "merchant": {"id": None, "name": None, "platform": "abo"},
           "offer": {"id": identity, "environment": "local", "image_url": "https://catalog.example.org/photo.jpg"},
           "provenance": {"source_url": "https://catalog.example.org/items/" + identity}}
    row.update(changes)
    return row


@pytest.fixture
def database(tmp_path):
    path = tmp_path / "recommendations.db"
    engine, factory = make_database("sqlite:///" + str(path))
    Base.metadata.create_all(engine)
    with engine.begin() as connection:
        ensure_index(connection)
        ensure_recommendation_index(connection)
    import_dataset(factory, "abo", [
        record("black-watch", "Black digital wristwatch", "Watches", brand="Casio"),
        record("blue-watch", "Blue digital wristwatch", "Watches", brand="Casio"),
        record("silver-watch", "Silver analog wristwatch", "Watches", brand="Other"),
        record("watch-box", "Digital watch storage box", "Watch boxes"),
        record("chair", "Blue upholstered chair", "Furniture > Chairs"),
        record("lamp", "Black desk lamp", "Home > Lighting > Lamps"),
        record("wrong-home", "Watch the sunset with this black pillow", "HOME"),
        record("wrong-strap", "SHENGHUO Watch Band Strap", "HOME"),
        record("phone-stand", "Smartphone stand holder for iPhone", "PHONE"),
    ], version="test", checksum="b" * 64)
    yield factory, path
    engine.dispose()


def find(identity="saved-watch", noun="watch", intents=None):
    return {"id": identity, "title": "My " + noun, "note": "", "text": "", "intents": intents or [],
            "analysis": {"product_name": "Digital wristwatch" if noun == "watch" else noun,
                         "category_path": ["Accessories", "Watches", "Digital watches"] if noun == "watch" else [noun],
                         "brand": "Casio" if noun == "watch" else None,
                         "style": ["Digital"] if noun == "watch" else [], "summary": "A saved " + noun}}


def request(*finds, query="", limit=24):
    return RecommendationRequest(finds=list(finds), query=query, limit=limit)


def test_matches_actual_watch_saves_not_furniture_or_accessories(database):
    factory, _ = database
    result = recommend(factory, request(find()), now=123)
    assert result.status == "ready" and result.catalog_count == 9
    assert {item.source_record_id for item in result.items} == {"black-watch", "blue-watch", "silver-watch"}
    assert result.generated_at == 123
    assert all(reason.find_id == "saved-watch" for item in result.items for reason in item.reasons)
    assert all(item.source_url.endswith(item.source_record_id) for item in result.items)
    assert all(item.product_url is None and item.price_minor is None and item.currency is None and item.availability == "unknown" for item in result.items)
    assert all(item.attribution and item.license_url and item.image_url for item in result.items)
    with factory() as db:
        assert db.scalar(select(func.count()).select_from(SavedItem)) == 0


def test_adding_editing_and_multiple_intents_changes_current_ranking(database):
    factory, _ = database
    black = recommend(factory, request(find(intents=["I like black", "I prefer digital"])))
    blue = recommend(factory, request(find(intents=["I like blue", "I prefer digital"])))
    assert black.items[0].source_record_id == "black-watch"
    assert blue.items[0].source_record_id == "blue-watch"
    assert any(reason.matched_value == "blue" for reason in blue.items[0].reasons)
    assert not any(reason.matched_value == "black" for reason in blue.items[0].reasons)


def test_explicit_negative_preference_excludes_products(database):
    factory, _ = database
    result = recommend(factory, request(find(intents=["no black", "digital"])))
    assert "black-watch" not in {item.source_record_id for item in result.items}
    assert result.items[0].source_record_id == "blue-watch"


def test_phone_does_not_recommend_cases_or_stands_as_the_phone(database):
    factory, _ = database
    result = recommend(factory, request(find("phone", "phone")))
    assert result.status == "no_matches" and not result.items


def test_changing_or_removing_find_changes_sources_without_a_cache(database):
    factory, _ = database
    watch = recommend(factory, request(find()))
    lamp = recommend(factory, request(find("my-lamp", "lamp")))
    assert watch.items and {item.source_record_id for item in lamp.items} == {"lamp"}
    assert all(reason.find_id == "my-lamp" for item in lamp.items for reason in item.reasons)
    assert recommend(factory, request()).status == "needs_saves"
    assert not recommend(factory, request()).items


def test_different_actual_saves_are_represented_in_a_short_result_page(database):
    factory, _ = database
    result = recommend(factory, request(find(), find("my-lamp", "lamp"), limit=2))
    assert {item.reasons[0].find_id for item in result.items} == {"saved-watch", "my-lamp"}


def test_search_filters_personalized_catalog_results(database):
    factory, _ = database
    assert [item.source_record_id for item in recommend(factory, request(find(), query="blue")).items] == ["blue-watch"]
    assert recommend(factory, request(find(), query="lamp")).status == "no_matches"
    assert recommend(factory, request(find(), limit=1)).items.__len__() == 1


def test_missing_analysis_catalog_and_unrelated_query_do_not_invent_fallbacks(database):
    factory, _ = database
    raw = {"id": "new", "title": "https://instagram.com/p/123", "note": "", "text": "", "intents": []}
    assert recommend(factory, request(raw)).status == "needs_analysis"
    assert recommend(None, request(find())).status == "catalog_unavailable"
    assert recommend(factory, request(find(), query="completely nonexistent thing")).status == "no_matches"
    revoke_feed(factory, "abo", "local-dataset")
    assert recommend(factory, request(find())).status == "catalog_unavailable"


def test_repeated_marketplace_record_is_shown_once(database):
    factory, _ = database
    product = record("uk-watch", "Blue digital watch", "Watches", provenance={"original_item_id": "SAME", "source_url": "https://catalog.example.org/uk"})
    us = deepcopy(product)
    us["source_record_id"] = "us-watch"
    import_dataset(factory, "abo", [product, us], version="two-markets", checksum="c" * 64)
    result = recommend(factory, request(find()))
    assert len(result.items) == 1
    assert result.catalog_count == 2  # Source records, not unique products.


def test_other_real_sources_keep_their_citations_and_synthetic_rows_are_excluded(database):
    factory, _ = database
    for source, kind in [("wands", "open_dataset"), ("synthetic", "synthetic")]:
        row = record(source + "-watch", "Black digital watch", "WATCH")
        row.update(source_id=source, data_kind=kind)
        row["merchant"]["platform"] = source
        import_dataset(factory, source, [row], version="test", checksum="d" * 64)
    result = recommend(factory, request(find()))
    assert result.catalog_count == 10
    assert not any(item.source_id == "synthetic" for item in result.items)
    wands = next(item for item in result.items if item.source_id == "wands")
    assert wands.source_name == "Wayfair WANDS"
    assert wands.license_url.endswith("LICENSE")
    assert "Wayfair" in wands.attribution


def test_service_reads_downloaded_database_read_only(database):
    _, path = database
    service = LocalRecommendationService(path=path)
    response = service.recommendations(request(find()))
    assert response.status_code == 200 and b'"status":"ready"' in response.body
    assert response.headers["cache-control"] == "no-store"
    with pytest.raises(Exception):
        with service.engine.begin() as connection:
            connection.exec_driver_sql("CREATE TABLE should_not_write (id INTEGER)")
    service.engine.dispose()


def test_request_bounds_and_duplicate_source_ids_are_rejected():
    with pytest.raises(ValueError):
        request(find(), find())
    with pytest.raises(ValueError):
        request(find(), limit=51)
    with pytest.raises(ValueError):
        request(find(intents=["x" * 501]))
    with pytest.raises(ValueError):
        request(find(), query="x" * 101)


def test_endpoint_requires_authentication_before_parsing(database):
    from backend.app.capture_preview import create_app
    factory, _ = database
    app = create_app(api_key="unused-provider-key", token="private-test-token")
    app.state.recommendation_service.factory = factory
    with TestClient(app) as client:
        assert client.post("/v1/recommendations", content=b"not json").status_code == 401
        response = client.post("/v1/recommendations", json=request(find()).model_dump(), headers={"Authorization": "Bearer private-test-token"})
        assert response.status_code == 200 and response.json()["status"] == "ready"
        assert response.headers["cache-control"] == "no-store"
        assert "unused-provider-key" not in response.text
