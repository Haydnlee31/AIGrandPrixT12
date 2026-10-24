"""Bounded hosted validation with synthetic content and API-only cleanup.

Creates one disposable capture, runs two multimodal analyses (the second after
a reviewed transcript), and one native preview. Server retries may incur extra
provider requests. Never requests Explore, recommendations, or the full Library.
The supplied account's existing deletion contract expires its cached mutation
receipts, so run during a quiet validation window. A second account key is
optional; without it this verifies authentication, not cross-account isolation.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlencode, urlsplit
import uuid

import httpx

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from backend.app.capture_preview import PreviewResult
from scripts.validate_multimodal_live import (
    CORRECTED_VOICE, SAFE_PROVIDER_CODES, VOICE_FRAGMENT, ValidationFailure,
    audio_fixture, common_checks, native_decode, normalize, require, watch_image,
)
from scripts.smoke_astra import sample_image


class HostedFailure(Exception):
    def __init__(self, check, *, status=None, code=None):
        self.check, self.status = check, status
        self.code = code if code in SAFE_PROVIDER_CODES else None
        super().__init__("Hosted validation failed")


class HostedAPI:
    """No redirects or secret-bearing error output; repeat mutations keep a key."""
    def __init__(self, client, token, *, secondary_token=None, bypass=None):
        self.client, self.token, self.secondary_token = client, token, secondary_token
        self.bypass = bypass
        self.requests = 0

    def __call__(self, method, path, body=None, *, expected=200, auth="primary", key=None, binary=False):
        if not path.startswith("/v1/") and path != "/health":
            raise HostedFailure("unsafe_request_path")
        headers = {}
        token = {"primary": self.token, "secondary": self.secondary_token,
                 "invalid": "invalid-hosted-validation-credential", "anonymous": None}[auth]
        if token:
            headers["Authorization"] = f"Bearer {token}"
        if self.bypass:
            headers["x-vercel-protection-bypass"] = self.bypass
        if method in {"POST", "PATCH", "DELETE"}:
            headers["Idempotency-Key"] = key or "hosted-" + uuid.uuid4().hex
        # Native preview is stateless but billable and has no durable receipt:
        # don't automatically repeat it after a lost response.
        attempts = 1 if path == "/v1/capture-preview" else 3
        response = None
        for attempt in range(attempts):
            try:
                self.requests += 1
                response = self.client.request(method, path, json=body, headers=headers)
                break
            except httpx.TransportError:
                if attempt + 1 == attempts:
                    raise HostedFailure("http_transport") from None
                time.sleep(1)
        if response.status_code != expected:
            code = None
            try:
                code = response.json().get("error", {}).get("code")
            except (ValueError, AttributeError):
                pass
            raise HostedFailure("http_status", status=response.status_code, code=code)
        if binary:
            return response.content
        try:
            return response.json()
        except ValueError:
            raise HostedFailure("http_json") from None


class VercelClient:
    """Authorized CLI protection bypass; app credentials never enter argv/logs."""
    def __init__(self, executable, deployment, config, scope):
        self.executable, self.deployment, self.config, self.scope = executable, deployment, config, scope

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def request(self, method, path, *, json=None, headers=None):
        import json as json_module
        with tempfile.TemporaryDirectory(prefix="mymah-vercel-request-") as temporary:
            directory = Path(temporary)
            config, response_path = directory / "curl.conf", directory / "response"
            lines = ["header = " + json_module.dumps(f"{name}: {value}") for name, value in (headers or {}).items()]
            arguments = [str(self.executable), "curl", path, "--deployment", self.deployment,
                "--scope", self.scope, "--global-config", str(self.config), "--", "--silent", "--show-error",
                "--max-time", "120", "--config", str(config), "--request", method,
                "--output", str(response_path), "--write-out", "%{http_code}"]
            if json is not None:
                body = directory / "body.json"
                body.touch(mode=0o600)
                body.write_text(json_module.dumps(json), encoding="utf-8")
                lines.append('header = "Content-Type: application/json"')
                arguments.extend(["--data-binary", "@" + str(body)])
            config.touch(mode=0o600)
            config.write_text("\n".join(lines) + "\n", encoding="utf-8")
            try:
                completed = subprocess.run(arguments, timeout=150, capture_output=True,
                    env={**os.environ, "VERCEL_TELEMETRY_DISABLED": "1"})
            except (OSError, subprocess.TimeoutExpired):
                raise httpx.ConnectError("Authorized deployment transport failed") from None
            status = completed.stdout.strip()[-3:]
            if completed.returncode or not status.isdigit() or not response_path.exists():
                raise httpx.ConnectError("Authorized deployment transport failed")
            return httpx.Response(int(status), content=response_path.read_bytes())


def run_validation(api, audio, mime, *, wait_seconds=420, poll_seconds=2,
                   decode=None, progress=lambda _: None, report_changed=lambda _: None):
    started = time.monotonic()
    marker = "validation" + uuid.uuid4().hex
    report = {"status": "failed", "marker": marker, "checks": [], "stages": [],
              "cleanup": "not_needed", "limitations": [],
              "submitted_ai_operations": {"multimodal_analyses": 0, "transcription": 0, "native_preview": 0}}
    capture_id = save_id = None
    publish_key = "hosted-publish-" + uuid.uuid4().hex
    publish_revision = None
    capture = None
    create_body = None
    create_key = "hosted-create-" + uuid.uuid4().hex

    def check(name, condition=True):
        require(condition, name)
        report["checks"].append(name)
        report_changed(report)

    def wait_ready(value):
        deadline = time.monotonic() + wait_seconds
        while value["stage"] not in {"ready", "failed"}:
            stage = value["stage"]
            if not report["stages"] or report["stages"][-1] != stage:
                report["stages"].append(stage)
                progress({"stage": stage})
                report_changed(report)
            if time.monotonic() >= deadline:
                raise HostedFailure("serverless_worker_deadline")
            time.sleep(poll_seconds)
            value = api("GET", f"/v1/multimodal/captures/{capture_id}")
        if value["stage"] == "failed":
            raise HostedFailure("serverless_worker_failed", code=value.get("error_code"))
        return value

    try:
        health = api("GET", "/health", auth="anonymous")
        check("combined_health_ready", health.get("ready") is True and health.get("multimodal") is True)
        identity = api("GET", "/v1/me")
        check("account_authenticated", bool(identity.get("user_id")))
        caps = api("GET", "/v1/multimodal/capabilities")
        check("multimodal_enabled", caps.get("enabled") is True and {"image", "audio"}.issubset(caps.get("content_types", [])))
        catalog = api("GET", "/v1/catalog/status")
        check("native_catalog_route", isinstance(catalog.get("catalog_count"), int))
        report["catalog"] = {key: catalog.get(key) for key in ("status", "catalog_count")}
        for auth in ("anonymous", "invalid"):
            api("GET", "/v1/multimodal/capabilities", auth=auth, expected=401)
            api("GET", "/v1/catalog/status", auth=auth, expected=401)
        check("shared_and_native_authentication_enforced")
        if api.secondary_token:
            other = api("GET", "/v1/me", auth="secondary")
            check("different_secondary_account", other.get("user_id") != identity["user_id"])
        else:
            report["limitations"].append("Cross-account isolation requires a second valid account; hosted checks cover unauthenticated/invalid access only.")

        initial_sync = api("GET", "/v1/sync")["revision"]
        watch = watch_image()
        lamp = base64.b64decode(sample_image().split(",", 1)[1])
        create_body = {
            "title": f"{marker} lamp and wristwatch illustrations",
            "text": "Two synthetic product illustrations: a desk lamp and a digital wristwatch.",
            "url": "https://www.pinterest.com/pin/" + marker,
            "client": "ios_app",
        }
        # Persist the nonsecret synthetic create receipt before sending, so an
        # interrupted process can recover the one fixture without listing data.
        report["fixture_create"] = {"key": create_key, "body": create_body}
        report["cleanup"] = "pending"
        report_changed(report)
        capture = api("POST", "/v1/multimodal/captures", create_body, key=create_key, expected=201)
        capture_id = capture["id"]
        report["fixture_capture_id"] = capture_id
        report["cleanup"] = "pending"
        report_changed(report)
        for raw, media_type in ((lamp, "image/png"), (watch, "image/png"), (audio, mime)):
            capture = api("POST", f"/v1/multimodal/captures/{capture_id}/assets", {
                "revision": capture["revision"], "media_type": media_type,
                "data_base64": base64.b64encode(raw).decode("ascii"),
            })
        image_ids = [asset["id"] for asset in capture["assets"] if asset["kind"] == "image"]
        voice = next(asset for asset in capture["assets"] if asset["kind"] == "audio")
        report["submitted_ai_operations"]["multimodal_analyses"] += 1
        report["submitted_ai_operations"]["transcription"] += 1
        capture = wait_ready(api("POST", f"/v1/multimodal/captures/{capture_id}/analyze", {"revision": capture["revision"]}))
        common_checks(capture, image_ids)
        check("multimodal_grounded_images", len(capture["result"]["analysis"]["products"]) >= 2)
        voice = next(asset for asset in capture["assets"] if asset["kind"] == "audio")
        check("recorded_voice_transcribed", normalize(VOICE_FRAGMENT) in normalize(voice["transcript"] or ""))
        check("voice_cited", voice["id"] in capture["result"]["source_assets"])
        check("predictive_prompts", len(capture["result"]["preview"]["prompts"]) == 3)

        capture = api("PATCH", f"/v1/multimodal/captures/{capture_id}/assets/{voice['id']}", {
            "revision": capture["revision"], "transcript": CORRECTED_VOICE,
        })
        check("correction_invalidates_old_result", capture["result"] is None and capture["stage"] == "draft")
        report["submitted_ai_operations"]["multimodal_analyses"] += 1
        capture = wait_ready(api("POST", f"/v1/multimodal/captures/{capture_id}/analyze", {"revision": capture["revision"]}))
        common_checks(capture, image_ids)
        corrected = next(asset for asset in capture["assets"] if asset["kind"] == "audio")
        check("reviewed_transcript_retained", corrected["transcript"] == CORRECTED_VOICE and corrected["transcript_origin"] == "user")
        intents = capture["result"]["analysis"]["intent_context"]
        check("corrected_context_used", any("fabric" in normalize(text) for text in intents) and not any("dad" in normalize(text) for text in intents))
        if decode:
            with tempfile.TemporaryDirectory(prefix="mymah-hosted-decode-") as folder:
                decode(capture, Path(folder))
            check("hosted_response_native_sdk_decode")

        publish_revision = capture["revision"]
        published = api("POST", f"/v1/multimodal/captures/{capture_id}/publish", {"revision": publish_revision}, key=publish_key)
        save_id = published["id"]
        report["fixture_save_id"] = save_id
        report_changed(report)
        replay = api("POST", f"/v1/multimodal/captures/{capture_id}/publish", {"revision": publish_revision}, key=publish_key)
        check("publication_idempotent", replay["id"] == save_id)
        saved = api("GET", f"/v1/saves/{save_id}")
        check("shared_library_publication", saved.get("has_image") is True and saved["analysis"]["schema_version"] == 1)
        check("shared_contextual_prompts", len(saved["features"]["multimodal_preview"]["prompts"]) == 3)
        check("platform_source_preserved", saved["source"] == "pinterest")
        found = api("GET", "/v1/library/search?" + urlencode({"q": marker}))
        check("unique_fixture_search", any(item["id"] == save_id for item in found["items"]))
        check("publication_sync_advanced", api("GET", "/v1/sync")["revision"] > initial_sync)
        for route in (f"/v1/multimodal/captures/{capture_id}",
                      f"/v1/multimodal/captures/{capture_id}/assets/{voice['id']}",
                      f"/v1/saves/{save_id}", f"/v1/saves/{save_id}/image"):
            api("GET", route, auth="anonymous", expected=401)
            api("GET", route, auth="invalid", expected=401)
            if api.secondary_token:
                api("GET", route, auth="secondary", expected=404)
        check("private_content_requires_valid_account")
        if api.secondary_token:
            check("cross_account_content_hidden")
        check("published_image_readable", bool(api("GET", f"/v1/saves/{save_id}/image", binary=True)))
        report["submitted_ai_operations"]["native_preview"] += 1
        preview = api("POST", "/v1/capture-preview", {
            "title": "Synthetic rectangular digital wristwatch " + marker,
            "note": "I prefer the rectangular face for everyday wear.",
            "image_data_url": "data:image/png;base64," + base64.b64encode(watch).decode("ascii"),
        })
        PreviewResult.model_validate(preview)
        check("native_ios_preview_live", preview["schema_version"] == 2 and len(preview["prompts"]) == 3)
        report["status"] = "passed"
    except (HostedFailure, ValidationFailure) as error:
        report["failure"] = {"check": error.check}
        if isinstance(error, HostedFailure):
            report["failure"].update({"http_status": error.status, "provider_code": error.code})
    except Exception as error:
        report["failure"] = {"check": "validation_execution", "error_type": type(error).__name__}
    finally:
        if create_body and not capture_id:
            try:
                # A lost create response may conceal a committed fixture.
                # Replaying exactly the same receipt cannot create a duplicate.
                recovered = api("POST", "/v1/multimodal/captures", create_body, key=create_key, expected=201)
                capture_id = recovered["id"]
                report["fixture_capture_id"] = capture_id
            except Exception as error:
                report["status"], report["cleanup"] = "failed", "needs_attention"
                report["cleanup_error"] = {"check": "create_receipt_recovery", "error_type": type(error).__name__}
        if capture_id:
            try:
                # Publication can commit before a network response is lost. Read
                # only this fixture to recover its ID before choosing deletion.
                current = api("GET", f"/v1/multimodal/captures/{capture_id}")
                save_id = save_id or current.get("published_save_id")
                path = f"/v1/saves/{save_id}" if save_id else f"/v1/multimodal/captures/{capture_id}"
                api("DELETE", path)
                api("GET", f"/v1/multimodal/captures/{capture_id}", expected=404)
                for asset in current["assets"]:
                    api("GET", f"/v1/multimodal/captures/{capture_id}/assets/{asset['id']}", expected=404)
                if save_id:
                    api("GET", f"/v1/saves/{save_id}", expected=404)
                    api("GET", f"/v1/saves/{save_id}/image", expected=404)
                    found = api("GET", "/v1/library/search?" + urlencode({"q": marker}))
                    require(not any(item["id"] == save_id for item in found["items"]), "fixture_removed_from_search")
                    api("POST", f"/v1/multimodal/captures/{capture_id}/publish", {"revision": publish_revision}, key=publish_key, expected=410)
                report["cleanup"] = "verified"
                check("fixture_and_media_removed")
            except Exception as error:
                report["status"], report["cleanup"] = "failed", "needs_attention"
                report["cleanup_error"] = {"check": getattr(error, "check", "cleanup_execution"), "error_type": type(error).__name__}
        report["elapsed_seconds"] = round(time.monotonic() - started, 2)
        report["http_requests"] = api.requests
        report_changed(report)
    return report


def read_secret(path):
    value = path.read_text(encoding="utf-8").strip()
    if not value or len(value) > 16384 or any(char.isspace() for char in value):
        raise HostedFailure("credential_file_invalid")
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="Exact staged HTTPS origin; redirects are refused")
    parser.add_argument("--account-key-file", type=Path, required=True)
    parser.add_argument("--second-account-key-file", type=Path)
    parser.add_argument("--protection-bypass-file", type=Path)
    parser.add_argument("--audio-file", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--decode-native", action="store_true")
    parser.add_argument("--vercel-cli", type=Path, help="Use an already authenticated Vercel CLI for protected deployments")
    parser.add_argument("--vercel-config", type=Path)
    parser.add_argument("--vercel-scope")
    args = parser.parse_args(argv)
    try:
        origin = urlsplit(args.url)
        require(origin.scheme == "https" and origin.hostname and not origin.username and not origin.password
                and not origin.query and not origin.fragment and origin.path in {"", "/"}, "https_origin_required")
        require(not any((args.vercel_cli, args.vercel_config, args.vercel_scope))
                or all((args.vercel_cli, args.vercel_config, args.vercel_scope)), "complete_vercel_transport_required")
        token = read_secret(args.account_key_file)
        secondary = read_secret(args.second_account_key_file) if args.second_account_key_file else None
        bypass = read_secret(args.protection_bypass_file) if args.protection_bypass_file else None
        args.report.parent.mkdir(parents=True, exist_ok=True)

        def save_report(report):
            args.report.touch(mode=0o600, exist_ok=True)
            args.report.chmod(0o600)
            args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

        with tempfile.TemporaryDirectory(prefix="mymah-hosted-audio-") as folder:
            audio, mime = audio_fixture(Path(folder), args.audio_file)
            transport = (VercelClient(args.vercel_cli, args.url, args.vercel_config, args.vercel_scope) if args.vercel_cli
                else httpx.Client(base_url=args.url.rstrip("/"), timeout=120, follow_redirects=False))
            with transport as client:
                api = HostedAPI(client, token, secondary_token=secondary, bypass=bypass)
                report = run_validation(api, audio, mime, decode=native_decode if args.decode_native else None,
                    progress=lambda value: print(json.dumps(value), flush=True), report_changed=save_report)
        print(json.dumps(report, indent=2))
        return 0 if report["status"] == "passed" else 1
    except Exception as error:
        print(json.dumps({"status": "failed", "check": getattr(error, "check", "validation_setup"),
                          "error_type": type(error).__name__}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
