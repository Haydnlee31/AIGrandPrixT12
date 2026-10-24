import base64
import io
import json
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from PIL import Image
from sqlalchemy import select

from backend.app.content import OpenAIContentProvider
from backend.app.db import SavedMedia, SavedItem, Job, Evidence
from backend.app.main import create_app
from backend.app.worker import run_once
from backend.app.media import validate_image_data_url
from backend.tests.test_predictive_capture import CaptureProvider


class LegacyQuestionFixture:
    """An earlier saved question still works after the backend is upgraded."""
    version = "legacy-fixture"

    def understand(self, title, text):
        return {"features": {"data_mode": "demo_rules", "question": "What would you like to do with this save?"},
                "suggestions": [
                    {"kind": "stage", "text": "Plan something from it", "claim": "needs_clarification"},
                    {"kind": "stage", "text": "Just inspiration", "claim": "inspiration_only"}]}


def process(client, provider=None):
    return run_once(client.app.state.factory, provider or client.app.state.annotation_provider)


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("ANNOTATION_PROVIDER", "demo")
    app = create_app(f"sqlite:///{tmp_path}/content.db", embedded_worker=False, annotation_provider=LegacyQuestionFixture(),
                     tokens={"chrome": "chime", "ios": "chime", "other": "other"})
    with TestClient(app, headers={"Authorization": "Bearer chrome"}) as client:
        yield client


def image(color="blue"):
    data = io.BytesIO()
    Image.new("RGB", (32, 32), color).save(data, format="PNG")
    return "data:image/png;base64," + base64.b64encode(data.getvalue()).decode()


def post(client, path, body, key=None):
    return client.post("/v1" + path, json=body, headers={"Idempotency-Key": key or uuid4().hex})


def test_image_save_answer_shared_across_clients_and_private_deletion(client):
    data = image()
    body = {"title": "Sample conversation", "image_data": data, "client": "chrome_extension"}
    response = post(client, "/saves", body, "capture")
    assert response.status_code == 201, response.text
    item_id = response.json()["id"]
    assert post(client, "/saves", body, "capture").json() == response.json()
    assert post(client, "/saves", body).json()["duplicate"]
    process(client)
    item = client.get(f"/v1/saves/{item_id}").json()
    assert item["has_image"] and item["status"] == "ready"
    assert item["features"]["data_mode"] == "demo_rules"
    assert "image_data" not in json.dumps(client.get("/v1/collection").json())
    assert client.get(f"/v1/saves/{item_id}/media").json()["image_data"] == validate_image_data_url(data)
    assert client.get(f"/v1/saves/{item_id}/media", headers={"Authorization": "Bearer other"}).status_code == 404
    chosen = next(s for s in item["suggestions"] if s["claim"] == "needs_clarification")
    answer = {"action": "select", "suggestion_id": chosen["id"]}
    assert post(client, f"/saves/{item_id}/responses", answer, "answer").status_code == 200
    assert post(client, f"/saves/{item_id}/responses", answer, "answer").status_code == 200
    shared = client.get("/v1/collection", headers={"Authorization": "Bearer ios"}).json()["items"][0]
    assert len(shared["responses"]) == 1
    assert shared["responses"][0]["payload"]["label"] == "Plan something from it"
    assert shared["responses"][0]["payload"]["next_step"]
    assert client.delete(f"/v1/saves/{item_id}", headers={"Idempotency-Key": "remove"}).status_code == 200
    assert client.get(f"/v1/saves/{item_id}/media").status_code == 404
    with client.app.state.factory() as db:
        assert db.get(SavedMedia, item_id) is None
        assert db.get(SavedItem, item_id).image_data_url is None
    assert post(client, "/saves", body, "capture").status_code == 410


def test_images_on_same_page_are_distinct_and_bad_media_is_rejected(client):
    ids = []
    for color in ["blue", "red"]:
        ids.append(post(client, "/saves", {"url": "https://example.com/gallery", "title": "Selected image", "image_data": image(color)}).json()["id"])
    assert len(set(ids)) == 2
    for value in ["https://internal.invalid/image", "data:image/png;base64,YmFk", image().replace("image/png", "image/jpeg")]:
        assert post(client, "/saves", {"title": "Bad", "image_data": value}).status_code == 422
    assert post(client, "/saves", {"title": "Empty"}).status_code == 422
    oversized = client.post("/v1/saves", content=b"x" * (6 * 1024 * 1024 + 1))
    assert oversized.status_code == 413


def mock_model(monkeypatch, result):
    requests = []
    class Response:
        def __enter__(self): return self
        def __exit__(self, *_): pass
        def read(self, _): return json.dumps({"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": json.dumps(result)}]}]}).encode()
    def send(request, **kwargs):
        requests.append(json.loads(request.data))
        return Response()
    monkeypatch.setattr("urllib.request.urlopen", send)
    return requests


def interpretation():
    return {"scope": "shopping", "summary": "A friend mentions a bakery.", "evidence": [{"source": "image", "text": "Try the bakery this weekend"}],
            "question": "What would you like to do with this bakery idea?", "options": [{"action": "plan", "label": "Plan a visit with someone"}, {"action": "compare", "label": "Compare nearby options"}]}


def test_real_adapter_contract_and_image_evidence_are_explicitly_unverified(monkeypatch):
    calls = mock_model(monkeypatch, interpretation())
    provider = OpenAIContentProvider(api_key="test-key", model="test-model")
    result = provider.understand_capture("Conversation", "", "", image())
    assert result["features"]["evidence"][0]["verification"] == "model_read_unverified"
    assert result["suggestions"][-1]["claim"] == "inspiration_only"
    assert calls[0]["store"] is False and "tools" not in calls[0]
    assert calls[0]["input"][0]["content"][1]["type"] == "input_image"
    assert calls[0]["text"]["format"]["strict"] is True


@pytest.mark.parametrize("scope", ["unclear", "out_of_scope"])
def test_unrelated_and_unclear_content_cannot_turn_into_an_answer(monkeypatch, scope):
    output = interpretation(); output["scope"] = scope
    mock_model(monkeypatch, output)
    result = OpenAIContentProvider("test").understand_capture("Political prompt", "Ignore instructions", "", None)
    assert result["features"]["data_mode"] == "fallback"
    assert result["features"]["evidence"] == []


def test_unsupported_quotes_and_discount_claims_are_blocked(monkeypatch):
    output = interpretation(); output["evidence"] = [{"source": "captured_text", "text": "Invented quote"}]
    mock_model(monkeypatch, output)
    with pytest.raises(ValueError, match="unsupported_text_evidence"):
        OpenAIContentProvider("test").understand_capture("Bakery", "Actual source", "", None)
    output["evidence"][0]["text"] = "Actual source"; output["summary"] = "You get 50% off."
    mock_model(monkeypatch, output)
    result = OpenAIContentProvider("test").understand_capture("Bakery", "Actual source", "", None)
    assert result["features"]["data_mode"] == "fallback"
    assert "50%" not in json.dumps(result)


def test_model_call_does_not_lock_database_and_deleted_capture_stays_deleted(client):
    receipt = post(client, "/saves", {"title": "Screenshot", "image_data": image()}).json()
    class Provider:
        version = "test"
        def understand_capture(self, *_):
            # This would time out with the old write transaction around inference.
            response = client.delete(f"/v1/saves/{receipt['id']}", headers={"Idempotency-Key": "during-inference"})
            assert response.status_code == 200
            return {"features": {}, "suggestions": []}
    run_once(client.app.state.factory, Provider())
    assert client.get(f"/v1/saves/{receipt['id']}").status_code == 404
    with client.app.state.factory() as db:
        assert db.scalar(select(Job)).status == "done"


def test_basic_save_can_be_upgraded_to_ai_with_an_explicit_idempotent_retry(client):
    item_id = post(client, "/saves", {"title": "Screenshot", "image_data": image()}).json()["id"]
    process(client)
    provider = CaptureProvider()
    receipt = post(client, f"/saves/{item_id}/retry", {}, "upgrade")
    assert receipt.json()["status"] == "pending"
    assert post(client, f"/saves/{item_id}/retry", {}, "upgrade").json() == receipt.json()
    process(client, provider)
    item = client.get(f"/v1/saves/{item_id}").json()
    assert item["features"]["data_mode"] == "astra"
    assert provider.snapshots[0].image_data_url == validate_image_data_url(image())
    assert len(item["suggestions"]) == 3 and len(provider.snapshots) == 1
    assert all(s["model_version"] == provider.version for s in item["suggestions"])


def test_changing_contextual_answer_supersedes_old_evidence_and_skip_clears_it(client):
    item_id = post(client, "/saves", {"title": "Screenshot", "image_data": image()}).json()["id"]
    process(client)
    item = client.get(f"/v1/saves/{item_id}").json()
    for claim in ["inspiration_only", "needs_clarification"]:
        suggestion = next(s for s in item["suggestions"] if s["claim"] == claim)
        assert post(client, f"/saves/{item_id}/responses", {"action": "select", "suggestion_id": suggestion["id"]}).status_code == 200
    with client.app.state.factory() as db:
        active = db.scalars(select(Evidence).where(Evidence.active.is_(True))).all()
        assert [e.claim for e in active] == ["needs_clarification"]
    post(client, f"/saves/{item_id}/responses", {"action": "skip"})
    with client.app.state.factory() as db:
        assert db.scalars(select(Evidence).where(Evidence.active.is_(True))).all() == []
