"""Durable multimodal journeys and failure paths without live provider calls."""
import base64
from copy import deepcopy
from io import BytesIO
import json
from pathlib import Path
import time
from uuid import uuid4
import wave

from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from PIL import Image
from PIL.PngImagePlugin import PngInfo
import pytest
from sqlalchemy import inspect, select

from backend.app import multimodal as module
from backend.app.catalog.service import import_dataset
from backend.app.db import Job, MultimodalAsset, MultimodalCapture, Mutation, SavedItem, Suggestion, UserEvent, make_database
from backend.app.intelligence import DemoAnnotationProvider
from backend.app.main import create_app
from backend.app.multimodal import MultimodalService
from backend.app.predictive import ProviderError
from backend.app.worker import run_once


ROOT = Path(__file__).resolve().parents[2]
TOKENS = {"test-alex-token": "alex", "test-sam-token": "sam"}


def png(color="red", *, metadata=False):
    stream = BytesIO()
    info = PngInfo()
    if metadata:
        info.add_text("private-location", "must-not-survive-normalization")
    Image.new("RGB", (16, 16), color).save(stream, "PNG", pnginfo=info)
    return stream.getvalue()


def wav():
    stream = BytesIO()
    with wave.open(stream, "wb") as recording:
        recording.setnchannels(1)
        recording.setsampwidth(2)
        recording.setframerate(16000)
        recording.writeframes(bytes(16000 * 2))
    return stream.getvalue()


def output(snapshot):
    evidence = f"[{snapshot.images[0][0]}] Rectangular face" if snapshot.images else snapshot.title or snapshot.note or snapshot.transcripts[0][1]
    basis = "image" if snapshot.images else "captured_text"
    intent = [part.strip() for text in [snapshot.note, *(text for _, text in snapshot.transcripts)]
              for part in text.splitlines() if part.strip()]
    return {
        "analysis": {"schema_version": 1, "summary": "A rectangular digital wristwatch.",
            "products": [{"product_type": "Digital wristwatch", "category_path": ["Accessories", "Watches", "Digital watches"],
                "brand": None, "model": None,
                "attributes": [{"name": "shape", "value": "Rectangular", "basis": basis, "evidence": evidence, "certainty": "observed"}],
                "use_cases": ["Everyday wear"], "search_terms": ["digital wristwatch"]}],
            "intent_context": intent[:8], "uncertainties": ["Exact brand and model are unknown."]},
        "preview": {"product_name": "Digital wristwatch", "category_path": ["Accessories", "Watches", "Digital watches"],
            "brand": None, "style": ["Rectangular"], "summary": "A rectangular digital wristwatch.",
            "uncertainties": ["Exact brand and model are unknown."],
            "prompts": [
                {"id": "p1", "text": "I like the rectangular watch face.", "question": "Does the rectangular face appeal to you?"},
                {"id": "p2", "text": "I want a watch for everyday wear.", "question": "Would you wear it every day?"},
                {"id": "p3", "text": "I am considering this as a gift.", "question": "Could this be a gift?"}],
            "evidence": [evidence], "schema_version": 2, "analyzed_at": int(time.time())},
        "source_assets": [identifier for identifier, _ in (*snapshot.images, *snapshot.transcripts)],
    }


class FakeMultimodal:
    version = "gpt-6-astra:multimodal-test"
    model = "gpt-6-astra"
    transcription_model = "gpt-transcribe"

    def __init__(self):
        self.snapshots = []
        self.recordings = []
        self.callback = None
        self.transcription_callback = None
        self.failure = None
        self.transcript = "I want a leather strap for Dad."
        self.summary_overrides = []

    def analyze(self, snapshot):
        self.snapshots.append(snapshot)
        result = output(snapshot)
        if len(self.snapshots) <= len(self.summary_overrides):
            result["analysis"]["summary"] = self.summary_overrides[len(self.snapshots) - 1]
        if self.callback:
            self.callback(snapshot)
        if self.failure:
            raise self.failure
        return result

    def transcribe(self, raw, media_type):
        self.recordings.append((raw, media_type))
        if self.transcription_callback:
            self.transcription_callback()
        if self.failure:
            raise self.failure
        return self.transcript


@pytest.fixture
def client(tmp_path):
    provider = FakeMultimodal()
    app = create_app(f"sqlite:///{tmp_path / 'multimodal.db'}", embedded_worker=False,
        annotation_provider=DemoAnnotationProvider(), multimodal_provider=provider,
        tokens=TOKENS, demo_mode=False, allowed_origins=[])
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer test-alex-token"
        yield client


def request(client, method, path, body=None, *, key=None, user="alex"):
    return client.request(method, path, json=body, headers={
        "Authorization": f"Bearer test-{user}-token", "Idempotency-Key": key or uuid4().hex})


def create(api, *, key=None, user="alex", **fields):
    response = request(api, "POST", "/v1/multimodal/captures", {"title": "Digital watch", **fields}, key=key, user=user)
    assert response.status_code == 201, response.text
    return response.json()


def view(client, capture, *, user="alex"):
    response = client.get(f"/v1/multimodal/captures/{capture['id']}", headers={"Authorization": f"Bearer test-{user}-token"})
    assert response.status_code == 200, response.text
    return response.json()


def upload(client, capture, raw=None, mime="image/png", **kwargs):
    response = request(client, "POST", f"/v1/multimodal/captures/{capture['id']}/assets",
        {"revision": capture["revision"], "media_type": mime, "data_base64": base64.b64encode(png() if raw is None else raw).decode()}, **kwargs)
    assert response.status_code == 200, response.text
    return response.json()


def analyze(client, capture, **kwargs):
    response = request(client, "POST", f"/v1/multimodal/captures/{capture['id']}/analyze", {"revision": capture["revision"]}, **kwargs)
    assert response.status_code == 200, response.text
    return response.json()


def tick(client):
    return run_once(client.app.state.factory, client.app.state.annotation_provider, client.app.state.multimodal)


def ready(client, *, images=1, audio=False, **fields):
    capture = create(client, **fields)
    for color in ["red", "blue", "green", "yellow"][:images]:
        capture = upload(client, capture, png(color))
    if audio:
        capture = upload(client, capture, wav(), "audio/wav")
    capture = analyze(client, capture)
    for _ in range(3):
        if not tick(client):
            break
    capture = view(client, capture)
    assert capture["status"] == "ready", capture
    return capture


def publish(client, capture, *, key=None):
    response = request(client, "POST", f"/v1/multimodal/captures/{capture['id']}/publish", {"revision": capture["revision"]}, key=key)
    assert response.status_code == 200, response.text
    return response.json()


def test_durable_save_separate_transcription_and_analysis_jobs(client):
    capture = create(client, note="It is a gift.", client="ios_app")
    assert capture["status"] == "pending" and capture["stage"] == "draft"
    capture = upload(client, capture, png("red"))
    capture = upload(client, capture, png("blue"))
    capture = upload(client, capture, wav(), "audio/wav")
    capture = analyze(client, capture)
    assert capture["stage"] == "transcribing" and capture["status"] == "pending"
    provider = client.app.state.multimodal.provider
    assert provider.recordings == provider.snapshots == []
    assert tick(client)
    intermediate = view(client, capture)
    assert intermediate["stage"] == "analyzing" and intermediate["status"] == "pending"
    assert len(provider.recordings) == 1 and provider.snapshots == []
    assert next(a for a in intermediate["assets"] if a["kind"] == "audio")["transcript"] == provider.transcript
    assert tick(client)
    final = view(client, capture)
    assert final["status"] == final["stage"] == "ready"
    assert len(provider.snapshots) == 1
    snapshot = provider.snapshots[0]
    assert len(snapshot.images) == 2
    assert snapshot.note == "It is a gift."
    assert snapshot.transcripts[0][1] == provider.transcript
    assert final["result"]["source_assets"] == [identifier for identifier, _ in (*snapshot.images, *snapshot.transcripts)]
    assert final["result"]["preview"]["schema_version"] == 2
    assert client.get("/v1/collection").json()["items"] == []
    assert not tick(client)
    with client.app.state.factory() as db:
        jobs = db.scalars(select(Job).order_by(Job.due_at)).all()
        assert [job.kind for job in jobs] == ["multimodal_transcribe", "multimodal_analyze"]
        assert all(job.status == "done" and job.attempts == 1 for job in jobs)


def test_text_only_capture_and_unchanged_analyze_are_supported(client):
    capture = create(client, note="I need a watch for travel.")
    first = analyze(client, capture)
    second = analyze(client, capture)
    assert first["revision"] == second["revision"] == capture["revision"]
    assert tick(client)
    final = view(client, capture)
    assert final["status"] == "ready" and final["assets"] == []
    assert final["result"]["analysis"]["intent_context"] == ["I need a watch for travel."]
    assert not tick(client)


def test_retry_identity_replays_receipt_and_conflicts_for_different_content(client):
    key = uuid4().hex
    capture = create(client, key=key, note="original")
    assert create(client, key=key, note="original") == capture
    response = request(client, "POST", "/v1/multimodal/captures", {"title": "Digital watch", "note": "changed"}, key=key)
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "idempotency_conflict"
    upload_key = uuid4().hex
    uploaded = upload(client, capture, key=upload_key)
    assert upload(client, capture, key=upload_key) == uploaded
    assert len(view(client, capture)["assets"]) == 1


def test_stale_revision_cannot_edit_upload_or_analyze(client):
    old = create(client)
    current = upload(client, old)
    paths = [
        ("PATCH", "", {"revision": old["revision"], "note": "stale"}),
        ("POST", "/analyze", {"revision": old["revision"]}),
        ("POST", "/assets", {"revision": old["revision"], "media_type": "image/png", "data_base64": base64.b64encode(png("blue")).decode()}),
    ]
    for method, suffix, body in paths:
        response = request(client, method, f"/v1/multimodal/captures/{old['id']}{suffix}", body)
        assert response.status_code == 409
        assert response.json()["error"]["code"] == "capture_revision_conflict"
    assert view(client, old) == current


def test_provider_has_no_open_database_connection_and_edit_discards_old_output(client):
    capture = analyze(client, create(client, note="Old note"))
    factory = client.app.state.factory
    provider = client.app.state.multimodal.provider

    def edit_during_analysis(snapshot):
        assert factory.kw["bind"].pool.checkedout() == 0
        assert snapshot.note == "Old note"
        response = request(client, "PATCH", f"/v1/multimodal/captures/{capture['id']}",
            {"revision": capture["revision"], "note": "New note"})
        assert response.status_code == 200, response.text
    provider.callback = edit_during_analysis
    assert tick(client)
    changed = view(client, capture)
    assert changed["note"] == "New note"
    assert changed["result"] is None and changed["stage"] == "draft"
    provider.callback = None
    analyze(client, changed)
    assert tick(client)
    assert view(client, capture)["result"]["analysis"]["intent_context"] == ["New note"]


def test_delete_during_analysis_cannot_resurrect_capture(client):
    capture = analyze(client, upload(client, create(client)))
    def remove(_):
        response = request(client, "DELETE", f"/v1/multimodal/captures/{capture['id']}")
        assert response.status_code == 200
    client.app.state.multimodal.provider.callback = remove
    assert tick(client)
    assert client.get(f"/v1/multimodal/captures/{capture['id']}").status_code == 404
    with client.app.state.factory() as db:
        deleted = db.get(MultimodalCapture, capture["id"])
        assert deleted.deleted and deleted.result is None and deleted.note == ""
        assert db.scalars(select(MultimodalAsset)).all() == []
        assert all(job.status == "done" for job in db.scalars(select(Job)))


def test_remove_audio_while_transcribing_discards_result_and_does_not_queue_analysis(client):
    capture = analyze(client, upload(client, create(client), wav(), "audio/wav"))
    asset_id = capture["assets"][0]["id"]
    def remove_audio():
        response = request(client, "DELETE", f"/v1/multimodal/captures/{capture['id']}/assets/{asset_id}",
            {"revision": capture["revision"]})
        assert response.status_code == 200, response.text
    client.app.state.multimodal.provider.transcription_callback = remove_audio
    assert tick(client)
    final = view(client, capture)
    assert final["assets"] == [] and final["stage"] == "draft"
    assert final["result"] is None
    assert not tick(client)


def test_user_transcript_edit_wins_over_inflight_transcription_and_is_reused(client):
    capture = analyze(client, upload(client, create(client), wav(), "audio/wav"))
    asset_id = capture["assets"][0]["id"]
    provider = client.app.state.multimodal.provider
    edited = []

    def correct_transcript():
        response = request(client, "PATCH", f"/v1/multimodal/captures/{capture['id']}/assets/{asset_id}",
            {"revision": capture["revision"], "transcript": "  I want\na blue strap.  "})
        assert response.status_code == 200, response.text
        edited.append(response.json())
    provider.transcription_callback = correct_transcript
    assert tick(client)
    corrected = view(client, capture)
    assert corrected["stage"] == "draft" and corrected["result"] is None
    assert corrected["assets"][0]["transcript"] == "I want a blue strap."
    assert corrected["assets"][0]["transcript_origin"] == "user"
    assert corrected["revision"] == capture["revision"] + 1
    assert analyze(client, corrected)["stage"] == "analyzing"
    assert tick(client)
    assert len(provider.recordings) == 1
    assert provider.snapshots[-1].transcripts == ((asset_id, "I want a blue strap."),)
    assert view(client, capture)["result"]["analysis"]["intent_context"] == ["I want a blue strap."]


def test_transcript_edits_are_audio_only_owned_and_revision_checked(client):
    capture = upload(client, create(client))
    image_id = capture["assets"][0]["id"]
    response = request(client, "PATCH", f"/v1/multimodal/captures/{capture['id']}/assets/{image_id}",
        {"revision": capture["revision"], "transcript": "Not an audio attachment"})
    assert response.status_code == 422 and response.json()["error"]["code"] == "not_audio"
    capture = upload(client, capture, wav(), "audio/wav")
    audio_id = next(a["id"] for a in capture["assets"] if a["kind"] == "audio")
    path = f"/v1/multimodal/captures/{capture['id']}/assets/{audio_id}"
    assert request(client, "PATCH", path, {"revision": capture["revision"], "transcript": " "}).status_code == 422
    assert request(client, "PATCH", path, {"revision": capture["revision"] - 1, "transcript": "Stale"}).status_code == 409
    assert request(client, "PATCH", path, {"revision": capture["revision"], "transcript": "Other user"}, user="sam").status_code == 404
    key = uuid4().hex
    body = {"revision": capture["revision"], "transcript": "A corrected note"}
    first = request(client, "PATCH", path, body, key=key)
    assert first.status_code == 200
    assert request(client, "PATCH", path, body, key=key).json() == first.json()


def test_expired_lease_can_be_reclaimed_without_old_result_publication(client):
    capture = analyze(client, create(client))
    factory = client.app.state.factory
    provider = client.app.state.multimodal.provider
    provider.summary_overrides = ["Obsolete first analysis.", "Current second analysis."]

    def expire_then_reclaim(_):
        provider.callback = None
        with factory.begin() as db:
            job = db.scalar(select(Job).where(Job.status == "running"))
            job.lease_until = time.time() - 1
        assert tick(client)
    provider.callback = expire_then_reclaim
    assert tick(client)
    final = view(client, capture)
    assert final["result"]["analysis"]["summary"] == "Current second analysis."
    assert len(provider.snapshots) == 2
    with factory() as db:
        jobs = db.scalars(select(Job)).all()
        assert len(jobs) == 1 and jobs[0].attempts == 2 and jobs[0].status == "done"


def test_expired_transcription_does_not_persist_text_or_enqueue_duplicate_analysis(client):
    capture = analyze(client, upload(client, create(client), wav(), "audio/wav"))
    provider = client.app.state.multimodal.provider
    factory = client.app.state.factory

    def expire():
        with factory.begin() as db:
            job = db.scalar(select(Job).where(Job.status == "running"))
            job.lease_until = time.time() - 1
    provider.transcription_callback = expire
    assert tick(client)
    midway = view(client, capture)
    assert midway["assets"][0]["transcript"] is None
    with factory() as db:
        assert [job.kind for job in db.scalars(select(Job))] == ["multimodal_transcribe"]
    provider.transcription_callback = None
    assert tick(client)
    assert tick(client)
    assert view(client, capture)["status"] == "ready"
    with factory() as db:
        jobs = db.scalars(select(Job).where(Job.kind == "multimodal_analyze")).all()
        assert len(jobs) == 1 and jobs[0].status == "done"


def test_unexpected_provider_exception_does_not_expose_private_error_text(client):
    capture = analyze(client, create(client))
    client.app.state.multimodal.provider.failure = RuntimeError("private phrase and provider credentials")
    assert tick(client)
    final = view(client, capture)
    assert final["status"] == "enrichment_failed"
    assert final["error_code"] == "multimodal_invalid_output"
    assert "private phrase" not in json.dumps(final)
    with client.app.state.factory() as db:
        assert db.scalar(select(Job)).error == "multimodal_invalid_output"


@pytest.mark.parametrize("audio", [False, True])
@pytest.mark.parametrize("retryable,code,attempts", [(True, "multimodal_rate_limited", 3), (False, "multimodal_authentication_failed", 1)])
def test_retryable_failures_are_bounded_and_terminal_errors_stay_visible(client, audio, retryable, code, attempts):
    capture = create(client)
    if audio:
        capture = upload(client, capture, wav(), "audio/wav")
    analyze(client, capture)
    provider = client.app.state.multimodal.provider
    provider.failure = ProviderError(code, retryable)
    for index in range(attempts):
        assert tick(client)
        with client.app.state.factory.begin() as db:
            job = db.scalar(select(Job))
            assert job.attempts == index + 1
            if index < attempts - 1:
                assert job.status == "pending"
                job.due_at = 0
            else:
                assert job.status == "failed"
    final = view(client, capture)
    assert final["status"] == "enrichment_failed" and final["stage"] == "failed"
    assert final["error_code"] == code and final["result"] is None
    assert final["title"] == "Digital watch"
    assert not tick(client)
    provider.failure = None
    analyze(client, final)
    assert tick(client)
    if audio:
        assert tick(client)
    assert view(client, capture)["status"] == "ready"


def test_ownership_authentication_and_private_asset_download(client):
    capture = upload(client, create(client, note="private note"))
    path = f"/v1/multimodal/captures/{capture['id']}"
    asset_path = path + "/assets/" + capture["assets"][0]["id"]
    assert client.get(path, headers={"Authorization": "Bearer invalid"}).status_code == 401
    for suffix in ("", "/assets/" + capture["assets"][0]["id"]):
        response = client.get(path + suffix, headers={"Authorization": "Bearer test-sam-token"})
        assert response.status_code == 404 and "private note" not in response.text
    response = request(client, "PATCH", path, {"revision": capture["revision"], "note": "hijack"}, user="sam")
    assert response.status_code == 404
    response = request(client, "POST", path + "/analyze", {"revision": capture["revision"]}, user="sam")
    assert response.status_code == 404
    downloaded = client.get(asset_path)
    assert downloaded.status_code == 200
    assert downloaded.headers["cache-control"] == "no-store"
    assert downloaded.headers["content-disposition"] == "attachment"
    assert "data_base64" not in json.dumps(view(client, capture))


def test_images_are_normalized_metadata_removed_and_deduplicated(client):
    capture = upload(client, create(client), png(metadata=True))
    asset = capture["assets"][0]
    downloaded = client.get(f"/v1/multimodal/captures/{capture['id']}/assets/{asset['id']}")
    assert b"must-not-survive-normalization" not in downloaded.content
    with Image.open(BytesIO(downloaded.content)) as image:
        assert "private-location" not in image.info
    duplicate = upload(client, capture, png(metadata=False))
    assert duplicate["revision"] == capture["revision"] and len(duplicate["assets"]) == 1
    with client.app.state.factory() as db:
        assert all("data_base64" not in json.dumps(m.response) for m in db.scalars(select(Mutation)))


@pytest.mark.parametrize("mime,data", [("image/png", b"invalid"), ("image/jpeg", png()),
    ("audio/wav", b"RIFFinvalid"), ("audio/webm", b"webm")])
def test_invalid_uploads_do_not_change_capture(client, mime, data):
    capture = create(client)
    response = request(client, "POST", f"/v1/multimodal/captures/{capture['id']}/assets",
        {"revision": capture["revision"], "media_type": mime, "data_base64": base64.b64encode(data).decode()})
    assert response.status_code == 422
    assert view(client, capture) == capture


def test_attachment_count_and_storage_quotas_are_per_owner(client, monkeypatch):
    capture = create(client)
    for color in ("red", "green", "blue", "yellow"):
        capture = upload(client, capture, png(color))
    response = request(client, "POST", f"/v1/multimodal/captures/{capture['id']}/assets",
        {"revision": capture["revision"], "media_type": "image/png", "data_base64": base64.b64encode(png("purple")).decode()})
    assert response.status_code == 422 and response.json()["error"]["code"] == "asset_limit"
    monkeypatch.setattr(module, "MAX_USER_CAPTURES", 1)
    response = request(client, "POST", "/v1/multimodal/captures", {"title": "Another watch"})
    assert response.status_code == 429
    sam = create(client, user="sam")
    monkeypatch.setattr(module, "MAX_USER_BYTES", 1)
    response = request(client, "POST", f"/v1/multimodal/captures/{sam['id']}/assets",
        {"revision": sam["revision"], "media_type": "image/png", "data_base64": base64.b64encode(png()).decode()}, user="sam")
    assert response.status_code == 429
    assert view(client, sam, user="sam")["assets"] == []


def test_capture_storage_quota_rejects_without_partial_asset(client, monkeypatch):
    capture = upload(client, create(client))
    monkeypatch.setattr(module, "MAX_CAPTURE_BYTES", capture["assets"][0]["size_bytes"])
    response = request(client, "POST", f"/v1/multimodal/captures/{capture['id']}/assets",
        {"revision": capture["revision"], "media_type": "image/png", "data_base64": base64.b64encode(png("blue")).decode()})
    assert response.status_code == 429
    assert view(client, capture) == capture


def test_analysis_rate_limits_are_per_user_and_duplicate_start_does_not_consume_allowance(client, monkeypatch):
    monkeypatch.setattr(module, "ANALYSES_PER_MINUTE", 1)
    first = create(client)
    analyze(client, first)
    analyze(client, first)
    second = create(client)
    response = request(client, "POST", f"/v1/multimodal/captures/{second['id']}/analyze", {"revision": second["revision"]})
    assert response.status_code == 429 and response.json()["error"]["code"] == "multimodal_rate_limited"
    assert view(client, second)["stage"] == "draft"
    other = create(client, user="sam")
    analyze(client, other, user="sam")
    with client.app.state.factory() as db:
        events = db.scalars(select(UserEvent).where(UserEvent.event_type == "multimodal_analysis_requested")).all()
        assert sorted(event.user_id for event in events) == ["alex", "sam"]


@pytest.mark.parametrize("limit", ["daily", "queue"])
def test_daily_and_queued_job_limits_fail_without_partial_enqueue(client, monkeypatch, limit):
    capture = create(client)
    if limit == "daily":
        monkeypatch.setattr(module, "ANALYSES_PER_DAY", 1)
        with client.app.state.factory.begin() as db:
            db.add(UserEvent(user_id="alex", event_type="multimodal_analysis_requested", payload={}, occurred_at=time.time() - 120))
    else:
        monkeypatch.setattr(module, "MAX_QUEUED_PER_USER", 1)
        analyze(client, create(client))
    with client.app.state.factory() as db:
        before = len(db.scalars(select(Job)).all())
    response = request(client, "POST", f"/v1/multimodal/captures/{capture['id']}/analyze", {"revision": capture["revision"]})
    assert response.status_code == 429
    assert view(client, capture)["stage"] == "draft"
    with client.app.state.factory() as db:
        assert len(db.scalars(select(Job)).all()) == before


def test_delete_scrubs_assets_results_and_invalidates_cached_mutations(client):
    key = uuid4().hex
    capture = create(client, key=key, note="private note")
    capture = upload(client, capture)
    deletion_key = uuid4().hex
    response = request(client, "DELETE", f"/v1/multimodal/captures/{capture['id']}", key=deletion_key)
    assert response.status_code == 200
    assert request(client, "DELETE", f"/v1/multimodal/captures/{capture['id']}", key=deletion_key).json() == {"deleted": True}
    replay = request(client, "POST", "/v1/multimodal/captures", {"title": "Digital watch", "note": "private note"}, key=key)
    assert replay.status_code == 410 and replay.json()["error"]["code"] == "mutation_expired"
    with client.app.state.factory() as db:
        assert db.scalars(select(MultimodalAsset)).all() == []
        tombstone = db.get(MultimodalCapture, capture["id"])
        assert tombstone.deleted and tombstone.result is None and tombstone.note == ""
        assert all("private note" not in json.dumps(m.response) for m in db.scalars(select(Mutation)))


def test_oversized_delete_body_is_rejected_before_mutating_assets(client):
    capture = upload(client, create(client))
    response = client.request("DELETE", f"/v1/multimodal/captures/{capture['id']}",
        content=b"x" * (6 * 1024 * 1024 + 1), headers={"Idempotency-Key": uuid4().hex})
    assert response.status_code == 413 and response.json()["error"]["code"] == "request_too_large"
    assert view(client, capture) == capture


def test_explicit_publish_preserves_analysis_search_citations_and_annotation_only_intent(client):
    capture = ready(client, audio=True, note="It is a gift.")
    assert client.get("/v1/collection").json()["items"] == []
    receipt = publish(client, capture)
    save_id = receipt["id"]
    assert receipt["status"] == "ready" and receipt["duplicate"] is False
    saved = client.get(f"/v1/saves/{save_id}").json()
    assert saved["analysis"] == capture["result"]["analysis"]
    assert saved["has_image"] and saved["analysis_status"] == "ready"
    assert client.get("/v1/library/search", params={"q": "rectangular digital"}).json()["items"][0]["id"] == save_id
    assert client.get("/v1/library/search", params={"q": "leather Dad"}).json()["items"][0]["id"] == save_id
    original_ids = [suggestion["id"] for suggestion in saved["suggestions"]]
    assert len(set(original_ids)) == 3
    assert publish(client, capture) == {"id": save_id, "status": "ready", "duplicate": True}
    assert [s["id"] for s in client.get(f"/v1/saves/{save_id}").json()["suggestions"]] == original_ids
    selection = request(client, "POST", f"/v1/saves/{save_id}/responses",
        {"action": "select", "suggestion_id": original_ids[0]})
    assert selection.status_code == 200
    assert selection.json()["execution_status"] == "annotation_only"
    assert selection.json()["analysis_job_id"]
    assert tick(client)

    record = {"source_id": "abo", "source_record_id": "digital", "data_kind": "open_dataset",
        "title": "Rectangular digital wristwatch", "category": "Accessories > Watches > Digital watches",
        "brand": None, "description": "A rectangular digital wristwatch.", "attributes": {"shape": "Rectangular"},
        "merchant": {"id": None, "name": None, "platform": "abo"}, "offer": {"id": "digital", "environment": "local"},
        "provenance": {"source_url": "https://catalog.example.org/digital"}}
    import_dataset(client.app.state.factory, "abo", [record], version="test", checksum="a" * 64)
    explore = client.get("/v1/explore", params={"source": "abo"})
    assert explore.status_code == 200, explore.text
    items = explore.json()["items"]
    assert items and items[0]["product"]["source_record_id"] == "digital"
    assert items[0]["product"]["offer"]["price_minor"] is None
    assert all(reason["saved_item_id"] == save_id for reason in items[0]["reasons"])
    assert items[0]["catalog_citation"]["record_id"] == "digital"


def test_shared_library_deletion_erases_linked_multimodal_assets_and_results(client):
    capture = ready(client, audio=True)
    receipt = publish(client, capture)
    assert request(client, "DELETE", f"/v1/multimodal/captures/{capture['id']}").status_code == 409
    response = request(client, "DELETE", f"/v1/saves/{receipt['id']}")
    assert response.status_code == 200
    assert client.get(f"/v1/multimodal/captures/{capture['id']}").status_code == 404
    assert client.get("/v1/library/search", params={"q": "watch"}).json()["items"] == []
    with client.app.state.factory() as db:
        assert db.scalars(select(MultimodalAsset)).all() == []
        assert db.get(MultimodalCapture, capture["id"]).result is None
        assert db.get(SavedItem, receipt["id"]).image_data_url is None
        assert db.scalars(select(Suggestion)).all() == []


def test_shared_annotation_refinement_retains_all_media_and_stable_prompt_ids(client):
    # A media save uses the multimodal provider even if legacy inference is fallback.
    assert not getattr(client.app.state.annotation_provider, "supports_product_analysis", False)
    capture = ready(client, images=2, audio=True, note="It is a gift.")
    receipt = publish(client, capture)
    save_id = receipt["id"]
    saved = client.get(f"/v1/saves/{save_id}").json()
    original_ids = {s["claim"]: s["id"] for s in saved["suggestions"]}
    response = request(client, "POST", f"/v1/saves/{save_id}/responses",
        {"action": "select", "suggestion_id": original_ids["buy_intent"]})
    assert response.status_code == 200 and response.json()["analysis_job_id"]
    assert response.json()["execution_status"] == "annotation_only"
    assert tick(client)
    provider = client.app.state.multimodal.provider
    assert len(provider.snapshots) == 2 and len(provider.recordings) == 1
    assert provider.snapshots[-1].images == provider.snapshots[0].images
    assert provider.snapshots[-1].transcripts == provider.snapshots[0].transcripts
    assert "I would like to buy this" in provider.snapshots[-1].note
    refreshed = client.get(f"/v1/saves/{save_id}").json()
    assert refreshed["status"] == "ready" and refreshed["analysis_status"] == "ready"
    assert "I would like to buy this" in refreshed["analysis"]["intent_context"]
    assert {s["claim"]: s["id"] for s in refreshed["suggestions"]} == original_ids


@pytest.mark.parametrize("reason,status", [("quota", 429), ("disabled", 503)])
def test_shared_reanalysis_obeys_multimodal_limits_without_losing_user_annotations(client, monkeypatch, reason, status):
    capture = ready(client)
    save_id = publish(client, capture)["id"]
    before = client.get(f"/v1/saves/{save_id}").json()
    if reason == "quota":
        monkeypatch.setattr(module, "ANALYSES_PER_MINUTE", 1)
    else:
        client.app.state.multimodal.enabled = False
    response = request(client, "POST", f"/v1/saves/{save_id}/analyze", {})
    assert response.status_code == status
    unchanged = client.get(f"/v1/saves/{save_id}").json()
    assert unchanged["analysis"] == before["analysis"] and unchanged["revision"] == before["revision"]
    suggestion = next(s for s in before["suggestions"] if s["claim"] == "buy_intent")
    response = request(client, "POST", f"/v1/saves/{save_id}/responses",
        {"action": "select", "suggestion_id": suggestion["id"]})
    assert response.status_code == 200, response.text
    assert response.json()["execution_status"] == "annotation_only" and response.json()["analysis_job_id"] is None
    changed = client.get(f"/v1/saves/{save_id}").json()
    assert changed["status"] == "enrichment_failed" and changed["analysis"] is None
    assert changed["title"] == before["title"] and changed["has_image"]
    assert any(row["payload"].get("suggestion_id") == suggestion["id"] for row in changed["responses"])
    with client.app.state.factory() as db:
        assert all(job.status == "done" for job in db.scalars(select(Job)))


def test_explicit_shared_reanalysis_uses_multimodal_provider_and_deletion_discards_it(client):
    capture = ready(client, images=2, audio=True)
    receipt = publish(client, capture)
    save_id = receipt["id"]
    response = request(client, "POST", f"/v1/saves/{save_id}/analyze", {})
    assert response.status_code == 202
    def delete_during_refinement(_):
        response = request(client, "DELETE", f"/v1/saves/{save_id}")
        assert response.status_code == 200
    provider = client.app.state.multimodal.provider
    provider.callback = delete_during_refinement
    assert tick(client)
    assert len(provider.snapshots) == 2 and len(provider.snapshots[-1].images) == 2
    assert client.get(f"/v1/saves/{save_id}").status_code == 404
    assert client.get(f"/v1/multimodal/captures/{capture['id']}").status_code == 404
    with client.app.state.factory() as db:
        assert db.scalars(select(MultimodalAsset)).all() == []
        assert db.get(SavedItem, save_id).features == {}


def test_published_capture_cannot_be_silently_edited(client):
    capture = ready(client)
    publish(client, capture)
    for suffix, method, body in [("", "PATCH", {"revision": capture["revision"], "note": "changed"}),
                                 ("/analyze", "POST", {"revision": capture["revision"]})]:
        response = request(client, method, f"/v1/multimodal/captures/{capture['id']}{suffix}", body)
        assert response.status_code == 409 and response.json()["error"]["code"] == "capture_published"


def test_disabled_feature_preserves_existing_capture_and_leaves_media_jobs_queued(tmp_path):
    provider = FakeMultimodal()
    app = create_app(f"sqlite:///{tmp_path / 'disabled.db'}", embedded_worker=False,
        annotation_provider=DemoAnnotationProvider(), multimodal_provider=provider, multimodal_enabled=False,
        tokens=TOKENS, demo_mode=False, allowed_origins=[])
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer test-alex-token"
        assert client.get("/v1/multimodal/capabilities").json()["enabled"] is False
        response = request(client, "POST", "/v1/multimodal/captures", {"title": "Digital watch"})
        assert response.status_code == 503 and response.json()["error"]["code"] == "multimodal_disabled"
        legacy = request(client, "POST", "/v1/saves", {"url": "https://example.org/legacy", "title": "Desk lamp"})
        assert legacy.status_code == 201
        assert tick(client)
        assert client.get(f"/v1/saves/{legacy.json()['id']}").json()["status"] == "ready"
        with app.state.factory.begin() as db:
            db.add(Job(user_id="alex", kind="multimodal_analyze", payload={"capture_id": "queued", "revision": 1}))
        assert not tick(client)
        assert provider.snapshots == []


def test_demo_reset_erases_only_requesting_users_multimodal_content(tmp_path):
    app = create_app(f"sqlite:///{tmp_path / 'reset.db'}", embedded_worker=False,
        annotation_provider=DemoAnnotationProvider(), multimodal_provider=FakeMultimodal(),
        tokens=TOKENS, demo_mode=True, allowed_origins=[])
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer test-alex-token"
        alex = upload(client, create(client))
        sam = upload(client, create(client, user="sam"), user="sam")
        response = request(client, "POST", "/v1/demo/reset", {})
        assert response.status_code == 200 and response.json() == {"reset": True}
        assert client.get(f"/v1/multimodal/captures/{alex['id']}").status_code == 404
        assert view(client, sam, user="sam")["assets"]
        with app.state.factory() as db:
            assert {asset.user_id for asset in db.scalars(select(MultimodalAsset))} == {"sam"}


def test_migration_adds_media_tables_without_changing_existing_saves(tmp_path, monkeypatch):
    url = f"sqlite:///{tmp_path / 'upgrade.db'}"
    monkeypatch.setenv("DATABASE_URL", url)
    config = Config(str(ROOT / "alembic.ini"))
    config.set_main_option("script_location", str(ROOT / "backend/migrations"))
    config.set_main_option("sqlalchemy.url", url)
    command.upgrade(config, "a71f92452086")
    engine, factory = make_database(url)
    image = "data:image/png;base64," + base64.b64encode(png()).decode()
    with factory.begin() as db:
        db.add(SavedItem(id="preserved", user_id="alex", original_url="https://example.org/existing", canonical_url="https://example.org/existing",
            title="Existing save", source="web", note="Do not lose this note", image_data_url=image, features={"custom": "unchanged"}))
    command.upgrade(config, "head")
    with factory() as db:
        item = db.get(SavedItem, "preserved")
        assert (item.title, item.note, item.image_data_url, item.features) == ("Existing save", "Do not lose this note", image, {"custom": "unchanged"})
    assert {"multimodal_captures", "multimodal_assets"}.issubset(inspect(engine).get_table_names())
    engine.dispose()
