import json
from types import SimpleNamespace

import httpx
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from backend.app.auth_proxy import install_login_routes

WEB = "https://mynah-finds.vercel.app"
UPSTREAM = "https://auth.example.test/neondb/auth"
# Provider contract, deliberately independent of our implementation constant.
PROVIDER_COOKIE = "__Secure-neon-auth.session_token"


@pytest.fixture
def proxy(monkeypatch):
    requests = []
    def upstream(request):
        requests.append(request)
        return httpx.Response(200, json={"user":{"id":"alice"}, "token":"opaque-session"}, headers={
            "Set-Cookie": f"{PROVIDER_COOKIE}=signed-session; Domain=auth.example.test; Path=/; HttpOnly; Secure; SameSite=None; Partitioned; Max-Age=604800",
        })
    client_class = httpx.AsyncClient
    monkeypatch.setattr("backend.app.auth_proxy.httpx.AsyncClient", lambda **kwargs: client_class(transport=httpx.MockTransport(upstream), **kwargs))
    app = FastAPI()
    install_login_routes(app, SimpleNamespace(enabled=True, base_url=UPSTREAM), ["chrome-extension://test-extension"])
    with TestClient(app, base_url=WEB) as client:
        yield client, requests


def test_login_preserves_only_provider_session_as_first_party_http_only_cookie(proxy):
    client, requests = proxy
    result = client.post("/v1/auth/session/sign-in/email-otp", headers={"Origin":WEB,"X-Mynah-Auth":"1","Authorization":"Bearer private-library-key"}, json={"email":"test@example.com","otp":"123456"})
    assert result.status_code == 200
    assert result.headers["cache-control"] == "no-store"
    assert result.json() == {"user":{"id":"alice"}}
    assert "set-cookie" in result.headers, "Successful login lost Neon's session cookie"
    cookie = result.headers["set-cookie"]
    assert "HttpOnly" in cookie and "Secure" in cookie and "SameSite=Lax" in cookie
    assert "Path=/v1/auth/session" in cookie and "Max-Age=604800" in cookie
    assert "Domain" not in cookie and "Partitioned" not in cookie
    assert "authorization" not in requests[0].headers
    client.cookies.set("unrelated_private_cookie", "other-secret")
    client.get("/v1/auth/session/token", headers={"X-Mynah-Auth":"1"})
    assert requests[-1].headers["cookie"] == PROVIDER_COOKIE + "=signed-session"
    assert requests[-1].url == UPSTREAM + "/token"


@pytest.mark.parametrize("origin,header", [("https://attacker.example","1"), ("null","1"), (WEB,None), (None,None)])
def test_rejects_csrf_without_contacting_neon(proxy, origin, header):
    client, requests = proxy
    headers = {}
    if origin: headers["Origin"] = origin
    if header: headers["X-Mynah-Auth"] = header
    assert client.post("/v1/auth/session/sign-out", json={}, headers=headers).status_code == 403
    assert requests == []


def test_disallows_arbitrary_proxy_operations_and_password_changes(proxy):
    client, requests = proxy
    headers = {"X-Mynah-Auth":"1"}
    for path in ("admin/list-users", "change-password", "sign-up/email", "https://attacker.example"):
        assert client.post("/v1/auth/session/"+path, json={}, headers=headers).status_code == 404
    assert client.get("/v1/auth/session/token?redirect=https://attacker.example", headers=headers).status_code == 400
    assert client.post("/v1/auth/session/email-otp/send-verification-otp", json={"email":"test@example.com", "type":"forget-password"}, headers=headers).status_code == 400
    assert requests == []


def test_supports_exact_extension_origin_and_native_requests(proxy):
    client, requests = proxy
    for origin in ("chrome-extension://test-extension", None):
        headers = {"X-Mynah-Auth":"1"}
        if origin: headers["Origin"] = origin
        assert client.get("/v1/auth/session/get-session", headers=headers).status_code == 200
    assert all(request.headers["origin"] == WEB for request in requests)
