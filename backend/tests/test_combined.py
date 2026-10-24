import json

from fastapi.testclient import TestClient
import pytest

from backend.app.combined import RELAY_PATHS, create_app
from backend.app.intelligence import DemoAnnotationProvider
from backend.tests.test_multimodal_pipeline import FakeMultimodal
from scripts.run_local import configure


@pytest.fixture
def combined(tmp_path):
    app = create_app(tokens={"alex-session": "alex", "sam-session": "sam"}, api_key="",
        price_directory=tmp_path / "prices", relay_options={"price_background": False},
        main_options={"database_url": f"sqlite:///{tmp_path / 'combined.db'}",
            "annotation_provider": DemoAnnotationProvider(), "embedded_worker": False,
            "multimodal_enabled": True, "multimodal_provider": FakeMultimodal(),
            "allowed_origins": ["https://app.example.org"]})
    with TestClient(app) as client:
        yield client


def test_one_origin_serves_both_native_and_shared_routes(combined):
    headers = {"Authorization": "Bearer alex-session"}
    assert combined.get("/health").json() == {"status": "ok", "ready": False, "multimodal": True}
    assert combined.get("/v1/me", headers=headers).json()["user_id"] == "alex"
    assert combined.get("/v1/multimodal/capabilities", headers=headers).json()["enabled"] is True
    assert combined.get("/v1/catalog/status", headers=headers).status_code == 200
    for route in RELAY_PATHS - {"/v1/catalog/status"}:
        response = combined.post(route, json={}, headers=headers)
        assert response.status_code in {200, 422, 503}, (route, response.status_code)
    assert combined.get("/").status_code == 200


def test_all_relay_routes_authenticate_before_parsing(combined):
    for route in RELAY_PATHS:
        method = "GET" if route == "/v1/catalog/status" else "POST"
        for headers in ({}, {"Authorization": "Bearer other"}):
            response = combined.request(method, route, content=b"not-json", headers=headers)
            assert response.status_code == 401
            assert response.headers["cache-control"] == "no-store"


def test_duplicate_auth_is_rejected_and_account_state_separate(combined):
    response = combined.get("/v1/catalog/status", headers=[("Authorization", "Bearer alex-session"), ("Authorization", "Bearer sam-session")])
    assert response.status_code == 401
    relays = combined.app.state.relays
    assert relays["alex"].state.preview_service is not relays["sam"].state.preview_service
    assert relays["alex"].state.price_tracking_service.path != relays["sam"].state.price_tracking_service.path


def test_cors_supports_same_configured_origins_on_native_routes(combined):
    response = combined.options("/v1/capture-preview", headers={
        "Origin": "https://app.example.org", "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "Authorization, Content-Type"})
    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == "https://app.example.org"
    response = combined.get("/v1/catalog/status", headers={"Origin": "https://evil.example"})
    assert "access-control-allow-origin" not in response.headers


def test_startup_loads_key_enables_multimodal_and_preserves_json(tmp_path):
    config = tmp_path / ".env"
    config.write_text('ASTRA_API_KEY="fixture-only"\nAPI_TOKENS={"a":"alex"}\nCORS_ORIGINS=["https://app.example.org"]\nIGNORED=bad\n')
    env = {}
    configure(config, env)
    assert env["MULTIMODAL_ENABLED"] == "true"
    assert env["EMBEDDED_WORKER"] == "true"
    assert json.loads(env["API_TOKENS"]) == {"a": "alex"}
    assert "IGNORED" not in env
    env["ASTRA_API_KEY"] = "process-value"
    configure(config, env)
    assert env["ASTRA_API_KEY"] == "process-value"


def test_startup_requires_key_and_never_leaks_malformed_value(tmp_path):
    with pytest.raises(ValueError, match="Configure ASTRA_API_KEY"):
        configure(tmp_path / "missing", {})
    config = tmp_path / ".env"
    config.write_text('ASTRA_API_KEY="secret-sample-without-closing-quote')
    with pytest.raises(ValueError) as error:
        configure(config, {})
    assert "secret-sample" not in str(error.value)
    configure(tmp_path / "missing", {"MULTIMODAL_ENABLED": "false"})


def test_login_cookie_preflight_retains_credentials_while_api_does_not(combined):
    login = combined.options("/v1/auth/session/token", headers={
        "Origin": "https://app.example.org", "Access-Control-Request-Method": "GET",
        "Access-Control-Request-Headers": "X-Mynah-Auth"})
    assert login.status_code == 200
    assert login.headers["access-control-allow-credentials"] == "true"
    api = combined.options("/v1/catalog/status", headers={
        "Origin": "https://app.example.org", "Access-Control-Request-Method": "GET",
        "Access-Control-Request-Headers": "Authorization"})
    assert "access-control-allow-credentials" not in api.headers


def test_verified_dynamic_login_uses_same_account_in_relay_and_shared_library(tmp_path, monkeypatch):
    import time
    from types import SimpleNamespace
    from uuid import uuid4
    import jwt
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    origin = "https://test.neonauth.example"
    alice, bob = str(uuid4()), str(uuid4())
    private = Ed25519PrivateKey.generate()
    monkeypatch.setenv("NEON_AUTH_URL", origin + "/db/auth")
    monkeypatch.setenv("NEON_ACCOUNT_LINKS", json.dumps({alice: "existing-library"}))
    monkeypatch.setattr("backend.app.auth.PyJWKClient", lambda *args, **kwargs: SimpleNamespace(get_signing_key_from_jwt=lambda token: SimpleNamespace(key=private.public_key())))
    def token(subject):
        return jwt.encode({"sub": subject, "iss": origin, "aud": origin, "exp": int(time.time()) + 900,
                           "iat": int(time.time()), "emailVerified": True}, private, algorithm="EdDSA")
    app = create_app(tokens={}, api_key="", price_directory=tmp_path / "prices",
        relay_options={"price_background": False}, main_options={
            "database_url": f"sqlite:///{tmp_path / 'managed.db'}", "embedded_worker": False,
            "annotation_provider": DemoAnnotationProvider(), "multimodal_provider": FakeMultimodal()})
    with TestClient(app) as client:
        assert app.state.relays == {}
        headers = {"Authorization": "Bearer " + token(alice)}
        assert client.get("/v1/me", headers=headers).json()["user_id"] == "existing-library"
        assert client.get("/v1/catalog/status", headers=headers).status_code == 200
        first = app.state.relays["existing-library"]
        assert client.get("/v1/catalog/status", headers=headers).status_code == 200
        assert app.state.relays["existing-library"] is first
        capture = client.post("/v1/multimodal/captures", json={"title": "Private watch"},
            headers={**headers, "Idempotency-Key": "private"})
        assert capture.status_code == 201
        bob_headers = {"Authorization": "Bearer " + token(bob)}
        assert client.get("/v1/catalog/status", headers=bob_headers).status_code == 200
        assert app.state.relays["neon:" + bob] is not first
        assert client.get("/v1/multimodal/captures/" + capture.json()["id"], headers=bob_headers).status_code == 404
        assert client.get("/v1/catalog/status", headers={"Authorization": "Bearer unsigned"}).status_code == 401
        assert len(app.state.relays) == 2
