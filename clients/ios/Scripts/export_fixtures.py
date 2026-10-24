"""Regenerate Swift decoder fixtures from an isolated real API instance (no external calls)."""
import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from fastapi.testclient import TestClient
from backend.app.main import create_app
from backend.app.worker import run_once

OUT = Path(__file__).resolve().parents[1] / "Tests/CommonThreadKitTests/Fixtures"
SHARED = ROOT / "contracts/examples"


def save(name, response, expected=200):
    assert response.status_code == expected, response.text
    payload = response.json()
    for destination in (OUT, SHARED):
        destination.mkdir(parents=True, exist_ok=True)
        (destination / f"{name}.json").write_text(json.dumps(payload, indent=2) + "\n")
    return payload


with tempfile.TemporaryDirectory() as directory:
    app = create_app(database_url=f"sqlite:///{directory}/fixture.db", embedded_worker=False, tokens={"fixture-token": "fixture-user"}, demo_mode=True)
    with TestClient(app, headers={"Authorization": "Bearer fixture-token"}) as client:
        save("capabilities", client.get("/v1/capabilities"))
        save("account", client.get("/v1/me"))
        receipt = save("capture", client.post("/v1/saves", json={"url": "https://example.org/desk", "title": "Warm desk lighting", "note": "Warm lighting for my small desk", "client": "ios_share_extension"}, headers={"Idempotency-Key": "capture"}), 201)
        save("pending", client.get(f"/v1/saves/{receipt['id']}"))
        run_once(app.state.factory)
        item = save("saved", client.get(f"/v1/saves/{receipt['id']}"))
        save("annotation", client.post(f"/v1/saves/{receipt['id']}/responses", json={"action": "select", "suggestion_id": item["suggestions"][0]["id"]}, headers={"Idempotency-Key": "annotation"}))
        save("collection", client.get("/v1/collection"))
        save("hypotheses", client.get("/v1/hypotheses"))
        session = save("session", client.post("/v1/discovery-sessions", json={"explicit": True}, headers={"Idempotency-Key": "session"}), 201)
        session = save("budget", client.post(f"/v1/discovery-sessions/{session['id']}/events", json={"expected_version": 1, "action": "budget", "value": 10000}, headers={"Idempotency-Key": "budget"}))
        save("stale_version", client.post(f"/v1/discovery-sessions/{session['id']}/events", json={"expected_version": 1, "action": "direction", "value": "warm"}, headers={"Idempotency-Key": "stale"}), 409)
        save("shortlist", client.post(f"/v1/discovery-sessions/{session['id']}/events", json={"expected_version": 2, "action": "retrieve"}, headers={"Idempotency-Key": "retrieve"}))
        save("discoveries", client.get("/v1/discovery-sessions"))
        save("catalog", client.get("/v1/catalog"))
        watch = save("watch", client.post("/v1/watches", json={"variant_id": "halo-cream", "target_minor": 7000}, headers={"Idempotency-Key": "watch"}), 201)
        save("watch_update", client.patch(f"/v1/watches/{watch['id']}", json={"target_minor": 7100}, headers={"Idempotency-Key": "watch-update"}))
        save("watches", client.get("/v1/watches"))
        save("watch_detail", client.get(f"/v1/watches/{watch['id']}"))
        simulation = save("simulation", client.post(f"/v1/watches/{watch['id']}/simulate", json={"variant_id": "halo-cream", "currency": "SGD", "amount_minor": 6900}, headers={"Idempotency-Key": "simulation"}))
        run_once(app.state.factory)
        save("job", client.get(f"/v1/jobs/{simulation['job_id']}"))
        save("notifications", client.get("/v1/notifications"))
        save("unauthorized", client.get("/v1/me", headers={"Authorization": "Bearer invalid"}), 401)
print(f"Exported API fixtures to {OUT}")
