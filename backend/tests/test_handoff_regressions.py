from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from backend.app.main import create_app
from backend.app.worker import run_once


@pytest.fixture
def client(tmp_path):
    app = create_app(
        f"sqlite:///{tmp_path / 'handoff.db'}",
        embedded_worker=False,
        tokens={"handoff-token": "handoff-user"},
        demo_mode=True,
    )
    with TestClient(app) as test_client:
        test_client.headers["Authorization"] = "Bearer handoff-token"
        yield test_client


def mutate(client, path, body, *, method="POST", key=None):
    return client.request(
        method,
        f"/v1{path}",
        json=body,
        headers={"Idempotency-Key": key or uuid4().hex},
    )


def drain(client):
    for _ in range(30):
        if not run_once(client.app.state.factory):
            return
    pytest.fail("Worker did not finish the finite test workload")


def test_retrying_capture_after_deletion_cannot_resurrect_save(client):
    body = {
        "url": "https://example.com/shared-desk",
        "title": "Warm desk lighting",
        "note": "I like the warm lighting",
        "client": "ios_share_extension",
    }
    captured = mutate(client, "/saves", body, key="original-capture")
    assert captured.status_code == 201, captured.text
    item_id = captured.json()["id"]
    removed = mutate(client, f"/saves/{item_id}", {}, method="DELETE")
    assert removed.status_code == 200, removed.text

    # A second device may retry an earlier request whose response was lost.
    replay = mutate(client, "/saves", body, key="original-capture")
    assert replay.status_code == 410, replay.text
    assert replay.json()["error"]["code"] == "mutation_expired"
    assert replay.json()["error"]["retryable"] is False
    drain(client)
    assert client.get(f"/v1/saves/{item_id}").status_code == 404
    assert client.get("/v1/collection").json()["items"] == []
    assert client.get("/v1/hypotheses").json()["items"][0]["evidence"] == []


def test_noop_watch_updates_preserve_crossing_state_and_queued_checks(client):
    response = mutate(client, "/watches", {"variant_id": "arc-sand", "target_minor": 5000})
    assert response.status_code == 201, response.text
    watch = response.json()
    observation = {"variant_id": "arc-sand", "currency": "SGD", "amount_minor": 4900}

    def observe(price):
        result = mutate(client, f"/watches/{watch['id']}/simulate", {**observation, "amount_minor": price})
        assert result.status_code == 200, result.text

    observe(4900)
    drain(client)
    assert len(client.get("/v1/notifications").json()["items"]) == 1

    for payload in [{}, {"enabled": True}, {"target_minor": 5000}, {"enabled": True, "target_minor": 5000}]:
        # A no-op edit must not invalidate already queued observations either.
        observe(4800)
        patched = mutate(client, f"/watches/{watch['id']}", payload, method="PATCH")
        assert patched.status_code == 200, patched.text
        assert patched.json()["rule_version"] == watch["rule_version"]
        assert patched.json()["below"] is True
        drain(client)
        assert len(client.get("/v1/notifications").json()["items"]) == 1

    # A genuine crossing still produces a new alert after the no-op edits.
    observe(6000)
    drain(client)
    observe(4900)
    drain(client)
    assert len(client.get("/v1/notifications").json()["items"]) == 2


def test_simultaneous_same_version_session_writes_have_one_winner(client):
    # Repeated externally synchronized requests exercise independent FastAPI
    # handler threads without adding a barrier inside a database transaction.
    with ThreadPoolExecutor(max_workers=2) as pool:
        for _ in range(8):
            started = mutate(client, "/discovery-sessions", {"explicit": True})
            assert started.status_code == 201, started.text
            session = started.json()
            barrier = Barrier(2)

            def send(action, value):
                barrier.wait(timeout=5)
                return mutate(
                    client,
                    f"/discovery-sessions/{session['id']}/events",
                    {"expected_version": session["version"], "action": action, "value": value},
                )

            first = pool.submit(send, "direction", "warm")
            second = pool.submit(send, "budget", 8000)
            responses = [first.result(timeout=30), second.result(timeout=30)]
            assert sorted(r.status_code for r in responses) == [200, 409], [r.text for r in responses]
            winner = next(r.json() for r in responses if r.status_code == 200)
            conflict = next(r.json()["error"] for r in responses if r.status_code == 409)
            assert conflict["code"] == "stale_version"
            assert conflict["current"] == winner
            persisted = client.get(f"/v1/discovery-sessions/{session['id']}").json()
            assert persisted == winner
            assert persisted["version"] == session["version"] + 1
