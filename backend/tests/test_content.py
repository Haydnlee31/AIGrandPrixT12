import base64
import io
import json
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from PIL import Image
from sqlalchemy import select

from backend.app.content import OpenAIContentProvider
from backend.app.db import SavedMedia, Job, Evidence
from backend.app.main import create_app
from backend.app.worker import run_once


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("ANNOTATION_PROVIDER", "demo")
    app = create_app(f"sqlite:///{tmp_path}/content.db", embedded_worker=False, tokens={"chrome": "chime", "ios": "chime", "other": "other"})
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
    run_once(client.app.state.factory)
    item = client.get(f"/v1/saves/{item_id}").json()
    assert item["has_image"] and item["status"] == "ready"
    assert item["features"]["data_mode"] == "demo_rules"
    assert "image_data" not in json.dumps(client.get("/v1/collection").json())
    assert client.get(f"/v1/saves/{item_id}/media").json()["image_data"] == data
    assert client.get(f"/v1/saves/{item_id}/media", headers={"Authorization": "Bearer other"}).status_code == 404
    answer = {"action": "select", "suggestion_id": item["suggestions"][1]["id"]}
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


def test_basic_save_can_be_upgraded_to_ai_with_an_explicit_idempotent_retry(client, monkeypatch):
    item_id = post(client, "/saves", {"title": "Screenshot", "image_data": image()}).json()["id"]
    run_once(client.app.state.factory)
    monkeypatch.setenv("ANNOTATION_PROVIDER", "openai")
    monkeypatch.setenv("OPENAI_API_KEY", "test-key")
    calls = mock_model(monkeypatch, interpretation())
    # Provider configuration is selected once at startup in the shared backend.
    restarted_app = create_app(str(client.app.state.factory.kw["bind"].url), embedded_worker=False, tokens={"chrome": "chime"})
    with TestClient(restarted_app, headers={"Authorization": "Bearer chrome"}) as restarted:
        receipt = post(restarted, f"/saves/{item_id}/retry", {}, "upgrade")
        assert receipt.json()["status"] == "pending"
        assert post(restarted, f"/saves/{item_id}/retry", {}, "upgrade").json() == receipt.json()
        run_once(restarted.app.state.factory)
        item = restarted.get(f"/v1/saves/{item_id}").json()
        assert item["features"]["data_mode"] == "openai"
        assert item["features"]["question"] == interpretation()["question"]
        assert len(item["suggestions"]) == 3 and len(calls) == 1
        assert all(s["model_version"].startswith("openai:") for s in item["suggestions"])
        assert restarted.get("/v1/capabilities").json()["features"]["multimodal_ai"]

def test_contextual_answers_keep_multiple_intents_and_skip_preserves_them(client):
    item_id = post(client, "/saves", {"title": "Screenshot", "image_data": image()}).json()["id"]
    run_once(client.app.state.factory)
    item = client.get(f"/v1/saves/{item_id}").json()
    for suggestion in [item["suggestions"][-1], item["suggestions"][1]]:
        assert post(client, f"/saves/{item_id}/responses", {"action": "select", "suggestion_id": suggestion["id"]}).status_code == 200
    with client.app.state.factory() as db:
        active = db.scalars(select(Evidence).where(Evidence.active.is_(True))).all()
        assert {e.claim for e in active} == {"inspiration_only", "needs_clarification"}
    post(client, f"/saves/{item_id}/responses", {"action": "skip"})
    with client.app.state.factory() as db:
        assert len(db.scalars(select(Evidence).where(Evidence.active.is_(True))).all()) == 2


def test_contextual_alternatives_with_same_action_keep_distinct_choices(client, monkeypatch):
    output = interpretation()
    output['options'] = [{'action': 'plan', 'label': 'Visit with a friend'}, {'action': 'plan', 'label': 'Plan a birthday outing'}]
    mock_model(monkeypatch, output)
    item_id = post(client, '/saves', {'title': 'Conversation', 'image_data': image()}).json()['id']
    run_once(client.app.state.factory, OpenAIContentProvider('test'))
    options = client.get(f'/v1/saves/{item_id}').json()['suggestions']
    assert [option['text'] for option in options[:2]] == ['Visit with a friend', 'Plan a birthday outing']
    assert len({option['id'] for option in options}) == 3



def test_legacy_capture_key_cannot_be_reused_to_add_an_image(client):
    import hashlib
    from backend.app.contracts import Capture
    from backend.app.db import Mutation
    body = {"url": "https://example.org/article", "title": "Article"}
    first = post(client, "/saves", body, "old-capture")
    legacy = Capture(**body).model_dump(exclude={"image_data_url"})
    with client.app.state.factory.begin() as db:
        record = db.scalar(select(Mutation).where(Mutation.key == "old-capture"))
        record.fingerprint = hashlib.sha256(json.dumps(["capture", legacy], sort_keys=True).encode()).hexdigest()
    assert post(client, "/saves", body, "old-capture").json() == first.json()
    changed = post(client, "/saves", {**body, "image_data_url": image()}, "old-capture")
    assert changed.status_code == 409
    assert changed.json()["error"]["code"] == "idempotency_conflict"
