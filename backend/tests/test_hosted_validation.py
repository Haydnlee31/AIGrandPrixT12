"""Exercise safe hosted orchestration against the real API with mock providers."""
import json
from pathlib import Path
import subprocess

from fastapi.testclient import TestClient
import httpx
import pytest

from backend.app.combined import create_app
from backend.app.intelligence import DemoAnnotationProvider
from backend.app.worker import run_once
from backend.tests.test_capture_preview import envelope
from backend.tests.test_multimodal_live_validation import FixtureProvider, wav
from scripts.validate_hosted_multimodal import HostedAPI, HostedFailure, VercelClient, main, run_validation


@pytest.fixture
def wire(tmp_path):
    app = create_app(tokens={"private-primary": "alex", "private-secondary": "sam"}, api_key="fake-key",
        price_directory=tmp_path / "prices", relay_options={"price_background": False,
            "transport": httpx.MockTransport(lambda _: httpx.Response(200, json=envelope()))},
        main_options={"database_url": f"sqlite:///{tmp_path / 'hosted.db'}", "demo_mode": False,
            "annotation_provider": DemoAnnotationProvider(), "embedded_worker": False,
            "multimodal_enabled": True, "multimodal_provider": FixtureProvider(), "allowed_origins": []})
    with TestClient(app) as client:
        seen = []

        class Client:
            def request(self, method, path, **kwargs):
                seen.append((method, path))
                if method == "GET" and "/v1/multimodal/captures/" in path:
                    shared = app.state.main
                    run_once(shared.state.factory, shared.state.annotation_provider, shared.state.multimodal)
                return client.request(method, path, **kwargs)

        yield HostedAPI(Client(), "private-primary", secondary_token="private-secondary"), seen


def test_hosted_full_journey_preserves_other_content_and_checks_cross_account(wire):
    api, seen = wire
    existing = api("POST", "/v1/multimodal/captures", {"title": "Existing user content"}, expected=201)
    seen.clear()
    decoded = []
    report = run_validation(api, wav(), "audio/wav", poll_seconds=0, decode=lambda capture, _: decoded.append(capture))
    assert report["status"] == "passed", report
    assert report["cleanup"] == "verified"
    assert "cross_account_content_hidden" in report["checks"]
    assert report["submitted_ai_operations"] == {"multimodal_analyses": 2, "transcription": 1, "native_preview": 1}
    assert len(decoded) == 1
    assert all("/explore" not in path and "/recommendations" not in path for _, path in seen)
    assert all(existing["id"] not in path for _, path in seen)
    assert api("GET", f"/v1/multimodal/captures/{existing['id']}")["title"] == "Existing user content"


def test_hosted_failure_before_publication_cleans_only_created_capture(wire):
    api, _ = wire
    real_call = api.__call__

    class FailureAPI:
        secondary_token = None

        @property
        def requests(self):
            return api.requests

        def __call__(self, method, path, *args, **kwargs):
            if method == "PATCH":
                raise HostedFailure("injected_failure")
            return real_call(method, path, *args, **kwargs)

    report = run_validation(FailureAPI(), wav(), "audio/wav", poll_seconds=0)
    assert report["status"] == "failed"
    assert report["failure"]["check"] == "injected_failure"
    assert report["cleanup"] == "verified"
    assert report["limitations"]
    assert report["submitted_ai_operations"] == {"multimodal_analyses": 1, "transcription": 1, "native_preview": 0}


def test_lost_create_response_recovers_same_receipt_and_cleans_fixture(wire):
    api, _ = wire

    class LostCreate:
        secondary_token = None
        lost = False

        @property
        def requests(self):
            return api.requests

        def __call__(self, method, path, *args, **kwargs):
            result = api(method, path, *args, **kwargs)
            if path == "/v1/multimodal/captures" and method == "POST" and not self.lost:
                self.lost = True
                raise HostedFailure("lost_create_response")
            return result

    report = run_validation(LostCreate(), wav(), "audio/wav", poll_seconds=0)
    assert report["status"] == "failed"
    assert report["failure"]["check"] == "lost_create_response"
    assert report["cleanup"] == "verified"
    assert report["fixture_capture_id"]


def test_native_failure_after_publish_still_erases_shared_media(wire):
    api, _ = wire
    request = api.client.request

    def native_failure(method, path, **kwargs):
        if path == "/v1/capture-preview":
            return httpx.Response(500, json={"error": {"message": "private-primary must never be reported"}})
        return request(method, path, **kwargs)

    api.client.request = native_failure
    report = run_validation(api, wav(), "audio/wav", poll_seconds=0)
    assert report["status"] == "failed"
    assert report["cleanup"] == "verified"
    assert report["failure"]["http_status"] == 500
    assert "private-primary" not in json.dumps(report)


def test_transport_retry_reuses_key_and_native_preview_is_never_retried():
    requests = []

    class Client:
        def request(self, method, path, **kwargs):
            requests.append(kwargs["headers"])
            raise httpx.ConnectError("secret-token")

    api = HostedAPI(Client(), "secret-token")
    with pytest.raises(HostedFailure):
        api("POST", "/v1/multimodal/captures", {"title": "Synthetic"})
    assert len(requests) == 3
    assert len({request["Idempotency-Key"] for request in requests}) == 1
    requests.clear()
    with pytest.raises(HostedFailure) as failure:
        api("POST", "/v1/capture-preview", {"title": "Synthetic"})
    assert len(requests) == 1
    assert "secret-token" not in str(failure.value)


def test_vercel_transport_keeps_credentials_out_of_process_arguments(monkeypatch, tmp_path):
    def execute(arguments, **kwargs):
        assert "private-account-key" not in " ".join(arguments)
        config = Path(arguments[arguments.index("--config") + 1])
        assert config.stat().st_mode & 0o777 == 0o600
        assert 'header = "Authorization: Bearer private-account-key"' in config.read_text()
        output = Path(arguments[arguments.index("--output") + 1])
        output.write_text('{"ready":true}')
        return subprocess.CompletedProcess(arguments, 0, b"200", b"CLI notices")

    monkeypatch.setattr(subprocess, "run", execute)
    transport = VercelClient(tmp_path / "cli", "https://app.example", tmp_path / "config", "team")
    response = transport.request("GET", "/health", headers={"Authorization": "Bearer private-account-key"})
    assert response.status_code == 200 and response.json()["ready"] is True


@pytest.mark.parametrize("url", ["http://app.example", "https://key@app.example", "https://app.example?secret=key", "https://app.example/path"])
def test_hosted_cli_rejects_secret_bearing_and_non_origin_urls(tmp_path, capsys, url):
    assert main(["--url", url, "--account-key-file", str(tmp_path / "no-key"), "--report", str(tmp_path / "report")]) == 1
    assert "key@app" not in capsys.readouterr().out
