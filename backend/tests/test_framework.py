from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import event

from backend.app.main import create_app
from backend.app.worker import run_once


WEB_ORIGIN = "https://app.commonthread.test"
EXTENSION_ORIGIN = "chrome-extension://abcdefghijklmnopabcdefghijklmnop"
TOKENS = {"alex-extension": "alex", "alex-ios": "alex", "sam-ios": "sam"}


@pytest.fixture
def client(tmp_path):
    app = create_app(
        f"sqlite:///{tmp_path / 'framework.db'}",
        embedded_worker=False,
        tokens=TOKENS,
        demo_mode=True,
        allowed_origins=[WEB_ORIGIN, EXTENSION_ORIGIN],
    )
    with TestClient(app) as test_client:
        test_client.headers["Authorization"] = "Bearer alex-extension"
        yield test_client


def post(client, path, body, *, token=None):
    headers = {"Idempotency-Key": uuid4().hex}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return client.post(f"/v1{path}", json=body, headers=headers)


def drain(client):
    for _ in range(30):
        if not run_once(client.app.state.factory):
            return
    pytest.fail("Worker did not finish the finite test workload")


def test_capabilities_require_auth_and_label_available_demo_features(client):
    unauthorized = client.get("/v1/capabilities", headers={"Authorization": ""})
    assert unauthorized.status_code == 401
    assert unauthorized.json()["error"]["code"] == "unauthorized"

    response = client.get("/v1/capabilities")
    assert response.status_code == 200
    capabilities = response.json()
    assert capabilities["authentication"] == "development_bearer"
    assert capabilities["data_modes"] == {"annotations": "demo_rules", "catalog": "fixture", "tracking": "simulated"}
    for feature in ["annotations", "discovery", "watches", "price_simulation", "demo_reset", "image_upload"]:
        assert capabilities["features"][feature] is True
    for feature in ["live_price_monitoring", "push_notifications", "merchant_handoff", "personal_agent_connector", "reminder_scheduling"]:
        assert capabilities["features"][feature] is False
    assert set(capabilities["capture"]["clients"]) == {"web", "chrome_extension", "ios_app", "ios_share_extension"}
    assert capabilities["refresh"]["incremental_sync"] is False
    assert capabilities["refresh"]["pending_save_interval_ms"] < capabilities["refresh"]["pending_save_timeout_ms"]


def test_disabling_demo_mode_disables_simulation_and_reset_without_claiming_live_data(tmp_path):
    app = create_app(
        f"sqlite:///{tmp_path / 'not-demo.db'}",
        embedded_worker=False,
        tokens=TOKENS,
        demo_mode=False,
        allowed_origins=[],
    )
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer alex-ios"
        capabilities = client.get("/v1/capabilities").json()
        assert capabilities["features"]["price_simulation"] is False
        assert capabilities["features"]["demo_reset"] is False
        assert capabilities["features"]["live_price_monitoring"] is False
        assert capabilities["data_modes"]["catalog"] == "fixture"
        watch = post(client, "/watches", {"variant_id": "arc-sand", "target_minor": 5000}).json()
        assert post(client, f"/watches/{watch['id']}/simulate", {"variant_id": "arc-sand", "currency": "SGD", "amount_minor": 4900}).status_code == 404
        assert post(client, "/demo/reset", {}).status_code == 404


def test_clients_share_user_collection_and_keep_capture_provenance_separate_from_source(client):
    chrome_capture = post(client, "/saves", {
        "url": "https://pinterest.com/pin/desk-one",
        "title": "Warm desk lighting",
        "source": "pinterest",
        "client": "chrome_extension",
    })
    assert chrome_capture.status_code == 201, chrome_capture.text
    chrome_id = chrome_capture.json()["id"]
    ios_headers = {"Authorization": "Bearer alex-ios"}
    visible_on_ios = client.get("/v1/collection", headers=ios_headers).json()["items"]
    assert [item["id"] for item in visible_on_ios] == [chrome_id]
    assert visible_on_ios[0]["client"] == "chrome_extension"
    assert visible_on_ios[0]["source"] == "pinterest"

    ios_capture = post(client, "/saves", {
        "url": "https://example.com/shared-from-ios",
        "title": "Small desk",
        "source": "article",
        "client": "ios_share_extension",
    }, token="alex-ios")
    assert ios_capture.status_code == 201, ios_capture.text
    items = client.get("/v1/collection").json()["items"]
    assert {item["id"] for item in items} == {chrome_id, ios_capture.json()["id"]}
    ios_item = next(item for item in items if item["id"] == ios_capture.json()["id"])
    assert (ios_item["client"], ios_item["source"]) == ("ios_share_extension", "article")
    assert all("user_id" not in item for item in items)

    sam_headers = {"Authorization": "Bearer sam-ios"}
    assert client.get("/v1/collection", headers=sam_headers).json()["items"] == []
    assert client.get(f"/v1/saves/{chrome_id}", headers=sam_headers).status_code == 404
    invalid = post(client, "/saves", {"url": "https://example.com/unsupported", "title": "Desk", "client": "unregistered-client"})
    assert invalid.status_code == 422


def test_cors_preflight_allows_only_exact_configured_origins_and_headers(client):
    def preflight(origin, requested_headers="authorization,content-type,idempotency-key"):
        return client.options("/v1/saves", headers={
            "Origin": origin,
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": requested_headers,
            "Authorization": "",
        })

    for origin in [WEB_ORIGIN, EXTENSION_ORIGIN]:
        allowed = preflight(origin)
        assert allowed.status_code == 200, allowed.text
        assert allowed.headers["access-control-allow-origin"] == origin
        assert "origin" in allowed.headers["vary"].lower()
        assert "access-control-allow-credentials" not in allowed.headers

    for origin in ["https://app.commonthread.test.evil.test", "https://app.commonthread.test:8443", "http://app.commonthread.test", "null"]:
        denied = preflight(origin)
        assert denied.status_code == 400, denied.text
        assert "access-control-allow-origin" not in denied.headers
    assert preflight(WEB_ORIGIN, "x-unapproved-header").status_code == 400

    actual = client.get("/v1/me", headers={"Origin": WEB_ORIGIN})
    assert actual.status_code == 200
    assert actual.headers["access-control-allow-origin"] == WEB_ORIGIN
    assert "x-request-id" in actual.headers["access-control-expose-headers"].lower()
    assert actual.headers["x-request-id"]


def test_unexpected_errors_preserve_request_correlation_and_allowed_origin_access(tmp_path):
    app = create_app(
        f"sqlite:///{tmp_path / 'unexpected-error.db'}",
        embedded_worker=False,
        tokens=TOKENS,
        demo_mode=True,
        allowed_origins=[WEB_ORIGIN, EXTENSION_ORIGIN],
    )
    with TestClient(app, raise_server_exceptions=False) as client:
        client.headers["Authorization"] = "Bearer alex-extension"
        engine = app.state.factory.kw["bind"]

        def fail_collection(conn, cursor, statement, parameters, context, many):
            if statement.startswith("SELECT saved_items."):
                raise RuntimeError("Internal database diagnostic must not reach clients")

        event.listen(engine, "before_cursor_execute", fail_collection)
        request_ids = set()
        try:
            for origin in [WEB_ORIGIN, EXTENSION_ORIGIN, "https://unapproved.example", None]:
                response = client.get("/v1/collection", headers={"Origin": origin} if origin else {})
                assert response.status_code == 500
                error = response.json()["error"]
                assert error["code"] == "internal_error"
                assert "Internal database diagnostic" not in response.text
                assert response.headers["x-request-id"] == error["request_id"]
                assert error["request_id"] not in request_ids
                request_ids.add(error["request_id"])
                if origin in [WEB_ORIGIN, EXTENSION_ORIGIN]:
                    assert response.headers["access-control-allow-origin"] == origin
                    assert "x-request-id" in response.headers["access-control-expose-headers"].lower()
                    assert "origin" in response.headers["vary"].lower()
                else:
                    assert "access-control-allow-origin" not in response.headers
                assert "access-control-allow-credentials" not in response.headers
        finally:
            event.remove(engine, "before_cursor_execute", fail_collection)

        # Failure handling releases the failed transaction for the next request.
        assert client.get("/v1/collection").json() == {"items": [], "next_offset": None}


def test_watch_and_job_status_endpoints_are_owned_and_omit_internal_payloads(client):
    created = post(client, "/watches", {"variant_id": "arc-sand", "target_minor": 5000})
    assert created.status_code == 201, created.text
    watch = created.json()
    assert client.get(f"/v1/watches/{watch['id']}").json() == watch

    queued = post(client, f"/watches/{watch['id']}/simulate", {"variant_id": "arc-sand", "currency": "SGD", "amount_minor": 4900})
    assert queued.status_code == 200, queued.text
    job_path = f"/v1/jobs/{queued.json()['job_id']}"
    pending = client.get(job_path)
    assert pending.status_code == 200
    assert pending.json()["status"] == "pending"
    assert set(pending.json()) == {"id", "kind", "status", "attempts", "error"}
    sam_headers = {"Authorization": "Bearer sam-ios"}
    assert client.get(job_path, headers=sam_headers).status_code == 404
    assert client.get(f"/v1/watches/{watch['id']}", headers=sam_headers).status_code == 404
    assert client.get("/v1/jobs/missing").status_code == 404
    assert client.get("/v1/watches/missing").status_code == 404

    drain(client)
    completed = client.get(job_path).json()
    assert completed["status"] == "done"
    assert completed["attempts"] == 1
    checked = client.get(f"/v1/watches/{watch['id']}").json()
    assert checked["last_price_minor"] == 4900
    assert checked["below"] is True


def test_list_pagination_has_disjoint_pages_and_an_explicit_end(client):
    expected = {"collection": set(), "discovery-sessions": set(), "watches": set()}
    for index in range(3):
        capture = post(client, "/saves", {"url": f"https://example.com/page-{index}", "title": "Desk"})
        assert capture.status_code == 201, capture.text
        expected["collection"].add(capture.json()["id"])
        session = post(client, "/discovery-sessions", {"explicit": True})
        assert session.status_code == 201, session.text
        expected["discovery-sessions"].add(session.json()["id"])
        watch = post(client, "/watches", {"variant_id": "arc-sand", "target_minor": 5000})
        assert watch.status_code == 201, watch.text
        expected["watches"].add(watch.json()["id"])
        queued = post(client, f"/watches/{watch.json()['id']}/simulate", {"variant_id": "arc-sand", "currency": "SGD", "amount_minor": 4900})
        assert queued.status_code == 200, queued.text
    drain(client)

    for path in ["collection", "discovery-sessions", "watches", "notifications"]:
        first = client.get(f"/v1/{path}?limit=2").json()
        assert len(first["items"]) == 2
        assert first["next_offset"] == 2
        second = client.get(f"/v1/{path}?limit=2&offset={first['next_offset']}").json()
        assert len(second["items"]) == 1
        assert second["next_offset"] is None
        all_items = first["items"] + second["items"]
        ids = {item["id"] for item in all_items}
        assert len(ids) == 3
        if path == "notifications":
            assert {item["watch_id"] for item in all_items} == expected["watches"]
        else:
            assert ids == expected[path]
        assert client.get(f"/v1/{path}?offset=20&limit=2").json() == {"items": [], "next_offset": None}
        for query in ["offset=-1", "limit=0", "limit=101"]:
            invalid = client.get(f"/v1/{path}?{query}")
            assert invalid.status_code == 422
            assert invalid.json()["error"]["code"] == "invalid_pagination"


def test_openapi_defines_outputs_bearer_auth_and_required_mutation_keys(client):
    response = client.get("/openapi.json", headers={"Authorization": ""})
    assert response.status_code == 200
    document = response.json()
    scheme = document["components"]["securitySchemes"]["Bearer"]
    assert scheme["type"] == "http" and scheme["scheme"] == "bearer"
    assert not document["paths"]["/health"]["get"].get("security")

    for path, methods in document["paths"].items():
        for method, operation in methods.items():
            if method not in {"get", "post", "patch", "delete"}:
                continue
            if path == "/v1/auth/config":
                assert not operation.get("security")
            elif path.startswith("/v1/"):
                assert {"Bearer": []} in operation["security"], (path, method)
            success = [value for code, value in operation["responses"].items() if code.startswith("2")]
            assert success, (path, method)
            for result in success:
                if path == "/v1/commerce/datasets/{source}/export":
                    assert result["content"]["application/x-ndjson"]["schema"]["type"] == "string"
                    continue
                if path == "/v1/saves/{item_id}/image":
                    assert result["content"]["image/jpeg"]["schema"]["format"] == "binary"
                    assert result["content"]["image/png"]["schema"]["format"] == "binary"
                    continue
                if path == "/v1/multimodal/captures/{capture_id}/assets/{asset_id}" and method == "get":
                    assert set(result["content"]) == {"image/jpeg", "image/png", "audio/mp4", "audio/wav"}
                    assert all(value["schema"] == {"type": "string", "format": "binary"} for value in result["content"].values())
                    continue
                output = result["content"]["application/json"]["schema"]
                assert output.get("$ref", "").startswith("#/components/schemas/"), (path, method, output)
            assert operation["responses"]["422"]["content"]["application/json"]["schema"]["$ref"] == "#/components/schemas/ErrorEnvelope"
            if method in {"post", "patch", "delete"}:
                key = next(parameter for parameter in operation["parameters"] if parameter["name"] == "Idempotency-Key")
                assert key["in"] == "header" and key["required"] is True

    # Missing mutation headers keep the existing runtime error contract.
    missing_key = client.post("/v1/saves", json={"url": "https://example.com/no-key", "title": "Desk"})
    assert missing_key.status_code == 400
    assert missing_key.json()["error"]["code"] == "idempotency_key_required"
