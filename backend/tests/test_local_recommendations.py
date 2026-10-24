"""Actual retrieval against isolated catalogs; no paid provider calls."""
from copy import deepcopy
from concurrent.futures import ThreadPoolExecutor
import json
import hashlib
import threading

from fastapi.testclient import TestClient
import pytest

import backend.app.local_recommendations as recommendation_module

from backend.app.catalog.search_index import ensure_index
from backend.app.catalog.recommendation_index import ensure_recommendation_index
from backend.app.catalog.service import import_dataset, revoke_feed
from backend.app.db import Base, SavedItem, make_database
from backend.app.local_recommendations import RecommendationRequest, LocalRecommendationService, recommend
from sqlalchemy import func, select


def record(identity, title, category, **changes):
    # Explicit test catalog identity, not an attempt to infer a real ASIN.
    asin = hashlib.sha256(identity.encode()).hexdigest()[:10].upper()
    image = "https://amazon-berkeley-objects.s3.us-east-1.amazonaws.com/images/small/ab/abcdef01.jpg"
    row = {"source_id": "abo", "source_record_id": identity, "data_kind": "open_dataset",
           "title": title, "description": title, "category": category, "brand": None,
           "attributes": {"main_image_id": "explicit-fixture-image"}, "merchant": {"id": None, "name": None, "platform": "abo"},
           "offer": {"id": identity, "environment": "local", "image_url": image},
           "provenance": {"source_url": "https://catalog.example.org/items/" + identity,
                          "original_item_id": asin, "source_record_id": asin, "domain_name": "amazon.com"}}
    if "attributes" in changes:
        changes["attributes"] = {**row["attributes"], **changes["attributes"]}
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
            "analysis": {"product_name": "Wristwatch" if noun == "watch" else noun,
                         "category_path": ["Accessories", "Watches", "Wristwatches"] if noun == "watch" else [noun],
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
    assert all(item.product_url.startswith("https://www.amazon.com/dp/") and item.price_minor is None and item.currency is None and item.availability == "unknown" for item in result.items)
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


def test_product_subtype_cannot_fill_results_with_wrong_requested_color(database):
    factory, _ = database
    result = recommend(factory, request(find(intents=["I want a blue digital watch"])))
    assert [item.source_record_id for item in result.items] == ["blue-watch"]
    missing = recommend(factory, request(find(intents=["I want a silver digital watch"])))
    assert missing.status == "no_matches"  # Silver analog and black digital are not this request.


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


def test_missing_same_record_photo_does_not_show_an_unrelated_replacement(database):
    factory, _ = database
    import_dataset(factory, "abo", [
        record("phone", "Black phone", "Phones", offer={"id": "phone", "environment": "local", "image_url": None}),
        record("watch", "Black digital wristwatch", "Watches", brand="Casio"),
        record("phone-case", "Black smartphone case", "Phone cases"),
    ], version="mixed-photo-coverage", checksum="e" * 64)
    result = recommend(factory, request(find("saved-phone", "phone"), find(), limit=2))
    assert [item.source_record_id for item in result.items] == ["watch"]
    assert result.items[0].image_url.endswith("/ab/abcdef01.jpg")
    # A photo is never enough to turn an accessory into the requested product.
    phone_only = recommend(factory, request(find("saved-phone", "phone")))
    assert phone_only.status == "no_matches" and not phone_only.items


def test_photo_presentation_keeps_preference_order_within_photo_group(database):
    factory, _ = database
    result = recommend(factory, request(find(intents=["I like blue", "I prefer digital"])))
    assert result.items[0].source_record_id == "blue-watch"
    assert all(item.image_url for item in result.items)


@pytest.mark.parametrize("category", ["Smartphones", "Mobilephones"])
def test_phone_category_aliases_survive_fts_and_match_without_accessories(database, category):
    factory, _ = database
    import_dataset(factory, "abo", [
        record("actual-phone", "Black smartphone", category),
        record("case", "Black smartphone case", category + " cases"),
        record("stand", "Black smartphone stand", category + " stands"),
    ], version="phone-category-alias", checksum="f" * 64)
    result = recommend(factory, request(find("my-phone", "phone")))
    assert [item.source_record_id for item in result.items] == ["actual-phone"]
    assert result.items[0].image_url.endswith("/ab/abcdef01.jpg")
    assert result.items[0].reasons[0].find_id == "my-phone"
    assert [item.source_record_id for item in recommend(factory, request(find("my-phone", "phone"), query="phone")).items] == ["actual-phone"]


@pytest.mark.parametrize("signal", ["product_name", "category_path", "saved_title", "selected_intent"])
def test_smartphone_intent_never_promotes_pictured_home_telephones(database, signal):
    factory, _ = database
    phones = [record("mobile", "Samsung Galaxy smartphone", "Smartphones")]
    for index, title in enumerate([
        "AmazonBasics DECT Home Telephone Set 3", "Telephone with answering machine",
        "Corded office phone", "Cordless telephone", "Land-line phone", "Desktop phone",
    ]):
        phones.append(record(f"home-{index}", title, "PHONE"))
    import_dataset(factory, "abo", phones, version="mobile-vs-landline", checksum="9" * 64)
    saved = find("saved-phone", "phone")
    if signal == "product_name":
        saved["analysis"]["product_name"] = "iPhone 18 Pro Max"
    elif signal == "category_path":
        saved["analysis"]["category_path"] = ["Electronics", "Mobile phones", "Smartphones"]
    elif signal == "saved_title":
        saved["title"] = "iPhone 18 Duo"
    else:
        saved["intents"] = ["I want a mobile phone"]
    result = recommend(factory, request(saved))
    assert [item.source_record_id for item in result.items] == ["mobile"]
    assert result.items[0].image_url.endswith("/ab/abcdef01.jpg")
    assert all(reason.find_id == "saved-phone" for reason in result.items[0].reasons)
    # The restriction belongs to mobile intent, not every phone in the catalog.
    generic = recommend(factory, request(find("home-phone", "phone")))
    assert "home-0" in {item.source_record_id for item in generic.items}


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
    product = record("uk-watch", "Blue digital watch", "Watches")
    product["provenance"]["domain_name"] = "amazon.co.uk"
    us = deepcopy(product)
    us["source_record_id"] = "us-watch"
    us["provenance"]["domain_name"] = "amazon.com"
    import_dataset(factory, "abo", [product, us], version="two-markets", checksum="c" * 64)
    result = recommend(factory, request(find()))
    assert len(result.items) == 1
    assert result.catalog_count == 2  # Source records, not unique products.


def test_non_amazon_sources_and_synthetic_rows_are_excluded(database):
    factory, _ = database
    for source, kind in [("wands", "open_dataset"), ("synthetic", "synthetic")]:
        row = record(source + "-watch", "Black digital watch", "WATCH")
        row.update(source_id=source, data_kind=kind)
        row["merchant"]["platform"] = source
        import_dataset(factory, source, [row], version="test", checksum="d" * 64)
    result = recommend(factory, request(find()))
    assert result.catalog_count == 9
    assert all(item.source_id == "abo" for item in result.items)


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


def test_precise_color_preference_outweighs_generic_dial_strap_words(database):
    factory, _ = database
    generic = record("generic", "Black digital watch with strap dial face case band display", "WATCH")
    blue = record("specific-blue", "Blue wristwatch", "WATCH")
    import_dataset(factory, "abo", [generic, blue], version="precise-color", checksum="e" * 64)
    saved = find(intents=["I like blue", "dial strap face case band display"])
    saved["analysis"]["style"] = ["dial strap face case band display digital"]
    result = recommend(factory, request(saved))
    assert result.items[0].source_record_id == "specific-blue"
    assert result.items[0].reasons[0].matched_value == "blue"
    assert "color you liked" in result.items[0].reasons[0].text


def test_watch_preferences_keep_strap_dial_and_stitching_relationships(database):
    factory, _ = database
    import_dataset(factory, "abo", [
        record("black-nylon", "Black nylon strap watch", "WATCH",
               description="Glossy black dial with silver-tone hands and white Arabic numerals. Black nylon strap."),
        record("green-nylon", "Green nylon strap watch", "WATCH",
               description="Glossy white dial with silver-tone hands and black Arabic numerals. Green nylon strap."),
        record("silver-dial", "Analog silver dial watch", "WATCH",
               description="Dial Color: Silver, Band Color: Brown, Band Material: Synthetic"),
        record("black-leather", "Black leather strap watch", "WATCH",
               description="Black leather strap with white stitching and silver dial."),
    ], version="part-aware-watch", checksum="7" * 64)
    saved = find(intents=["I like the black leather strap with white stitching.",
                         "I appreciate the understated silver dial color."])
    saved["analysis"].update(brand=None, category_path=["Wristwatches"], style=["classic", "leather strap", "round face"])
    result = recommend(factory, request(saved))
    by_id = {item.source_record_id: item for item in result.items}
    assert result.items[0].source_record_id == "black-leather"
    assert "green-nylon" not in by_id  # No requested part/color match: do not pad the results.
    assert {reason.matched_value for reason in by_id["black-nylon"].reasons} == {"black strap"}
    assert {reason.matched_value for reason in by_id["silver-dial"].reasons} == {"silver dial"}
    # Missing exact materials remain alternatives, not a new hard filter.
    assert len(result.items) == 3
    assert all(item.price_minor is None and item.availability == "unknown" for item in result.items)


def test_part_preferences_accept_structured_source_fields_without_inferring_unqualified_colors(database):
    factory, _ = database
    import_dataset(factory, "abo", [
        record("specified", "Analog watch", "WATCH", attributes={"band_color": "Black", "dial_color": "Silver"}),
        record("unspecified", "Analog watch", "WATCH", attributes={"color": "Black/Silver"}),
    ], version="part-attributes", checksum="8" * 64)
    result = recommend(factory, request(find(intents=["I like a black strap and silver dial"])))
    assert result.items[0].source_record_id == "specified"
    assert {reason.matched_value for reason in result.items[0].reasons} == {"black strap", "silver dial"}
    assert len(result.items) == 1  # Unqualified colors cannot establish the requested part.


@pytest.mark.parametrize("negative", ["no black or silver", "don't want black or silver", "avoid black and silver"])
def test_multiple_negative_preferences_are_not_mistaken_for_positive_choices(database, negative):
    factory, _ = database
    result = recommend(factory, request(find(intents=[negative, "I prefer digital blue"])))
    assert {item.source_record_id for item in result.items} == {"blue-watch"}


def test_negative_material_does_not_exclude_every_kind_of_strap(database):
    factory, _ = database
    import_dataset(factory, "abo", [
        record("leather", "Black leather strap watch", "WATCH"),
        record("nylon", "Black nylon strap watch", "WATCH"),
    ], version="material-negative", checksum="f" * 64)
    result = recommend(factory, request(find(intents=["without leather strap", "I like black"])))
    assert [item.source_record_id for item in result.items] == ["nylon"]


def test_nested_source_attributes_match_without_repeated_why_text(database):
    factory, _ = database
    import_dataset(factory, "abo", [record("nested-blue", "Digital wristwatch", "WATCH",
        attributes={"color": [{"value": "Blue", "language_tag": "en_US"}]})], version="nested-color", checksum="1" * 64)
    saved = find(intents=["I like blue", "Blue is my favorite color"])
    saved["note"] = "blue"
    saved["analysis"]["style"] = ["Blue", "blue"]
    result = recommend(factory, request(saved))
    reasons = result.items[0].reasons
    assert sum(reason.matched_value.lower() == "blue" for reason in reasons) == 1
    assert len({reason.text for reason in reasons}) == len(reasons)


def test_small_category_avoids_repeated_broad_text_index_queries(database, monkeypatch):
    factory, _ = database
    def unexpected(*args, **kwargs):
        raise AssertionError("Small categories should be fetched once, not repeatedly text searched")
    monkeypatch.setattr(recommendation_module, "matching_product_ids", unexpected)
    assert recommend(factory, request(find())).items


def test_identical_request_is_computed_once_and_cache_expires(database, monkeypatch):
    factory, _ = database
    clock = [10.0]
    service = LocalRecommendationService(factory, clock=lambda: clock[0])
    original = recommendation_module.recommend
    calls = []
    def counted(*args, **kwargs):
        calls.append(True)
        return original(*args, **kwargs)
    monkeypatch.setattr(recommendation_module, "recommend", counted)
    first = service.recommendations(request(find()))
    second = service.recommendations(request(find()))
    assert len(calls) == 1
    assert first.body == second.body and second.headers["x-mynah-cache"] == "hit"
    assert second.headers["cache-control"] == "no-store"
    clock[0] += 61
    assert service.recommendations(request(find())).headers["x-mynah-cache"] == "miss"
    assert len(calls) == 2


def test_cache_is_bounded_and_keys_do_not_retain_private_capture_text(database, monkeypatch):
    factory, _ = database
    monkeypatch.setattr(recommendation_module, "CACHE_MAX_ENTRIES", 2)
    service = LocalRecommendationService(factory)
    for color in ("blue", "black", "silver"):
        saved = find(intents=[color])
        saved["note"] = "private gift note " + color
        service.recommendations(request(saved))
    assert len(service.cache) == 2
    assert all(len(key) == 64 and "private" not in key for key in service.cache)


def test_cache_isolated_by_find_identity_notes_intents_and_search(database):
    factory, _ = database
    service = LocalRecommendationService(factory)
    alice = find("alice-watch", intents=["blue"])
    alice["title"] = "Alice's private find"
    bob = find("bob-watch", intents=["black"])
    bob["title"] = "Bob's private find"
    first = json.loads(service.recommendations(request(alice)).body)
    second = json.loads(service.recommendations(request(bob)).body)
    assert first["items"][0]["source_record_id"] == "blue-watch"
    assert second["items"][0]["source_record_id"] == "black-watch"
    assert all(reason["find_id"] == "bob-watch" and reason["find_title"] == "Bob's private find" for item in second["items"] for reason in item["reasons"])
    bob["intents"] = ["blue"]
    assert json.loads(service.recommendations(request(bob)).body)["items"][0]["source_record_id"] == "blue-watch"
    bob["note"] = "no blue"
    assert all(item["source_record_id"] != "blue-watch" for item in json.loads(service.recommendations(request(bob)).body)["items"])
    assert json.loads(service.recommendations(request(alice, query="silver")).body)["items"][0]["source_record_id"] == "silver-watch"
    assert json.loads(service.recommendations(request()).body)["status"] == "needs_saves"


def test_catalog_replacement_and_revocation_invalidate_cached_results_immediately(database):
    factory, _ = database
    service = LocalRecommendationService(factory)
    assert service.recommendations(request(find())).status_code == 200
    import_dataset(factory, "abo", [record("fresh", "Blue digital watch", "WATCH")], version="new-catalog", checksum="2" * 64)
    updated = service.recommendations(request(find()))
    assert updated.headers["x-mynah-cache"] == "miss"
    payload = json.loads(updated.body)
    assert payload["catalog_count"] == 1
    assert [item["source_record_id"] for item in payload["items"]] == ["fresh"]
    revoke_feed(factory, "abo", "local-dataset")
    withdrawn = json.loads(service.recommendations(request(find())).body)
    assert withdrawn["status"] == "catalog_unavailable" and not withdrawn["items"]


def test_concurrent_identical_refreshes_share_one_retrieval(database, monkeypatch):
    factory, _ = database
    service = LocalRecommendationService(factory)
    original = recommendation_module.recommend
    entered, release = threading.Event(), threading.Event()
    calls = []
    def delayed(*args, **kwargs):
        calls.append(True)
        entered.set()
        assert release.wait(timeout=5)
        return original(*args, **kwargs)
    monkeypatch.setattr(recommendation_module, "recommend", delayed)
    with ThreadPoolExecutor(max_workers=3) as executor:
        one = executor.submit(service.recommendations, request(find()))
        assert entered.wait(timeout=5)
        two = executor.submit(service.recommendations, request(find()))
        three = executor.submit(service.recommendations, request(find()))
        release.set()
        results = [future.result(timeout=5) for future in (one, two, three)]
    assert len(calls) == 1
    assert all(response.status_code == 200 for response in results)
    assert len({response.body for response in results}) == 1
