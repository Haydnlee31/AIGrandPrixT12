import time
from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select, update

from backend.app.db import Evidence, Job, Notification, SavedItem
from backend.app.intelligence import CATALOG, shortlist
from backend.app.main import create_app
from backend.app.worker import run_once


@pytest.fixture
def client(tmp_path):
    app = create_app(f"sqlite:///{tmp_path / 'test.db'}", embedded_worker=False, tokens={"alex-token":"alex", "sam-token":"sam"}, demo_mode=True)
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer alex-token"
        yield client


def post(client, path, body, key=None, method="POST"):
    return client.request(method, "/v1" + path, json=body, headers={"Idempotency-Key":key or uuid4().hex})


def save(client, suffix="one", **kwargs):
    result = post(client, "/saves", {"url":f"https://example.com/{suffix}", "title":"Warm desk lighting", **kwargs})
    assert result.status_code == 201, result.text
    return result.json()["id"]


def drain(client):
    for _ in range(30):
        if not run_once(client.app.state.factory):
            break


def select_annotation(client, item, index=0):
    suggestion = client.get(f"/v1/saves/{item}").json()["suggestions"][index]
    result = post(client, f"/saves/{item}/responses", {"action":"select", "suggestion_id":suggestion["id"]})
    assert result.status_code == 200, result.text
    return suggestion


def explore(client):
    response = post(client, "/discovery-sessions", {"explicit":True})
    assert response.status_code == 201
    return response.json()


def event(client, session, action, value=None):
    data = {"expected_version":session["version"], "action":action}
    if value is not None:
        data["value"] = value
    return post(client, f"/discovery-sessions/{session['id']}/events", data)


def test_capture_is_durable_and_canonical_duplicates_do_not_inflate_context(client):
    body = {"url":"https://example.com/desk?utm_source=social#image", "title":"Warm desk"}
    first = post(client, "/saves", body, key="capture-1")
    assert first.json() == post(client, "/saves", body, key="capture-1").json()
    duplicate = post(client, "/saves", {**body, "url":"https://example.com/desk"}).json()
    assert duplicate["duplicate"] and duplicate["id"] == first.json()["id"]
    assert len(client.get('/v1/collection').json()["items"]) == 1
    with client.app.state.factory() as db:
        assert len(db.scalars(select(Job)).all()) == 1
    assert post(client, "/saves", {**body, "title":"Changed"}, key="capture-1").status_code == 409


def test_suggestions_are_not_evidence_and_skip_reject_do_not_confirm(client):
    item = save(client)
    drain(client)
    assert client.get('/v1/hypotheses').json()["items"][0]["evidence"] == []
    suggestion = client.get(f'/v1/saves/{item}').json()["suggestions"][0]
    for action in ["skip", "reject"]:
        assert post(client, f'/saves/{item}/responses', {"action":action,"suggestion_id":suggestion["id"]}).status_code == 200
    assert client.get('/v1/hypotheses').json()["items"][0]["evidence"] == []


def test_two_independent_confirmations_create_invitation_not_purchase_intent(client):
    first, second = save(client), save(client, "two")
    drain(client)
    select_annotation(client, first)
    assert client.get('/v1/hypotheses').json()["items"][0]["status"] == "collecting"
    select_annotation(client, second, 1)
    h = client.get('/v1/hypotheses').json()["items"][0]
    assert h["status"] == "invitable" and h["readiness"] == "unknown"
    select_annotation(client, second, 3)
    h = client.get('/v1/hypotheses').json()["items"][0]
    assert h["status"] == "collecting"
    assert any(e["relation"] == "opposes_readiness" for e in h["evidence"])


def test_annotation_edit_and_rejection_supersede_original_evidence(client):
    item = save(client)
    drain(client)
    suggestion = select_annotation(client, item)
    response = post(client, f'/saves/{item}/responses', {"action":"edit", "suggestion_id":suggestion["id"], "text":"I do not like warm lighting"})
    h = response.json()["hypothesis"]
    assert "warm_lighting" not in h["confirmed_preferences"]
    assert h["evidence"][0]["claim"] == "needs_clarification"
    post(client, f'/saves/{item}/responses', {"action":"reject", "suggestion_id":suggestion["id"]})
    assert not client.get('/v1/hypotheses').json()["items"][0]["evidence"]


def test_tenant_isolation_on_items_suggestions_sessions_watches_and_trace(client):
    item = save(client)
    drain(client)
    suggestion = select_annotation(client, item)
    session = explore(client)
    watch = post(client, '/watches', {"variant_id":"arc-sand", "target_minor":5000}).json()
    client.headers['Authorization'] = 'Bearer sam-token'
    assert client.get(f'/v1/saves/{item}').status_code == 404
    assert client.get(f'/v1/discovery-sessions/{session["id"]}').status_code == 404
    assert post(client, f'/watches/{watch["id"]}', {"enabled":False}, method="PATCH").status_code == 404
    own = save(client, "sam")
    assert post(client, f'/saves/{own}/responses', {"action":"select", "suggestion_id":suggestion["id"]}).status_code == 404
    assert client.get('/v1/trace').json()["hypothesis"]["evidence"] == []
    assert client.get('/v1/watches').json()["items"] == []


def test_authentication_and_validation_errors_have_one_shape(client):
    del client.headers['Authorization']
    response = client.get('/v1/collection')
    assert response.status_code == 401
    assert {"code","message","request_id","retryable"} <= response.json()["error"].keys()
    client.headers['Authorization'] = 'Bearer alex-token'
    for url in ["file:///etc/passwd", "http://127.0.0.1/a", "http://localhost/a", "https://user:pass@example.com"]:
        assert post(client, '/saves', {"url":url,"title":"test"}).status_code == 422
    assert client.post('/v1/saves', json={"url":"https://example.com", "title":"desk"}).status_code == 400


def test_discovery_feedback_persists_and_stale_writes_fail(client):
    s = explore(client)
    updated = event(client, s, 'less_clutter').json()
    assert updated["preferences"]["low_clutter"]
    stale = event(client, s, 'direction', 'warm')
    assert stale.status_code == 409 and stale.json()["error"]["code"] == "stale_version"
    assert stale.json()["error"]["current"]["version"] == updated["version"]
    loaded = client.get(f'/v1/discovery-sessions/{s["id"]}').json()
    assert loaded["preferences"]["low_clutter"]
    assert event(client, loaded, 'retrieve').status_code == 422
    loaded = event(client, loaded, 'budget', 8000).json()
    loaded = event(client, loaded, 'retrieve').json()
    assert len(loaded["products"]) == 2
    assert all(p["price_minor"] <= 8000 and p["source_record"] for p in loaded["products"])
    loaded = event(client, loaded, 'max_width', 10).json()
    loaded = event(client, loaded, 'retrieve').json()
    assert not loaded['products']
    loaded = event(client, loaded, 'max_width').json()
    loaded = event(client, loaded, 'retrieve').json()
    assert len(loaded['products']) == 2


def test_catalog_filters_do_not_relax_budget_dimensions_or_ownership():
    assert not shortlist({"budget_minor":100})
    assert not shortlist({"budget_minor":20000, "max_width_cm":10})
    result = shortlist({"budget_minor":20000, "low_clutter":True, "owned":["arc-sand", "beam-black"]})
    assert [p["variant_id"] for p in result] == ["halo-cream"]


def test_deleted_or_corrected_evidence_hides_old_recommendations(client):
    item = save(client)
    drain(client)
    select_annotation(client, item)
    s = explore(client)
    s = event(client, s, 'budget', 10000).json()
    s = event(client, s, 'retrieve').json()
    assert s["products"]
    assert post(client, f'/saves/{item}', {}, method="DELETE").status_code == 200
    loaded = client.get(f'/v1/discovery-sessions/{s["id"]}').json()
    assert loaded["context_stale"] and loaded["products"] == []
    assert event(client, loaded, 'choose', 'arc-sand').status_code == 409
    assert client.get('/v1/hypotheses').json()["items"][0]["evidence"] == []


def test_dismissal_suppresses_invites_and_sessions_until_explicit_restart(client):
    for suffix in ['one', 'two']:
        item = save(client, suffix)
        drain(client)
        select_annotation(client, item)
    s = explore(client)
    post(client, '/hypotheses/desk-lighting/feedback', {"action":"misunderstood"})
    assert client.get('/v1/hypotheses').json()["items"][0]["status"] == "suppressed"
    assert client.get(f'/v1/discovery-sessions/{s["id"]}').json()["stage"] == "dismissed"
    assert post(client, '/discovery-sessions', {"explicit":False}).status_code == 409
    assert post(client, '/discovery-sessions', {"explicit":True}).status_code == 201


def test_enrichment_failure_does_not_lose_capture_and_retries_are_bounded(client):
    class FailingProvider:
        def understand(self, *_):
            raise TimeoutError("provider offline")
    item = save(client)
    for _ in range(3):
        run_once(client.app.state.factory, FailingProvider())
        with client.app.state.factory.begin() as db:
            db.execute(update(Job).values(due_at=0))
    assert client.get(f'/v1/saves/{item}').json()["status"] == "enrichment_failed"
    assert client.get('/v1/trace').json()["jobs"][0]["status"] == "failed"
    result = post(client, f'/saves/{item}/responses', {"action":"edit","text":"I love the warm lighting"})
    assert result.json()["hypothesis"]["confirmed_preferences"] == ["warm_lighting"]


def test_deleted_pending_save_cannot_publish_stale_annotations(client):
    item = save(client)
    post(client, f'/saves/{item}', {}, method="DELETE")
    drain(client)
    assert client.get(f'/v1/saves/{item}').status_code == 404
    assert not client.get('/v1/collection').json()["items"]
    restored = save(client)
    assert restored == item
    drain(client)
    assert len(client.get(f'/v1/saves/{item}').json()["suggestions"]) == 4


def test_alert_threshold_crossings_and_request_retries_are_deduplicated(client):
    watch = post(client, '/watches', {"variant_id":"arc-sand", "target_minor":5000}).json()
    def observe(price, key=None):
        response = post(client, f'/watches/{watch["id"]}/simulate', {"variant_id":"arc-sand", "currency":"SGD", "amount_minor":price}, key=key)
        assert response.status_code == 200, response.text
        drain(client)
    observe(4900, key="price-one")
    observe(4900, key="price-one")
    observe(4800)
    assert len(client.get('/v1/notifications').json()["items"]) == 1
    observe(6000)
    observe(4900)
    assert len(client.get('/v1/notifications').json()["items"]) == 2
    assert post(client, f'/watches/{watch["id"]}/simulate', {"variant_id":"halo-cream", "currency":"SGD", "amount_minor":100}).status_code == 422
    assert post(client, f'/watches/{watch["id"]}/simulate', {"variant_id":"arc-sand", "currency":"USD", "amount_minor":100}).status_code == 422


def test_watch_rule_change_invalidates_already_queued_check(client):
    watch = post(client, '/watches', {"variant_id":"arc-sand", "target_minor":5000}).json()
    post(client, f'/watches/{watch["id"]}/simulate', {"variant_id":"arc-sand", "currency":"SGD", "amount_minor":4900})
    post(client, f'/watches/{watch["id"]}', {"target_minor":4000}, method="PATCH")
    drain(client)
    assert client.get('/v1/notifications').json()["items"] == []


def test_worker_recovers_expired_lease_without_duplicate_results(client):
    item = save(client)
    with client.app.state.factory.begin() as db:
        db.execute(update(Job).values(status="running", lease_until=time.time()-10, lease_token="dead-worker"))
    with ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(lambda _: run_once(client.app.state.factory), range(2)))
    drain(client)
    assert len(client.get(f'/v1/saves/{item}').json()["suggestions"]) == 4


def test_reset_does_not_touch_other_users(client):
    save(client)
    client.headers['Authorization'] = 'Bearer sam-token'
    save(client, 'sam')
    post(client, '/demo/reset', {})
    assert not client.get('/v1/collection').json()["items"]
    client.headers['Authorization'] = 'Bearer alex-token'
    assert len(client.get('/v1/collection').json()["items"]) == 1
