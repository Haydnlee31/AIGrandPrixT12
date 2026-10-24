from copy import deepcopy
import time

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from backend.app.db import Base, Evidence, Job, SavedItem, Suggestion, make_database
from backend.app.main import create_app
from backend.app.worker import enqueue, run_once


def annotation(text="Warm lighting", **features):
    return {
        "features": {"desk_related": True, **features},
        "suggestions": [{"kind": "attraction", "text": text, "claim": "warm_lighting"}],
    }


class Provider:
    version = "test-provider-v1"

    def __init__(self, callback):
        self.callback = callback

    def understand(self, title, selected_text):
        return self.callback(title, selected_text)


@pytest.fixture
def database(tmp_path):
    engine, factory = make_database(f"sqlite:///{tmp_path / 'worker.db'}")
    Base.metadata.create_all(engine)
    with factory.begin() as db:
        item = SavedItem(user_id="alex", original_url="https://example.com/lamp", canonical_url="https://example.com/lamp", title="Original desk", source="web", selected_text="Captured lighting")
        db.add(item)
        db.flush()
        job_id = enqueue(db, "alex", "enrich", {"item_id": item.id, "revision": item.revision})
        item_id = item.id
    yield engine, factory, item_id, job_id
    engine.dispose()


def test_provider_has_no_checked_out_connection_and_revision_change_discards_output(database):
    engine, factory, item_id, old_job_id = database

    def change_save(title, text):
        assert (title, text) == ("Original desk", "Captured lighting")
        assert engine.pool.checkedout() == 0
        # This independent transaction must commit during the provider call.
        # An inference transaction retaining a write lock would deadlock here.
        with factory.begin() as db:
            item = db.get(SavedItem, item_id)
            item.title, item.selected_text, item.revision = "New desk", "New lighting", 2
            enqueue(db, "alex", "enrich", {"item_id": item_id, "revision": 2})
        return annotation("Obsolete result")

    assert run_once(factory, Provider(change_save))
    with factory() as db:
        assert db.get(Job, old_job_id).status == "done"
        item = db.get(SavedItem, item_id)
        assert item.status == "pending" and item.features == {}
        assert not db.scalars(select(Suggestion)).all()

    def updated_provider(title, text):
        assert (title, text) == ("New desk", "New lighting")
        return annotation("Current result")

    assert run_once(factory, Provider(updated_provider))
    with factory() as db:
        assert db.get(SavedItem, item_id).status == "ready"
        assert [row.text for row in db.scalars(select(Suggestion))] == ["Current result"]


def test_delete_api_can_complete_during_provider_call_and_result_stays_deleted(tmp_path):
    app = create_app(f"sqlite:///{tmp_path / 'api.db'}", embedded_worker=False, tokens={"token": "alex"})
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer token"
        response = client.post("/v1/saves", json={"url": "https://example.com/lamp", "title": "Desk lighting"}, headers={"Idempotency-Key": "save"})
        assert response.status_code == 201
        item_id = response.json()["id"]

        def remove_save(*_):
            response = client.delete(f"/v1/saves/{item_id}", headers={"Idempotency-Key": "delete"})
            assert response.status_code == 200
            return annotation()

        assert run_once(app.state.factory, Provider(remove_save))
        assert client.get(f"/v1/saves/{item_id}").status_code == 404
        with app.state.factory() as db:
            assert db.get(SavedItem, item_id).features == {}
            assert not db.scalars(select(Suggestion)).all()


@pytest.mark.parametrize("fails", [False, True])
@pytest.mark.parametrize("lease_change", ["expired", "replaced"])
def test_old_worker_cannot_publish_or_retry_after_losing_lease(database, fails, lease_change):
    _, factory, item_id, job_id = database
    expected = {}

    def lose_lease(*_):
        with factory.begin() as db:
            job = db.get(Job, job_id)
            if lease_change == "expired":
                job.lease_until = 0
            else:
                job.lease_token = "new-worker-token"
                job.lease_until = time.time() + 60
            expected.update(token=job.lease_token, until=job.lease_until)
        if fails:
            raise TimeoutError("unavailable")
        return annotation()

    assert run_once(factory, Provider(lose_lease))
    with factory() as db:
        job = db.get(Job, job_id)
        assert job.status == "running" and job.error is None
        assert (job.lease_token, job.lease_until) == (expected["token"], expected["until"])
        assert db.get(SavedItem, item_id).status == "pending"
        assert not db.scalars(select(Suggestion)).all()


@pytest.mark.parametrize("change", ["revision", "delete", "ready", "owner"])
def test_final_attempt_failure_cannot_mark_changed_save_failed(database, change):
    _, factory, item_id, job_id = database
    with factory.begin() as db:
        db.get(Job, job_id).attempts = 2

    def late_failure(*_):
        with factory.begin() as db:
            item = db.get(SavedItem, item_id)
            if change == "revision":
                item.revision += 1
            elif change == "delete":
                item.deleted = True
            elif change == "ready":
                item.status = "ready"
                item.features = {"from": "another-worker"}
            else:
                item.user_id = "sam"
        raise TimeoutError("old request failed")

    assert run_once(factory, Provider(late_failure))
    with factory() as db:
        job = db.get(Job, job_id)
        assert job.status == "done" and job.error is None
        item = db.get(SavedItem, item_id)
        assert item.status == ("ready" if change == "ready" else "pending")
        assert not db.scalars(select(Suggestion)).all()


def test_reclaimed_worker_result_wins_when_original_call_returns_later(database):
    _, factory, item_id, job_id = database

    def original_provider(*_):
        with factory.begin() as db:
            db.get(Job, job_id).lease_until = 0
        assert run_once(factory, Provider(lambda *_: annotation("Recovered result", owner="recovered")))
        return annotation("Late result", owner="original")

    assert run_once(factory, Provider(original_provider))
    with factory() as db:
        assert db.get(Job, job_id).attempts == 2
        assert db.get(Job, job_id).status == "done"
        assert db.get(SavedItem, item_id).features["owner"] == "recovered"
        assert [row.text for row in db.scalars(select(Suggestion))] == ["Recovered result"]


def test_duplicate_suggestions_and_duplicate_jobs_do_not_create_evidence(database):
    _, factory, item_id, _ = database
    result = annotation()
    result["suggestions"] *= 3
    result["suggestions"].append({"kind": "attraction", "text": " Warm lighting ", "claim": "warm_lighting"})
    with factory.begin() as db:
        enqueue(db, "alex", "enrich", {"item_id": item_id, "revision": 1})

    assert run_once(factory, Provider(lambda *_: result))

    def unexpected_call(*_):
        pytest.fail("An already ready save must not call the provider again")

    assert run_once(factory, Provider(unexpected_call))
    with factory() as db:
        assert [row.text for row in db.scalars(select(Suggestion))] == ["Warm lighting"]
        assert not db.scalars(select(Evidence)).all()


@pytest.mark.parametrize("invalid_features", [
    {"number": float("nan")},
    {"number": float("inf")},
    {"number": 2 ** 53},
    {"value": object()},
    {"value": (1, 2)},
    {1: "non-string key"},
    {"value": "x" * 2049},
    {"value": [[[[[[[["too deep"]]]]]]]]},
    {"value": [None] * 65},
    {"value": [[None] * 64] * 17},
    {str(index): "x" * 2048 for index in range(17)},
], ids=["nan", "infinite", "large-number", "object", "tuple", "key-type", "long-text", "deep", "long-list", "many-nodes", "large-json"])
def test_invalid_structured_features_are_rejected_atomically(database, invalid_features):
    _, factory, item_id, job_id = database
    result = annotation()
    result["features"] = invalid_features
    assert run_once(factory, Provider(lambda *_: result))
    with factory() as db:
        job = db.get(Job, job_id)
        assert job.status == "pending" and job.error == "ValueError"
        item = db.get(SavedItem, item_id)
        assert item.status == "pending" and item.features == {}
        assert not db.scalars(select(Suggestion)).all()


@pytest.mark.parametrize("patch", [
    {"claim": "purchase_intent"},
    {"claim": []},
    {"kind": "tool_call"},
    {"text": " "},
    {"text": "x" * 201},
    {"user_id": "sam"},
])
def test_invalid_suggestion_does_not_partially_publish_valid_ones(database, patch):
    _, factory, item_id, job_id = database
    result = annotation()
    invalid = {**deepcopy(result["suggestions"][0]), **patch}
    result["suggestions"].append(invalid)
    assert run_once(factory, Provider(lambda *_: result))
    with factory() as db:
        assert db.get(Job, job_id).error == "ValueError"
        assert db.get(SavedItem, item_id).status == "pending"
        assert not db.scalars(select(Suggestion)).all()
