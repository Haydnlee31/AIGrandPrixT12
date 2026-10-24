import json
import time
from types import SimpleNamespace
from uuid import uuid4

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi.testclient import TestClient

from backend.app.auth import InvalidLogin, LoginUnavailable, NeonAuth
from backend.app.main import create_app
from backend.app.worker import run_once


ORIGIN = "https://ep-auth-test.neonauth.ap-southeast-1.aws.neon.tech"
URL = ORIGIN + "/neondb/auth"
ALICE, BOB = str(uuid4()), str(uuid4())


@pytest.fixture
def signing(monkeypatch):
    private = Ed25519PrivateKey.generate()
    monkeypatch.setenv("NEON_AUTH_URL", URL)
    monkeypatch.delenv("NEON_ACCOUNT_LINKS", raising=False)
    monkeypatch.setattr("backend.app.auth.PyJWKClient", lambda *args, **kwargs: SimpleNamespace(get_signing_key_from_jwt=lambda token: SimpleNamespace(key=private.public_key())))
    def sign(subject=ALICE, **claims):
        now = int(time.time())
        payload = {"sub": subject, "iss": ORIGIN, "aud": ORIGIN, "exp": now + 900, "iat": now, "emailVerified": True, **claims}
        return jwt.encode(payload, private, algorithm="EdDSA", headers={"kid":"test"})
    return sign


@pytest.mark.parametrize("claims", [
    {"iss": "https://another-branch.neonauth.example"}, {"aud": "https://another-app.example"},
    {"exp": 1}, {"iat": int(time.time()) + 600}, {"emailVerified": False}, {"banned": True}, {"sub": "chime"},
])
def test_reject_wrong_branch_audience_expiration_and_unverified_identity(signing, claims):
    with pytest.raises(InvalidLogin):
        NeonAuth().subject(signing(**claims))


def test_reject_forged_and_unsigned_tokens(signing):
    verifier = NeonAuth()
    valid = signing()
    assert verifier.subject(valid) == ALICE
    forged = jwt.encode({"sub":ALICE}, Ed25519PrivateKey.generate(), algorithm="EdDSA")
    for value in (forged, jwt.encode({"sub":ALICE}, key="", algorithm="none"), "invalid", "x" * 16385):
        with pytest.raises(InvalidLogin):
            verifier.subject(value)


def test_key_service_outage_is_retryable_not_a_signout(signing):
    def unavailable(_):
        raise jwt.PyJWKClientConnectionError("offline")
    verifier = NeonAuth(jwks=SimpleNamespace(get_signing_key_from_jwt=unavailable))
    with pytest.raises(LoginUnavailable):
        verifier.subject(signing())


def test_login_shares_across_clients_but_never_between_users(signing, tmp_path, monkeypatch):
    monkeypatch.setenv("NEON_ACCOUNT_LINKS", json.dumps({ALICE:"existing-library"}))
    app = create_app(f"sqlite:///{tmp_path/'login.db'}", embedded_worker=False, tokens={"old-library-key":"existing-library"})
    with TestClient(app) as client:
        config = client.get("/v1/auth/config").json()
        assert config == {"enabled":True, "provider":"neon", "auth_url":URL}
        client.headers["Authorization"] = "Bearer old-library-key"
        captured = client.post("/v1/saves", json={"url":"https://example.com/lamp", "title":"A lamp", "source":"web", "client":"chrome_extension"}, headers={"Idempotency-Key":"capture-1"})
        assert captured.status_code == 201
        item_id = captured.json()["id"]
        before = client.get("/v1/sync").json()["revision"]
        run_once(app.state.factory)
        assert client.get("/v1/sync").json()["revision"] > before
        for native_or_browser in range(3):
            client.headers["Authorization"] = "Bearer " + signing()
            assert client.get("/v1/me").json()["user_id"] == "existing-library"
            assert client.get(f"/v1/saves/{item_id}").status_code == 200
        client.headers["Authorization"] = "Bearer " + signing(BOB)
        assert client.get("/v1/me").json()["user_id"] == "neon:" + BOB
        assert client.get(f"/v1/saves/{item_id}").status_code == 404
        assert client.get("/v1/collection").json()["items"] == []
        assert client.delete(f"/v1/saves/{item_id}", headers={"Idempotency-Key":"delete-1"}).status_code == 404
        assert client.get("/v1/sync").json() == {"user_id":"neon:"+BOB, "revision":0, "poll_interval_ms":15000}
        client.headers["Authorization"] = "Bearer " + signing()
        before = client.get("/v1/sync").json()["revision"]
        assert client.delete(f"/v1/saves/{item_id}", headers={"Idempotency-Key":"delete-1"}).status_code == 200
        assert client.get("/v1/sync").json()["revision"] > before
