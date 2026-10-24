"""Predictive annotations integrate with private captures without executing intent."""
import base64
from io import BytesIO
import re
from uuid import uuid4

from fastapi.testclient import TestClient
from PIL import Image
import pytest
from sqlalchemy import delete, event, func, inspect, select

from backend.app.db import Evidence, Job, Mutation, Notification, SavedItem, Suggestion, Watch
from backend.app.main import create_app
from backend.app.worker import run_once, validate_annotation


class CaptureProvider:
    version = "gpt-6-astra:predictive-test"
    data_mode = "astra"

    def __init__(self):
        self.snapshots = []
        self.callback = None

    def understand_capture(self, snapshot):
        self.snapshots.append(snapshot)
        if self.callback:
            self.callback()
        return {
            "features": {"subject": "Desk lamp", "data_mode": "astra", "image_analyzed": bool(snapshot.image_data_url)},
            "suggestions": [
                {"kind": "intent", "claim": "buy_intent", "text": "I would like to buy this"},
                {"kind": "intent", "claim": "track_discount", "text": "Keep track of this product for discounts"},
                {"kind": "intent", "claim": "remind_later", "text": "Remind me about this product tomorrow"},
            ],
        }


@pytest.fixture
def client(tmp_path):
    provider = CaptureProvider()
    app = create_app(
        f"sqlite:///{tmp_path / 'predictive.db'}", embedded_worker=False,
        tokens={"alex-token": "alex", "sam-token": "sam"}, annotation_provider=provider,
        demo_mode=False, allowed_origins=[],
    )
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer alex-token"
        yield client


def image_data(color="red"):
    buffer = BytesIO()
    Image.new("RGB", (12, 8), color).save(buffer, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode()


def post(client, path, body, *, key=None, user="alex"):
    return client.post("/v1" + path, json=body, headers={
        "Idempotency-Key": key or uuid4().hex, "Authorization": f"Bearer {user}-token",
    })


def capture(client, name, *, user="alex", **extra):
    response = post(client, "/saves", {"title": name, "url": f"https://example.com/{name}", **extra}, user=user)
    assert response.status_code == 201, response.text
    return response.json()["id"]


def enrich(client):
    assert run_once(client.app.state.factory, client.app.state.annotation_provider)


def respond(client, item_id, claim, *, action="select", user="alex"):
    details = client.get(f"/v1/saves/{item_id}", headers={"Authorization": f"Bearer {user}-token"}).json()
    suggestion = next(value for value in details["suggestions"] if value["claim"] == claim)
    response = post(client, f"/saves/{item_id}/responses", {"action": action, "suggestion_id": suggestion["id"]}, user=user)
    assert response.status_code == 200, response.text
    return response


def remove(client, item_id):
    response = client.delete(f"/v1/saves/{item_id}", headers={"Idempotency-Key": uuid4().hex})
    assert response.status_code == 200, response.text


def test_ranked_suggestions_survive_database_row_order(client):
    item_id = capture(client, "ranked")
    enrich(client)
    with client.app.state.factory.begin() as db:
        rows = db.scalars(select(Suggestion).where(Suggestion.item_id == item_id)).all()
        copies = [{"user_id": row.user_id, "item_id": row.item_id, "kind": row.kind,
                   "text": row.text, "claim": row.claim, "model_version": row.model_version} for row in rows]
        db.execute(delete(Suggestion).where(Suggestion.item_id == item_id))
        for index, row in enumerate(reversed(copies)):
            db.add(Suggestion(id=f"ordered-{index}", **row))
    view = client.get(f"/v1/saves/{item_id}").json()
    assert [suggestion["claim"] for suggestion in view["suggestions"]] == ["buy_intent", "track_discount", "remind_later"]


@pytest.mark.parametrize("include_url", [False, True])
def test_capture_image_is_private_and_reaches_provider_with_note(client, include_url):
    payload = {"title": "Lamp", "image_data_url": image_data(), "note": "For my reading corner", "client": "ios_share_extension"}
    if include_url:
        payload["url"] = "https://example.com/lamp"
    response = post(client, "/saves", payload)
    assert response.status_code == 201, response.text
    item_id = response.json()["id"]
    enrich(client)
    snapshot = client.app.state.annotation_provider.snapshots[-1]
    assert snapshot.note == payload["note"]
    assert snapshot.title == "Lamp"
    assert snapshot.image_data_url.startswith("data:image/png;base64,")
    view = client.get(f"/v1/saves/{item_id}").json()
    assert view["status"] == "ready"
    assert view["has_image"] is True
    assert view["image_path"] == f"/v1/saves/{item_id}/image"
    assert view["features"]["image_analyzed"] is True
    assert all(value["status"] == "proposed" and value["requires_confirmation"] for value in view["suggestions"])
    assert all(value["intent"] == value["claim"] for value in view["suggestions"])
    for path in [f"/v1/saves/{item_id}", "/v1/collection"]:
        response = client.get(path)
        assert response.status_code == 200
        body = response.text
        assert "image_data_url" not in body
        assert "data:image" not in body
    image = client.get(view["image_path"])
    assert image.status_code == 200
    assert image.headers["content-type"] == "image/png"
    assert image.headers["cache-control"] == "no-store"
    assert Image.open(BytesIO(image.content)).size == (12, 8)
    assert client.get(view["image_path"], headers={"Authorization": "Bearer sam-token"}).status_code == 404
    assert client.get(view["image_path"], headers={"Authorization": ""}).status_code == 401
    with client.app.state.factory() as db:
        evidence = list(db.scalars(select(Evidence)))
        assert len(evidence) == 1 and evidence[0].origin == "explicit_statement"
        assert evidence[0].text == payload["note"]
        assert evidence[0].claim not in {"buy_intent", "track_discount", "remind_later"}
        assert all("data:image" not in str(row.response) for row in db.scalars(select(Mutation)))


def test_capture_requires_url_or_image_and_existing_url_capture_still_works(client):
    assert post(client, "/saves", {"title": "Missing content"}).status_code == 422
    assert post(client, "/saves", {"title": "Bad image", "image_data_url": "https://example.com/image.png"}).status_code == 422
    item_id = capture(client, "url-only")
    enrich(client)
    assert client.app.state.annotation_provider.snapshots[-1].image_data_url is None
    assert client.get(f"/v1/saves/{item_id}/image").status_code == 404


def test_image_capture_retries_and_deduplication_create_only_one_job(client):
    payload = {"title": "Lamp", "image_data_url": image_data()}
    key = uuid4().hex
    first = post(client, "/saves", payload, key=key)
    replay = post(client, "/saves", payload, key=key)
    duplicate = post(client, "/saves", {**payload, "title": "Changed title"})
    assert first.status_code == replay.status_code == duplicate.status_code == 201
    assert first.json() == replay.json()
    assert first.json()["duplicate"] is False
    assert duplicate.json()["duplicate"] is True
    assert duplicate.json()["id"] == first.json()["id"]
    assert client.get(f"/v1/saves/{first.json()['id']}").json()["title"] == "Lamp"
    conflict = post(client, "/saves", {**payload, "image_data_url": image_data("blue")}, key=key)
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "idempotency_conflict"
    with client.app.state.factory() as db:
        assert db.scalar(select(func.count()).select_from(SavedItem)) == 1
        assert db.scalar(select(func.count()).select_from(Job)) == 1


def test_deleting_image_erases_bytes_and_invalidates_image_access(client):
    item_id = capture(client, "delete-image", image_data_url=image_data())
    enrich(client)
    remove(client, item_id)
    assert client.get(f"/v1/saves/{item_id}/image").status_code == 404
    assert client.get(f"/v1/saves/{item_id}").status_code == 404
    assert client.get("/v1/collection").json()["items"] == []
    with client.app.state.factory() as db:
        row = db.get(SavedItem, item_id)
        assert row.deleted and row.image_data_url is None
        assert db.scalar(select(func.count()).select_from(Suggestion)) == 0
        assert all("data:image" not in str(row.response) for row in db.scalars(select(Mutation)))


def test_only_active_user_confirmed_context_crosses_provider_boundary(client):
    confirmed = capture(client, "confirmed")
    enrich(client)
    respond(client, confirmed, "buy_intent")
    rejected = capture(client, "rejected")
    enrich(client)
    respond(client, rejected, "track_discount")
    respond(client, rejected, "track_discount", action="reject")
    deleted = capture(client, "deleted")
    enrich(client)
    respond(client, deleted, "remind_later")
    remove(client, deleted)
    capture(client, "proposed-only")
    enrich(client)
    sam = capture(client, "sam-private", user="sam")
    enrich(client)
    respond(client, sam, "track_discount", user="sam")
    capture(client, "explicit-note", note="I like warm lighting")
    enrich(client)
    capture(client, "target", note="For my reading corner")
    enrich(client)
    preferences = client.app.state.annotation_provider.snapshots[-1].confirmed_preferences
    assert set(preferences) == {
        "buy_intent: I would like to buy this", "warm_lighting: I like warm lighting",
        "needs_clarification: For my reading corner",
    }


def test_context_deleted_during_inference_requeues_without_publishing(client):
    context_id = capture(client, "context-to-remove")
    enrich(client)
    respond(client, context_id, "buy_intent")
    target_id = capture(client, "new-target")
    provider = client.app.state.annotation_provider
    provider.callback = lambda: remove(client, context_id)
    enrich(client)
    assert provider.snapshots[-1].confirmed_preferences == ("buy_intent: I would like to buy this",)
    assert client.get(f"/v1/saves/{target_id}").json()["suggestions"] == []
    with client.app.state.factory.begin() as db:
        pending = next(job for job in db.scalars(select(Job)) if job.payload.get("item_id") == target_id)
        assert pending.status == "pending" and pending.error == "context_changed"
        assert db.get(SavedItem, target_id).status == "pending"
        pending.due_at = 0
    provider.callback = None
    enrich(client)
    assert provider.snapshots[-1].confirmed_preferences == ()
    assert client.get(f"/v1/saves/{target_id}").json()["status"] == "ready"


@pytest.mark.parametrize("revocation", ["delete", "reject"])
def test_published_predictions_retracted_and_regenerated_after_context_revocation(client, revocation):
    unrelated_id = capture(client, "unrelated-before-context")
    enrich(client)
    context_id = capture(client, "confirmed-context")
    enrich(client)
    respond(client, context_id, "buy_intent")
    target_id = capture(client, "dependent-prediction")
    enrich(client)
    before = client.get(f"/v1/saves/{target_id}").json()
    assert before["status"] == "ready" and len(before["suggestions"]) == 3
    with client.app.state.factory() as db:
        evidence_id = db.scalar(select(Evidence.id).where(Evidence.item_id == context_id, Evidence.active.is_(True)))
    assert before["features"]["context_evidence_ids"] == [evidence_id]
    other_user_id = capture(client, "other-user-save", user="sam")
    enrich(client)
    if revocation == "delete":
        remove(client, context_id)
    else:
        respond(client, context_id, "buy_intent", action="reject")
    retracted = client.get(f"/v1/saves/{target_id}").json()
    assert retracted["status"] == "pending"
    assert retracted["features"] == {} and retracted["suggestions"] == []
    assert retracted["revision"] == before["revision"] + 1
    assert client.get(f"/v1/saves/{unrelated_id}").json()["status"] == "ready"
    assert client.get(f"/v1/saves/{other_user_id}", headers={"Authorization": "Bearer sam-token"}).json()["status"] == "ready"
    with client.app.state.factory() as db:
        pending = [job for job in db.scalars(select(Job).where(Job.status == "pending")) if job.payload.get("item_id") == target_id]
        assert len(pending) == 1 and pending[0].payload["revision"] == retracted["revision"]
        assert not db.get(Evidence, evidence_id).active
    enrich(client)
    refreshed = client.get(f"/v1/saves/{target_id}").json()
    assert refreshed["status"] == "ready" and len(refreshed["suggestions"]) == 3
    assert refreshed["features"]["context_evidence_ids"] == []
    assert client.app.state.annotation_provider.snapshots[-1].confirmed_preferences == ()
    # Intent identity survives regeneration so later rejection can retract a
    # prior confirmation; all generated context was still rebuilt above.
    assert {row["id"] for row in refreshed["suggestions"]} == {row["id"] for row in before["suggestions"]}


def test_collection_queries_image_presence_without_loading_private_image_bytes(client):
    item_id = capture(client, "deferred-image", image_data_url=image_data())
    with client.app.state.factory() as db:
        row = db.get(SavedItem, item_id)
        assert "image_data_url" in inspect(row).unloaded
        assert row.has_image is True
        assert "image_data_url" in inspect(row).unloaded
        engine = db.get_bind()
    statements = []
    def record_statement(connection, cursor, statement, parameters, context, executemany):
        statements.append(statement)
    event.listen(engine, "before_cursor_execute", record_statement)
    try:
        response = client.get("/v1/collection")
    finally:
        event.remove(engine, "before_cursor_execute", record_statement)
    assert response.status_code == 200
    assert response.json()["items"][0]["has_image"] is True
    assert "data:image" not in response.text
    saved_item_queries = [sql for sql in statements if sql.lstrip().upper().startswith("SELECT") and "saved_items" in sql]
    assert saved_item_queries
    assert any(re.search(r"saved_items\.image_data_url\s+IS NOT NULL", sql, re.I) for sql in saved_item_queries)
    assert all(not re.search(r"saved_items\.image_data_url(?!\s+IS NOT NULL)", sql, re.I) for sql in saved_item_queries)


@pytest.mark.parametrize("kind,claim", [("intent", "warm_lighting"), ("stage", "buy_intent")])
def test_provider_cannot_mislabel_legacy_claims_as_intents_or_intents_as_legacy(kind, claim):
    with pytest.raises(ValueError, match="invalid_provider_output"):
        validate_annotation({"features": {}, "suggestions": [{"kind": kind, "claim": claim, "text": "Choose this option"}]}, "test-provider")


@pytest.mark.parametrize("intent", ["buy_intent", "track_discount", "remind_later"])
def test_selecting_intent_records_annotation_without_executing_action(client, intent):
    item_id = capture(client, "select-intent")
    enrich(client)
    response = respond(client, item_id, intent).json()
    assert response["intent"] == intent
    assert response["execution_status"] == "annotation_only"
    with client.app.state.factory() as db:
        evidence = list(db.scalars(select(Evidence)))
        assert len(evidence) == 1 and evidence[0].claim == intent and evidence[0].active
        assert db.scalar(select(func.count()).select_from(Watch)) == 0
        assert db.scalar(select(func.count()).select_from(Notification)) == 0
        assert all(job.kind == "enrich" for job in db.scalars(select(Job)))


def test_capabilities_report_actual_provider_and_deferred_integrations(client):
    assert client.get("/health").json()["inference_provider"] == CaptureProvider.version
    assert client.get("/v1/me").json()["inference_provider"] == CaptureProvider.version
    body = client.get("/v1/capabilities").json()
    assert body["data_modes"]["annotations"] == "astra"
    assert body["features"]["image_upload"] and body["features"]["predictive_prompts"]
    assert "image" in body["capture"]["content_types"]
    assert body["capture"]["max_image_bytes"] == 4 * 1024 * 1024
    for feature in ["personal_agent_connector", "reminder_scheduling", "live_price_monitoring", "push_notifications"]:
        assert body["features"][feature] is False


def test_chunked_request_larger_than_six_mib_is_rejected_before_json_parsing(client):
    def chunks():
        for _ in range(7):
            yield b"x" * (1024 * 1024)
    response = client.post("/v1/saves", content=chunks(), headers={
        "Content-Type": "application/json", "Idempotency-Key": uuid4().hex,
    })
    assert response.status_code == 413
    assert response.json()["error"]["code"] == "request_too_large"
    assert response.json()["error"]["retryable"] is False
    assert response.headers["x-request-id"] == response.json()["error"]["request_id"]
    with client.app.state.factory() as db:
        assert db.scalar(select(func.count()).select_from(SavedItem)) == 0
