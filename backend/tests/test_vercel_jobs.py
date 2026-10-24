import time

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from backend.app.db import Base, Job, SavedItem, make_database
from backend.app.main import create_app
from backend.app.predictive import DemoAnnotationProvider
from backend.app.vercel_jobs import dispatch, process
from backend.app.worker import enqueue, run_once


def test_queue_delivery_is_after_commit_and_failure_preserves_save(tmp_path):
    app = create_app(f"sqlite:///{tmp_path / 'api.db'}", embedded_worker=False,
                     tokens={"alice-key": "alice", "bob-key": "bob"})
    seen = []

    def unavailable(factory, *, user_id=None):
        with factory() as db:
            seen.append((user_id, db.scalar(select(SavedItem.id))))
        raise RuntimeError("queue unavailable")

    app.state.job_dispatcher = unavailable
    with TestClient(app) as client:
        headers = {"Authorization": "Bearer alice-key", "Idempotency-Key": "one"}
        response = client.post("/v1/saves", headers=headers,
                               json={"url": "https://example.com/chair", "title": "Chair"})
        assert response.status_code == 201
        assert seen == [("alice", response.json()["id"])]
        assert client.post("/v1/saves", headers=headers,
                           json={"url": "https://example.com/chair", "title": "Chair"}).json()["id"] == response.json()["id"]
        count = len(seen)
        assert client.get("/v1/collection").status_code == 401
        assert len(seen) == count
        bob = client.get("/v1/collection", headers={"Authorization": "Bearer bob-key"})
        assert bob.json()["items"] == []
        with app.state.factory() as db:
            assert len(list(db.scalars(select(Job)))) == 1


def test_dispatch_is_account_scoped_and_recovers_expired_leases(tmp_path, monkeypatch):
    engine, factory = make_database(f"sqlite:///{tmp_path / 'jobs.db'}")
    Base.metadata.create_all(engine)
    with factory.begin() as db:
        ids = [enqueue(db, user, "enrich", {}) for user in ["alice", "bob", "alice", "alice"]]
        db.get(Job, ids[2]).status = "running"
        db.get(Job, ids[2]).lease_until = time.time() - 1
        db.get(Job, ids[3]).due_at = time.time() + 100
    sent = []

    class Queue:
        def __init__(self, **kwargs):
            pass

        def send(self, topic, payload, **kwargs):
            sent.append((topic, payload, kwargs))

    monkeypatch.setattr("backend.app.vercel_jobs.QueueClient", Queue)
    assert dispatch(factory, user_id="alice") == 2
    assert {entry[1]["job_id"] for entry in sent} == {ids[0], ids[2]}
    assert all(set(entry[1]) == {"job_id"} for entry in sent)
    engine.dispose()


def test_targeted_delivery_does_not_claim_another_job_and_retries(tmp_path, monkeypatch):
    engine, factory = make_database(f"sqlite:///{tmp_path / 'targeted.db'}")
    Base.metadata.create_all(engine)
    with factory.begin() as db:
        first = enqueue(db, "alice", "enrich", {"item_id": "deleted", "revision": 1})
        second = enqueue(db, "bob", "enrich", {"item_id": "deleted", "revision": 1})
    run_once(factory, DemoAnnotationProvider(), job_id=second)
    with factory() as db:
        assert db.get(Job, first).status == "pending"
        assert db.get(Job, second).status == "done"
    monkeypatch.setattr("backend.app.vercel_jobs.run_once", lambda *args, **kwargs: None)
    with pytest.raises(RuntimeError, match="job_not_finished"):
        process(factory, first)
    process(factory, second)
    process(factory, "already-removed")
    engine.dispose()


def test_recovery_route_requires_its_own_secret(tmp_path, monkeypatch):
    monkeypatch.setenv("CRON_SECRET", "c" * 43)
    app = create_app(f"sqlite:///{tmp_path / 'cron.db'}", embedded_worker=False)
    calls = []
    app.state.job_dispatcher = lambda factory: calls.append(True) or 2
    with TestClient(app) as client:
        assert client.get("/internal/jobs/recover").status_code == 401
        assert client.get("/internal/jobs/recover", headers={"Authorization": "Bearer demo-alex"}).status_code == 401
        assert calls == []
        result = client.get("/internal/jobs/recover", headers={"Authorization": "Bearer " + "c" * 43})
        assert result.json() == {"dispatched": 2}
        assert calls == [True]
