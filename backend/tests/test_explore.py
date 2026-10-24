import pytest

import backend.app.explore as explore_service

from backend.app.catalog.search_index import ensure_index
from backend.app.catalog.service import CatalogError, import_dataset, import_snapshot, revoke_feed
from backend.app.db import Base, Evidence, SavedItem, UserEvent, UserState, make_database
from backend.app.explore import CANDIDATE_LIMIT, ExplorePage, explore


@pytest.fixture
def database(tmp_path):
    engine, factory = make_database(f"sqlite:///{tmp_path / 'explore.db'}")
    Base.metadata.create_all(engine)
    with engine.begin() as connection:
        ensure_index(connection)
    yield factory
    engine.dispose()


def record(record_id="digital", title="Casio vintage digital watch", source="abo", category="Accessories > Watches > Digital watches", brand="Casio", **changes):
    row = {"source_id": source, "source_record_id": record_id, "data_kind": "open_dataset",
        "title": title, "category": category, "brand": brand, "description": "Silver rectangular display with a vintage style.",
        "attributes": {"style": "vintage", "display_type": "digital"},
        "merchant": {"id": None, "name": None, "platform": source},
        "offer": {"id": record_id, "environment": "local"},
        "provenance": {"source_url": f"https://catalog.example.org/items/{record_id}"}}
    row.update(changes)
    return row


def ingest(factory, rows=None, source="abo"):
    import_dataset(factory, source, rows or [record(source=source)], version="test", checksum="a" * 64)


def analysis():
    return {"schema_version": 1, "summary": "A vintage digital wristwatch with a Casio label.",
        "products": [{"product_type": "watch", "category_path": ["Accessories", "Watches", "Digital watches"],
            "brand": {"value": "Casio", "basis": "image", "evidence": "Visible Casio label", "certainty": "observed"},
            "model": None,
            "attributes": [{"name": "style", "value": "vintage", "basis": "image", "evidence": "Retro rectangular case", "certainty": "inferred"},
                           {"name": "display_type", "value": "digital", "basis": "image", "evidence": "LCD digits", "certainty": "observed"}],
            "use_cases": ["Timekeeping"], "search_terms": ["vintage digital watch"]}],
        "intent_context": [], "uncertainties": ["Exact model unknown"]}


def save(factory, *, user="alex", item_id="saved-watch", status="ready", deleted=False, data=None):
    with factory.begin() as db:
        db.add(SavedItem(id=item_id, user_id=user, original_url=f"https://saved.example.org/{item_id}",
            canonical_url=f"https://saved.example.org/{item_id}", title="My watch inspiration", source="web", client="ios_app",
            revision=2, status=status, deleted=deleted, features={"analysis": analysis() if data is None else data}))
        if db.get(UserState, user) is None:
            db.add(UserState(user_id=user, version=3))
    return item_id


def intent(factory, item_id, claim="buy_intent", *, active=True, user="alex", name="intent"):
    with factory.begin() as db:
        event = UserEvent(id=name + "-event", user_id=user, item_id=item_id, event_type="annotation_response", payload={"action": "select"})
        db.add(event)
        db.flush()
        db.add(Evidence(id=name, user_id=user, item_id=item_id, event_id=event.id, claim=claim,
            text="An explicit annotation", origin="confirmed_annotation", active=active))


def get(factory, **kwargs):
    with factory() as db:
        result = explore(db, kwargs.pop("user_id", "alex"), kwargs.pop("source_id", "abo"), **kwargs)
        ExplorePage.model_validate(result)
        return result


def test_fine_category_style_brand_rank_and_cite_actual_fields(database):
    ingest(database, [record(), record("analog", "Modern analog watch", category="Accessories > Watches > Analog watches", brand="Other",
        description="Round modern face", attributes={"style": "modern"}),
        record("chair", "Vintage digital chair", category="Furniture > Chairs", brand="Casio"),
        record("box", "Casio vintage digital watch box", category="Accessories > Watch storage boxes")])
    saved_id = save(database)
    result = get(database)
    assert result["status"] == "ready" and result["mode"] == "personalized"
    assert [item["product"]["source_record_id"] for item in result["items"]] == ["digital", "analog"]
    first = result["items"][0]
    assert first["score"] > result["items"][1]["score"]
    assert {reason["kind"] for reason in first["reasons"]} == {"category_match", "attribute_match", "brand_match"}
    for reason in first["reasons"]:
        assert reason["saved_item_id"] == saved_id and reason["saved_item_revision"] == 2
        assert reason["analysis_path"].startswith("products.0.")
        assert reason["catalog_value"]
        assert "detected" in reason["text"] and "you want to buy" not in reason["text"]
    assert first["catalog_citation"]["license_id"] == "CC-BY-4.0"
    assert first["catalog_citation"]["record_id"] == "digital"
    assert first["catalog_citation"]["record_url"] == "https://catalog.example.org/items/digital"
    assert first["product"]["offer"]["price_minor"] is None
    assert first["action"] == "view_source" and first["action_url"] == first["catalog_citation"]["record_url"]
    assert result["context_version"] == 3 and result["personalized_from_saves"] == 1


def test_only_confirmed_active_current_users_intent_can_affect_score(database):
    ingest(database)
    item_id = save(database)
    before = get(database)["items"][0]
    intent(database, item_id, active=False, name="rejected")
    intent(database, item_id, user="other", name="foreign")
    assert get(database)["items"][0]["score"] == before["score"]
    intent(database, item_id)
    confirmed = get(database)["items"][0]
    assert confirmed["score"] == before["score"] + 2
    assert next(reason for reason in confirmed["reasons"] if reason["kind"] == "confirmed_intent")["evidence_id"] == "intent"
    with database.begin() as db:
        db.get(Evidence, "intent").active = False
    assert get(database)["items"][0]["score"] == before["score"]


def test_inspiration_is_not_turned_into_purchase_intent(database):
    ingest(database)
    item_id = save(database)
    before = get(database)["items"][0]
    intent(database, item_id, claim="save_inspiration")
    after = get(database)["items"][0]
    assert before["score"] == after["score"]
    assert not any(reason["kind"] == "confirmed_intent" for reason in after["reasons"])


def test_no_private_cross_user_or_deleted_saves_and_no_cached_recommendations(database):
    ingest(database)
    save(database, user="other", item_id="other")
    assert get(database)["status"] == "needs_saves"
    own_id = save(database)
    assert get(database)["items"]
    with database.begin() as db:
        db.get(SavedItem, own_id).deleted = True
    result = get(database)
    assert result["items"] == [] and result["status"] == "needs_saves"


@pytest.mark.parametrize("delete_saved_item", [False, True])
def test_context_change_during_retrieval_does_not_return_stale_citations(database, monkeypatch, delete_saved_item):
    ingest(database)
    saved_id = save(database)
    original_candidates = explore_service._candidates

    def change_during_retrieval(*args, **kwargs):
        result = original_candidates(*args, **kwargs)
        with database.begin() as writer:
            writer.get(UserState, "alex").version += 1
            if delete_saved_item:
                writer.get(SavedItem, saved_id).deleted = True
        return result

    monkeypatch.setattr(explore_service, "_candidates", change_during_retrieval)
    with pytest.raises(CatalogError) as error:
        get(database)
    assert error.value.code == "explore_context_changed"


def test_context_version_recheck_bypasses_the_orm_identity_map(database, monkeypatch):
    ingest(database)
    save(database)
    original_candidates = explore_service._candidates

    def change_version(*args, **kwargs):
        result = original_candidates(*args, **kwargs)
        with database.begin() as writer:
            writer.get(UserState, "alex").version += 1
        return result

    monkeypatch.setattr(explore_service, "_candidates", change_version)
    with database() as db:
        cached_state = db.get(UserState, "alex")
        assert cached_state.version == 3
        with pytest.raises(CatalogError) as error:
            explore(db, "alex", "abo")
        assert error.value.code == "explore_context_changed"
        assert cached_state.version == 3


@pytest.mark.parametrize("state", ["pending", "enrichment_failed"])
def test_pending_and_failed_analysis_does_not_personalize(database, state):
    ingest(database)
    save(database, status=state)
    result = get(database)
    assert result["status"] == "needs_analysis" and not result["items"]


def test_malformed_or_unobserved_brand_analysis_is_not_retrieval_input(database):
    ingest(database)
    invalid = analysis()
    invalid["products"][0]["brand"]["certainty"] = "inferred"
    save(database, data=invalid)
    assert get(database)["status"] == "needs_analysis"


def test_unrelated_products_are_not_forced_into_recommendations(database):
    ingest(database, [record("chair", "Vintage chair", category="Furniture > Chairs", brand="Other")])
    save(database)
    result = get(database)
    assert result["items"] == [] and result["status"] == "no_matches"


def test_completed_nonproduct_analysis_does_not_request_reanalysis(database):
    ingest(database)
    nonproduct = analysis()
    nonproduct.update(summary="A scenic landscape without an identifiable product", products=[])
    save(database, data=nonproduct)
    result = get(database)
    assert result["status"] == "no_matches"
    assert result["personalized_from_saves"] == 1 and result["items"] == []


def test_search_works_without_library_context_and_cites_catalog_terms(database):
    ingest(database)
    result = get(database, q="Casio digital watch")
    assert result["mode"] == "search" and result["status"] == "ready"
    assert result["personalized_from_saves"] == 0
    reasons = result["items"][0]["reasons"]
    assert all(reason["kind"] == "query_match" and reason["saved_item_id"] is None for reason in reasons)
    assert all(reason["catalog_field"] and reason["catalog_value"] for reason in reasons)


def test_search_accepts_literal_token_prefixes_without_relaxing_profile_matching(database):
    ingest(database)
    result = get(database, q="casi digi wat")
    assert len(result["items"]) == 1
    assert result["items"][0]["reasons"][0]["kind"] == "query_match"


def test_search_preserves_source_isolation_and_revocation(database):
    ingest(database)
    ingest(database, [record(source="wands")], source="wands")
    result = get(database, q="watch")
    assert {item["product"]["source_id"] for item in result["items"]} == {"abo"}
    revoke_feed(database, "abo", "local-dataset")
    with pytest.raises(CatalogError, match="imported"):
        get(database, q="watch")
    assert get(database, source_id="wands", q="watch")["items"]


def test_fresh_affiliate_offers_expire_and_are_never_substituted_with_other_sources(database):
    row = record(source="impact", data_kind="merchant_feed")
    row["merchant"].update(id="seller", name="Seller")
    row["offer"].update(environment="production", url="https://merchant.example.org/watch", price_minor=5000, currency="SGD")
    row["provenance"]["catalog_id"] = "approved"
    import_snapshot(database, "impact", "approved", [row], approval_reference="test", source_observed_at=1000, freshness_seconds=60, now=1000)
    result = get(database, source_id="impact", q="watch", now=1020)
    assert result["items"][0]["action"] == "view_offer" and result["expires_at"] == 1060
    assert not get(database, source_id="impact", q="watch", now=1061)["items"]


def test_synthetic_records_only_return_for_the_explicit_synthetic_source(database):
    ingest(database)
    synthetic = record(source="synthetic", data_kind="synthetic")
    synthetic["provenance"] = {"is_synthetic": True}
    ingest(database, [synthetic], source="synthetic")
    assert all(item["product"]["data_kind"] == "open_dataset" for item in get(database, q="watch")["items"])
    assert get(database, source_id="synthetic", q="watch")["items"][0]["product"]["data_kind"] == "synthetic"


def test_bounded_candidate_pagination_reports_limited_window(database):
    ingest(database, [record(str(index)) for index in range(CANDIDATE_LIMIT + 20)])
    first = get(database, q="watch", limit=50)
    second = get(database, q="watch", limit=50, offset=50)
    assert first["candidate_count"] == CANDIDATE_LIMIT and first["candidate_window_limited"] is True
    assert first["next_offset"] == 50 and second["next_offset"] == 100
    assert {item["product"]["source_record_id"] for item in first["items"]}.isdisjoint(item["product"]["source_record_id"] for item in second["items"])


@pytest.mark.parametrize("options", [{"q": "x" * 101}, {"q": "watch\n"}, {"offset": 500}, {"limit": 0}, {"limit": True}, {"source_id": "unregistered"}])
def test_invalid_requests_are_rejected(database, options):
    ingest(database)
    with pytest.raises(CatalogError):
        get(database, **options)


def test_untrusted_source_link_is_not_exposed_as_an_action(database):
    row = record()
    row["provenance"]["source_url"] = "javascript:alert(1)"
    ingest(database, [row])
    result = get(database, q="watch")["items"][0]
    assert result["catalog_citation"]["record_url"] is None and result["action_url"] is None


def test_brand_matching_does_not_treat_a_compatibility_mention_as_the_brand(database):
    ingest(database, [record("other", "Digital watch compatible with Casio straps", brand="Other")])
    save(database)
    reasons = get(database)["items"][0]["reasons"]
    assert not any(reason["kind"] == "brand_match" for reason in reasons)
