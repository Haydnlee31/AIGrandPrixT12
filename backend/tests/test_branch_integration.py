"""The two released clients and both migration histories must remain compatible."""
import base64
import hashlib
import io
import json

from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from PIL import Image, PngImagePlugin
import pytest
import sqlalchemy as sa

from backend.app.main import create_app
from backend.app.worker import run_once
from backend.tests.test_predictive_capture import CaptureProvider


def image():
    output = io.BytesIO()
    metadata = PngImagePlugin.PngInfo(); metadata.add_text("note", "Legacy metadata")
    Image.new("RGB", (12, 8), "blue").save(output, format="PNG", pnginfo=metadata)
    return "data:image/png;base64," + base64.b64encode(output.getvalue()).decode()


@pytest.mark.parametrize("start", ["c4d905a137ab", "a71f92452086"])
def test_upgrade_keeps_images_answers_and_uncertain_capture_keys(tmp_path, monkeypatch, start):
    url = f"sqlite:///{tmp_path / 'upgrade.db'}"
    monkeypatch.setenv("DATABASE_URL", url)
    config = Config("alembic.ini")
    command.upgrade(config, start)
    engine = sa.create_engine(url)
    legacy = start == "c4d905a137ab"
    data = image()
    if not legacy:
        from backend.app.media import validate_image_data_url
        data = validate_image_data_url(data)
    payload = {"url": "", "title": "Conversation", "source": "web", "client": "chrome_extension", "selected_text": "", "note": "", "image_data": data} if legacy else {
        "title": "Conversation", "source": "web", "client": "ios_share_extension", "selected_text": "", "note": "", "image_data_url": data}
    fingerprint = hashlib.sha256(json.dumps(["capture", payload], sort_keys=True).encode()).hexdigest()
    receipt = {"id": "kept", "status": "ready", "duplicate": False}
    metadata = sa.MetaData()
    with engine.begin() as db:
        saves = sa.Table("saved_items", metadata, autoload_with=db)
        db.execute(saves.insert().values(id="kept", user_id="owner", original_url="", canonical_url="image:" + hashlib.sha256(base64.b64decode(data.split(',')[1]) if legacy else data.encode()).hexdigest(),
            title="Conversation", source="web", client=payload["client"], selected_text="", content_hash="", note="", captured_at=1, status="ready", features={}, revision=1, deleted=False,
            **({} if legacy else {"image_data_url": data})))
        if legacy:
            media = sa.Table("saved_media", metadata, autoload_with=db)
            db.execute(media.insert().values(item_id="kept", user_id="owner", image_data=data))
        mutations = sa.Table("idempotency_records", metadata, autoload_with=db)
        db.execute(mutations.insert().values(id="mutation", user_id="owner", key="uncertain", fingerprint=fingerprint, response=receipt))
        events = sa.Table("user_events", metadata, autoload_with=db)
        db.execute(events.insert().values(id="answer", user_id="owner", item_id="kept", event_type="annotation_response", payload={"action": "edit", "text": "Plan a visit"}, occurred_at=2))
    command.upgrade(config, "head")
    with engine.connect() as db:
        assert db.execute(sa.text("select version_num from alembic_version")).scalars().all() == ["b82fa3563197"]
        assert db.execute(sa.text("select count(*) from saved_media")).scalar() == 0
    app = create_app(url, embedded_worker=False, tokens={"token": "owner", "other": "other"})
    with TestClient(app, headers={"Authorization": "Bearer token"}) as client:
        saved = client.get("/v1/saves/kept").json()
        assert saved["has_image"] and saved["responses"][0]["payload"]["text"] == "Plan a visit"
        assert client.get("/v1/saves/kept/media").json()["image_data"] == data
        assert client.get("/v1/saves/kept/image").content == base64.b64decode(data.split(',')[1])
        assert client.get("/v1/saves/kept/media", headers={"Authorization": "Bearer other"}).status_code == 404
        retried = client.post("/v1/saves", json=payload, headers={"Idempotency-Key": "uncertain"})
        assert retried.status_code == 201, retried.text
        assert retried.json() == receipt
        duplicate = client.post("/v1/saves", json=payload, headers={"Idempotency-Key": "repeat"})
        assert duplicate.json()["id"] == "kept" and duplicate.json()["duplicate"]
        modern = client.post("/v1/saves", json={"title": "Conversation", "image_data_url": data}, headers={"Idempotency-Key": "modern"})
        assert modern.status_code == 201, modern.text
        assert modern.json()["id"] == "kept" and modern.json()["duplicate"]
        assert len(client.get("/v1/collection").json()["items"]) == 1
    engine.dispose()


def test_multiple_intents_and_individual_retraction_across_clients(tmp_path):
    provider = CaptureProvider()
    app = create_app(f"sqlite:///{tmp_path / 'answers.db'}", embedded_worker=False,
        tokens={"chrome": "owner", "ios": "owner", "other": "other"}, annotation_provider=provider)
    with TestClient(app, headers={"Authorization": "Bearer chrome"}) as client:
        receipt = client.post("/v1/saves", json={"title": "A saved lamp", "image_data": image(), "note": "For my reading corner", "client": "chrome_extension"}, headers={"Idempotency-Key": "save"}).json()
        run_once(app.state.factory, provider)
        path = f"/v1/saves/{receipt['id']}"
        saved = client.get(path).json()
        for index in [0, 1]:
            body = {"action": "select", "suggestion_id": saved["suggestions"][index]["id"]}
            headers = {"Idempotency-Key": f"answer-{index}", "Authorization": "Bearer ios" if index else "Bearer chrome"}
            first = client.post(path + "/responses", json=body, headers=headers)
            assert first.status_code == 200, first.text
            assert client.post(path + "/responses", json=body, headers=headers).json() == first.json()
            assert first.json()["execution_status"] == "annotation_only"
            active = first.json()["hypothesis"]["evidence"]
            assert [e["claim"] for e in active if e["origin"] == "confirmed_annotation"] == [s["claim"] for s in saved["suggestions"][:index+1]]
        shared = client.get(path, headers={"Authorization": "Bearer ios"}).json()
        assert len(shared["responses"]) == 3  # original note plus two distinct answers
        assert shared["responses"][-1]["payload"]["label"] == saved["suggestions"][1]["text"]
        assert "has not started" in shared["responses"][-1]["payload"]["next_step"]
        skipped = client.post(path + "/responses", json={"action": "skip"}, headers={"Idempotency-Key": "skip"}).json()
        assert len([e for e in skipped["hypothesis"]["evidence"] if e["origin"] == "confirmed_annotation"]) == 2
        first_event = next(e for e in shared["responses"] if e["event_type"] == "annotation_response")
        removed = client.post(path + "/responses", json={"action": "reject", "retract_event_id": first_event["id"]}, headers={"Idempotency-Key": "remove-one"})
        assert removed.status_code == 200, removed.text
        assert [e["claim"] for e in removed.json()["hypothesis"]["evidence"] if e["origin"] == "confirmed_annotation"] == ["track_discount"]
        active = [e for e in client.get(path).json()["responses"] if e["event_type"] == "annotation_response" and e["active"]]
        assert len(active) == 1 and active[0]["payload"]["claim"] == "track_discount"
        forbidden = client.post(path + "/responses", json={"action": "reject", "retract_event_id": first_event["id"]}, headers={"Idempotency-Key": "other", "Authorization": "Bearer other"})
        assert forbidden.status_code == 404
        assert client.get("/v1/library/search", params={"q": "reading corner"}).json()["total"] == 1
        assert client.get(path, headers={"Authorization": "Bearer other"}).status_code == 404
