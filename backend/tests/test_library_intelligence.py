"""Real Astra transport contract through capture, refinement, search and Explore."""
import base64
from copy import deepcopy
from io import BytesIO
import json
from uuid import uuid4

from fastapi.testclient import TestClient
import httpx
from PIL import Image
import pytest
from sqlalchemy import func, select

from backend.app.catalog.service import import_dataset
from backend.app.db import Evidence, Job, SavedItem
from backend.app.main import create_app
from backend.app.predictive import AstraAnnotationProvider
from backend.app.worker import run_once


def observed_watch():
    return {"schema_version": 1, "summary": "A vintage digital wristwatch with a Casio label.",
        "products": [{"product_type": "watch", "category_path": ["Accessories", "Watches", "Digital watches"],
            "brand": {"value": "Casio", "basis": "image", "evidence": "Visible Casio label", "certainty": "observed"},
            "model": None,
            "attributes": [{"name": "style", "value": "vintage", "basis": "image", "evidence": "Retro rectangular case", "certainty": "inferred"},
                           {"name": "display_type", "value": "digital", "basis": "image", "evidence": "LCD digits", "certainty": "observed"}],
            "use_cases": ["Timekeeping"], "search_terms": ["retro wristwatch", "腕時計"]}],
        "intent_context": [], "uncertainties": ["Exact model unknown"]}


@pytest.fixture
def api(tmp_path):
    state = {"calls": [], "error_status": None}

    def request(request):
        payload = json.loads(request.content)
        captured = json.loads(payload["input"][0]["content"][0]["text"])
        state["calls"].append(captured)
        if state["error_status"]:
            return httpx.Response(state["error_status"], json={"error": {"message": "Private remote error"}})
        analysis = observed_watch()
        analysis["intent_context"] = list(captured["confirmed_annotations"][:3])
        output = {"subject": "A digital wristwatch", "content_kind": "product",
            "visual_attributes": ["rectangular face", "digital display"], "analysis": analysis,
            "actions": ["buy_intent", "track_discount", "remind_later", "save_inspiration"]}
        return httpx.Response(200, json={"status": "completed", "output": [{"type": "message",
            "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": json.dumps(output)}]}]})

    provider = AstraAnnotationProvider("test-only-key", transport=httpx.MockTransport(request))
    app = create_app(f"sqlite:///{tmp_path / 'intelligence.db'}", embedded_worker=False,
        annotation_provider=provider, tokens={"alex-key": "alex", "sam-key": "sam"}, demo_mode=False)
    with TestClient(app, headers={"Authorization": "Bearer alex-key"}) as client:
        client.mock_astra = state
        yield client


def image_data():
    data = BytesIO()
    Image.new("RGB", (16, 16), "gray").save(data, format="PNG")
    return "data:image/png;base64," + base64.b64encode(data.getvalue()).decode()


def mutate(api, path, payload=None, key=None, user="alex", method="post"):
    return getattr(api, method)(path, **({"json": payload} if payload is not None else {}), headers={
        "Authorization": f"Bearer {user}-key", "Idempotency-Key": key or uuid4().hex})


def capture(api, *, name="A saved find", user="alex", note=""):
    response = mutate(api, "/v1/saves", {"title": name, "url": f"https://saved.example.org/{uuid4().hex}",
        "image_data_url": image_data(), "note": note, "client": "ios_app"}, user=user)
    assert response.status_code == 201, response.text
    return response.json()["id"]


def enrich(api):
    assert run_once(api.app.state.factory, api.app.state.annotation_provider)


def search(api, q="", category=None, user="alex", **params):
    response = api.get("/v1/library/search", params={"q": q, **({"category": category} if category else {}), **params},
        headers={"Authorization": f"Bearer {user}-key"})
    assert response.status_code == 200, response.text
    return response.json()


def details(api, item_id):
    response = api.get(f"/v1/saves/{item_id}")
    assert response.status_code == 200, response.text
    return response.json()


def catalog(api, source="abo"):
    row = {"source_id": source, "source_record_id": "watch-1", "data_kind": "open_dataset",
        "title": "Casio vintage digital watch", "category": "Watches > Digital watches", "brand": "Casio",
        "merchant": {"id": None, "name": None, "platform": source},
        "offer": {"id": "watch-offer", "environment": "local"},
        "provenance": {"source_url": "https://catalog.example.org/watch-1"}}
    import_dataset(api.app.state.factory, source, [row], version="test", checksum="a" * 64)


def test_actual_astra_transport_populates_typed_analysis_and_searchable_facets(api):
    item_id = capture(api)
    assert search(api, "Casio")["total"] == 0
    enrich(api)
    saved = details(api, item_id)
    assert saved["analysis_status"] == "ready"
    assert saved["analysis"]["products"][0]["category_path"][-1] == "Digital watches"
    assert saved["analysis"]["products"][0]["brand"]["value"] == "Casio"
    assert saved["title"] == "A saved find" and saved["selected_text"] == ""
    for query in ("watch vintage", "CASIO", "retro", "腕時計"):
        result = search(api, query)
        assert result["total"] == 1 and result["items"][0]["id"] == item_id
        assert "search_text" not in result["items"][0] and "category_text" not in result["items"][0]
    assert search(api, category="digital WATCHES")["total"] == 1
    assert search(api, category="Watches")["total"] == 1
    assert search(api, category="watch")["total"] == 0  # Exact category, not a substring.
    assert search(api, "discount")["total"] == 0  # Unselected prompts do not become search context.


def test_library_pagination_and_tenant_isolation_are_server_side(api):
    ids = []
    for index in range(3):
        ids.append(capture(api, name=f"Look {index}"))
        enrich(api)
    foreign = capture(api, user="sam")
    enrich(api)
    first = search(api, "腕時計", limit=2)
    second = search(api, "腕時計", limit=2, offset=first["next_offset"])
    assert first["total"] == 3 and first["next_offset"] == 2 and second["next_offset"] is None
    assert {item["id"] for item in first["items"] + second["items"]} == set(ids)
    assert foreign not in {item["id"] for item in first["items"]}
    assert search(api, "腕時計", user="sam")["total"] == 1
    unauthorized = api.get("/v1/library/search", headers={"Authorization": ""})
    assert unauthorized.status_code == 401
    assert api.get("/v1/library/search", params={"q": "watch\n"}).status_code == 422


def test_analysis_retries_are_idempotent_and_pending_work_is_not_duplicated(api):
    item_id = capture(api)
    pending = mutate(api, f"/v1/saves/{item_id}/analyze", key="pending-key")
    assert pending.status_code == 202 and pending.json()["queued"] is False
    api.mock_astra["error_status"] = 401
    enrich(api)
    failed = details(api, item_id)
    assert failed["analysis_status"] == "failed" and failed["title"] == "A saved find"
    retry = mutate(api, f"/v1/saves/{item_id}/analyze", key="retry-key")
    assert retry.status_code == 202 and retry.json()["queued"] is True
    assert retry.json()["revision"] == failed["revision"] + 1
    assert mutate(api, f"/v1/saves/{item_id}/analyze", key="retry-key").json() == retry.json()
    another = mutate(api, f"/v1/saves/{item_id}/analyze", key="another-key").json()
    assert another["queued"] is False and another["job_id"] == retry.json()["job_id"]
    api.mock_astra["error_status"] = None
    enrich(api)
    assert details(api, item_id)["analysis_status"] == "ready"
    with api.app.state.factory() as db:
        assert db.scalar(select(func.count()).select_from(Job).where(Job.status == "pending")) == 0


def test_analysis_is_owned_and_deletion_invalidates_cached_retry(api):
    item_id = capture(api)
    assert mutate(api, f"/v1/saves/{item_id}/analyze", user="sam").status_code == 404
    assert mutate(api, f"/v1/saves/{item_id}/analyze", key="retry").status_code == 202
    assert mutate(api, f"/v1/saves/{item_id}", method="delete").status_code == 200
    assert mutate(api, f"/v1/saves/{item_id}/analyze", key="retry").status_code == 410
    assert mutate(api, f"/v1/saves/{item_id}/analyze", key="new-retry").status_code == 404
    enrich(api)  # The old queued job cannot restore a deleted save.
    assert search(api)["total"] == 0


def test_explicit_annotation_select_edit_and_reject_refine_context_without_executing_actions(api):
    item_id = capture(api)
    enrich(api)
    buy = next(row for row in details(api, item_id)["suggestions"] if row["claim"] == "buy_intent")
    selected = mutate(api, f"/v1/saves/{item_id}/responses", {"action": "select", "suggestion_id": buy["id"]})
    assert selected.status_code == 200 and selected.json()["execution_status"] == "annotation_only"
    assert selected.json()["analysis_job_id"]
    assert details(api, item_id)["analysis_status"] == "pending"
    enrich(api)
    assert buy["text"] in api.mock_astra["calls"][-1]["confirmed_annotations"]
    assert buy["text"] in details(api, item_id)["analysis"]["intent_context"]
    refined_buy = next(row for row in details(api, item_id)["suggestions"] if row["claim"] == "buy_intent")
    rejected = mutate(api, f"/v1/saves/{item_id}/responses", {"action": "reject", "suggestion_id": refined_buy["id"]})
    assert rejected.status_code == 200 and rejected.json()["analysis_job_id"]
    enrich(api)
    assert buy["text"] not in api.mock_astra["calls"][-1]["confirmed_annotations"]
    with api.app.state.factory() as db:
        assert not db.scalars(select(Evidence).where(Evidence.item_id == item_id, Evidence.claim == "buy_intent", Evidence.active.is_(True))).all()
    edited = mutate(api, f"/v1/saves/{item_id}/responses", {"action": "edit", "text": "A graduation present for next month"})
    assert edited.status_code == 200 and edited.json()["analysis_job_id"]
    assert search(api, "graduation")["total"] == 1
    enrich(api)
    assert "A graduation present for next month" in api.mock_astra["calls"][-1]["confirmed_annotations"]
    assert "A graduation present for next month" in details(api, item_id)["analysis"]["intent_context"]


def test_context_deletion_retracts_derived_search_terms_until_regenerated(api):
    source_id = capture(api, name="First look", note="For a future collection")
    enrich(api)
    dependent_id = capture(api, name="Second look")
    enrich(api)
    assert search(api, "Casio")["total"] == 2
    assert details(api, dependent_id)["features"]["context_evidence_ids"]
    assert mutate(api, f"/v1/saves/{source_id}", method="delete").status_code == 200
    assert details(api, dependent_id)["analysis_status"] == "pending"
    assert search(api, "Casio")["total"] == 0
    enrich(api)
    assert not api.mock_astra["calls"][-1]["confirmed_preferences"]
    assert search(api, "Casio")["total"] == 1


def test_explore_api_defaults_to_configured_source_and_cites_the_saved_analysis(api, monkeypatch):
    catalog(api, "wands")
    monkeypatch.setenv("EXPLORE_CATALOG_SOURCE", "wands")
    empty = api.get("/v1/explore").json()
    assert empty["source_id"] == "wands" and empty["status"] == "needs_saves"
    item_id = capture(api)
    assert api.get("/v1/explore").json()["status"] == "needs_analysis"
    enrich(api)
    response = api.get("/v1/explore")
    assert response.status_code == 200, response.text
    first = response.json()["items"][0]
    assert first["catalog_citation"]["source_id"] == "wands"
    assert first["catalog_citation"]["record_id"] == "watch-1" and first["catalog_citation"]["license_id"] == "MIT"
    assert all(reason["saved_item_id"] == item_id for reason in first["reasons"])
    assert first["action"] == "view_source" and first["product"]["offer"]["url"] is None
    assert first["action_url"] == "https://catalog.example.org/watch-1"
    assert api.get("/v1/explore", headers={"Authorization": "Bearer sam-key"}).json()["items"] == []
    assert api.get("/v1/explore", params={"q": "watch"}, headers={"Authorization": "Bearer sam-key"}).json()["items"]
    assert mutate(api, f"/v1/saves/{item_id}", method="delete").status_code == 200
    assert not api.get("/v1/explore").json()["items"]
    assert api.get("/v1/explore", headers={"Authorization": ""}).status_code == 401
    assert api.get("/v1/explore", params={"q": "x" * 101}).status_code == 422
    assert api.get("/v1/explore", params={"offset": 500}).status_code == 422
