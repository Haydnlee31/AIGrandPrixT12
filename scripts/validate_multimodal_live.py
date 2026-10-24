"""Explicit, billable multimodal validation using isolated synthetic fixtures.

At most five analysis invocations and one transcription invocation are allowed.
Each analysis may make one corrective request within the provider's existing
deadline (at most ten Responses requests total). No user's Library is accessed.
Keys are read only from the process or an explicitly supplied --env-file.
"""
from __future__ import annotations

import argparse
import base64
from contextlib import contextmanager
from io import BytesIO
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from PIL import Image, ImageDraw
from backend.app.multimodal_provider import MultimodalProvider, RESPONSES_ENDPOINT, TRANSCRIPTION_ENDPOINT, validate_audio
from backend.app.predictive import ProviderError
from backend.app.server_config import ServerConfigError, load_server_env
from scripts.smoke_astra import sample_image


VOICE_TEXT = "I want this watch as a gift for my dad. Please avoid metal straps."
VOICE_FRAGMENT = "gift for my dad"
CORRECTED_VOICE = "Actually, this watch is for me. I prefer a fabric strap. This is not a gift."
SAFE_PROVIDER_CODES = {
    "multimodal_authentication_failed", "multimodal_key_missing", "multimodal_rate_limited",
    "multimodal_timeout", "multimodal_unavailable", "multimodal_request_rejected",
    "multimodal_invalid_output", "multimodal_invalid_response", "multimodal_incomplete_response",
    "multimodal_refused", "multimodal_invalid_transcript", "multimodal_invalid_audio",
    "multimodal_response_too_large", "multimodal_result_too_large", "validation_budget_exceeded",
}


class ValidationFailure(Exception):
    def __init__(self, check, provider_code=None):
        self.check = check
        self.provider_code = provider_code if provider_code in SAFE_PROVIDER_CODES else None
        super().__init__("Multimodal validation failed")


def require(condition, check):
    if not condition:
        raise ValidationFailure(check)


class MeasuredProvider(MultimodalProvider):
    """Count actual endpoint requests, including corrective generations."""
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.analysis_http_requests = 0
        self.transcription_http_requests = 0

    async def _request(self, endpoint, **kwargs):
        if endpoint == RESPONSES_ENDPOINT:
            if self.analysis_http_requests >= 10:
                raise ProviderError("validation_budget_exceeded", False)
            self.analysis_http_requests += 1
        elif endpoint == TRANSCRIPTION_ENDPOINT:
            if self.transcription_http_requests >= 1:
                raise ProviderError("validation_budget_exceeded", False)
            self.transcription_http_requests += 1
        return await super()._request(endpoint, **kwargs)


class BudgetedProvider:
    def __init__(self, provider):
        self.provider = provider
        self.model = provider.model
        self.transcription_model = provider.transcription_model
        self.version = provider.version
        self.analysis_calls = 0
        self.transcription_calls = 0

    def analyze(self, value):
        if self.analysis_calls >= 5:
            raise ProviderError("validation_budget_exceeded", False)
        self.analysis_calls += 1
        return self.provider.analyze(value)

    def transcribe(self, raw, mime):
        if self.transcription_calls >= 1:
            raise ProviderError("validation_budget_exceeded", False)
        self.transcription_calls += 1
        return self.provider.transcribe(raw, mime)

    def close(self):
        self.provider.close()

    def counts(self):
        return {"analysis_invocations": self.analysis_calls, "transcription_invocations": self.transcription_calls,
                "responses_requests": getattr(self.provider, "analysis_http_requests", None),
                "transcription_requests": getattr(self.provider, "transcription_http_requests", None)}


@contextmanager
def isolated_database_environment(path):
    previous = os.environ.get("DATABASE_URL")
    os.environ["DATABASE_URL"] = f"sqlite:///{path}"
    try:
        yield os.environ["DATABASE_URL"]
    finally:
        if previous is None:
            os.environ.pop("DATABASE_URL", None)
        else:
            os.environ["DATABASE_URL"] = previous


def watch_image():
    image = Image.new("RGB", (320, 320), "#f4f0e8")
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((129, 12, 191, 308), radius=12, fill="#4d5c69")
    draw.rounded_rectangle((83, 94, 237, 226), radius=24, fill="#33383d", outline="#858f98", width=5)
    draw.rounded_rectangle((100, 117, 220, 200), radius=8, fill="#c4cdb6")
    draw.text((127, 146), "10:09", fill="#182824", font_size=24)
    stream = BytesIO()
    image.save(stream, "PNG")
    return stream.getvalue()


def audio_fixture(directory, path=None):
    """Generate speech with local macOS tools, or validate an explicit audio file."""
    if path is not None:
        source = Path(path)
        with source.open("rb") as stream:
            raw = stream.read(4 * 1024 * 1024 + 1)
        mime = "audio/wav" if source.suffix.casefold() == ".wav" else "audio/mp4"
        return raw, validate_audio(raw, mime)
    say, convert = shutil.which("say"), shutil.which("afconvert")
    if not say or not convert:
        raise ValidationFailure("audio_fixture_required")
    aiff, wav = directory / "voice.aiff", directory / "voice.wav"
    subprocess.run([say, "-o", str(aiff), VOICE_TEXT], check=True, timeout=30, capture_output=True)
    subprocess.run([convert, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)],
                   check=True, timeout=30, capture_output=True)
    raw = wav.read_bytes()
    return raw, validate_audio(raw, "audio/wav")


def normalize(text):
    return " ".join(re.findall(r"\w+", text.casefold()))


def native_decode(capture, directory):
    """Decode the real response with the actual Swift SDK in a temporary binary."""
    compiler = shutil.which("xcrun")
    if compiler is None:
        raise ValidationFailure("native_decoder_unavailable")
    fixture = directory / "capture.json"
    fixture.write_text(json.dumps(capture), encoding="utf-8")
    source = directory / "Decode.swift"
    source.write_text('''import Foundation
@main struct Decode {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let capture = try CommonThreadClient.decoder().decode(MultimodalCapture.self, from: data)
        guard capture.status == "ready", let result = capture.result,
              result.analysis.schemaVersion == 1, result.preview.schemaVersion == 2 else {
            throw MultimodalClientError.invalidResponse
        }
    }
}
''', encoding="utf-8")
    sources = sorted((ROOT / "clients/ios/Sources/CommonThreadKit").glob("*.swift"))
    executable = directory / "decode"
    compiled = subprocess.run([compiler, "swiftc", "-swift-version", "5", "-module-cache-path", str(directory / "modules"),
                               *map(str, sources), str(source), "-o", str(executable)],
                              timeout=180, capture_output=True)
    require(compiled.returncode == 0, "native_decoder_build")
    decoded = subprocess.run([str(executable), str(fixture)], timeout=30, capture_output=True)
    require(decoded.returncode == 0, "native_response_decode")


def common_checks(capture, image_ids):
    from backend.app.capture_preview import PreviewOutput
    from backend.app.understanding import ProductAnalysis
    result = capture["result"]
    require(capture["status"] == "ready" and result is not None, "ready_result")
    ProductAnalysis.model_validate(result["analysis"])
    preview = result["preview"]
    require(preview["schema_version"] == 2, "native_schema_version")
    PreviewOutput.model_validate({name: value for name, value in preview.items() if name not in {"schema_version", "analyzed_at"}})
    asset_ids = {asset["id"] for asset in capture["assets"]}
    require(set(result["source_assets"]).issubset(asset_ids), "evidence_asset_ownership")
    require(len(result["source_assets"]) == len(set(result["source_assets"])), "unique_evidence_assets")
    require(set(image_ids).issubset(result["source_assets"]), "all_images_used")
    for product in result["analysis"]["products"]:
        for fact in [product["brand"], product["model"], *product["attributes"]]:
            if fact is not None and fact["basis"] == "image":
                require(any(fact["evidence"].startswith(f"[{identifier}] ") for identifier in image_ids), "image_evidence_identity")
        require(not any(attribute["name"].casefold() in {"price", "cost", "discount", "stock", "availability", "merchant", "purchase_url"}
                        for attribute in product["attributes"]), "no_invented_commerce_facts")
    require(len(preview["prompts"]) in {0, 3}, "native_prompt_count")
    require([prompt["id"] for prompt in preview["prompts"]] in [[], ["p1", "p2", "p3"]], "native_prompt_identity")


def run_validation(provider, audio, mime, *, expected_audio_text=VOICE_FRAGMENT, decode_native=native_decode, live=True):
    from fastapi.testclient import TestClient
    from alembic import command
    from alembic.config import Config
    from backend.app.intelligence import DemoAnnotationProvider
    from backend.app.worker import run_once

    started = time.monotonic()
    budget = BudgetedProvider(provider)
    report = {"status": "failed", "mode": "live" if live else "mock", "analysis_model": provider.model,
              "transcription_model": provider.transcription_model, "checks": [], "cases": []}
    active = None
    try:
        with tempfile.TemporaryDirectory(prefix="mymah-multimodal-live-") as scratch:
            directory = Path(scratch)
            with isolated_database_environment(directory / "validation.db") as database_url:
                from backend.app.main import create_app
                config = Config(str(ROOT / "alembic.ini"))
                config.set_main_option("script_location", str(ROOT / "backend/migrations"))
                command.upgrade(config, "head")
                fallback = DemoAnnotationProvider()
                app = create_app(database_url=database_url, embedded_worker=False, annotation_provider=fallback,
                    multimodal_provider=budget, tokens={"live-fixture-token": "live-fixture-user", "other-fixture-token": "other-user"})
                with TestClient(app, headers={"Authorization": "Bearer live-fixture-token"}) as client:
                    def api(method, path, body=None, *, key=None, expected=200, headers=None):
                        request_headers = dict(headers or {})
                        if method != "GET":
                            request_headers["Idempotency-Key"] = key or uuid.uuid4().hex
                        response = client.request(method, path, json=body, headers=request_headers)
                        if response.status_code != expected:
                            try:
                                code = response.json().get("error", {}).get("code")
                            except (ValueError, TypeError, AttributeError):
                                code = None
                            raise ValidationFailure("api_contract", code)
                        return response.json()

                    def new_case(name, body, images=(), with_audio=False):
                        nonlocal active
                        active = {"name": name, "status": "running", "stages": [], "checks": []}
                        report["cases"].append(active)
                        capture = api("POST", "/v1/multimodal/captures", body, expected=201)
                        for image in images:
                            capture = api("POST", f"/v1/multimodal/captures/{capture['id']}/assets",
                                {"revision": capture["revision"], "media_type": "image/png", "data_base64": base64.b64encode(image).decode()})
                        if with_audio:
                            capture = api("POST", f"/v1/multimodal/captures/{capture['id']}/assets",
                                {"revision": capture["revision"], "media_type": mime, "data_base64": base64.b64encode(audio).decode()})
                        return capture

                    def analyze(capture):
                        capture = api("POST", f"/v1/multimodal/captures/{capture['id']}/analyze", {"revision": capture["revision"]})
                        expected_revision = capture["revision"]
                        deadline = time.monotonic() + 130
                        case_started = time.monotonic()
                        while True:
                            if capture["stage"] not in active["stages"]:
                                active["stages"].append(capture["stage"])
                            require(capture["revision"] == expected_revision, "stable_processing_revision")
                            if capture["status"] == "ready":
                                active["elapsed_seconds"] = round(time.monotonic() - case_started, 2)
                                common_checks(capture, [a["id"] for a in capture["assets"] if a["kind"] == "image"])
                                active["checks"].extend(["structured_analysis", "native_preview", "evidence_identity", "no_invented_commerce_facts"])
                                return capture
                            if capture["status"] == "enrichment_failed":
                                raise ValidationFailure("provider_pipeline", capture.get("error_code"))
                            require(time.monotonic() < deadline, "processing_deadline")
                            if not run_once(app.state.factory, fallback, app.state.multimodal):
                                time.sleep(0.1)
                            capture = api("GET", f"/v1/multimodal/captures/{capture['id']}")

                    lamp = base64.b64decode(sample_image().split(",", 1)[1])
                    watch = watch_image()
                    capture = analyze(new_case("text_only_uncertain_identity", {
                        "title": "A digital wristwatch", "text": "Caption: a wristwatch nicknamed Duo. The brand is not identified.",
                        "note": "I need water resistance, but that is not stated in the caption."}))
                    require(bool(capture["result"]["analysis"]["products"]), "text_product_detected")
                    require(all(p["brand"] is None for p in capture["result"]["analysis"]["products"]), "unknown_brand_remains_unknown")
                    require(not any("water" in attribute["name"].casefold() or "waterproof" in attribute["value"].casefold()
                        for product in capture["result"]["analysis"]["products"] for attribute in product["attributes"]), "preference_is_not_a_specification")
                    active["checks"].extend(["unknown_brand", "preferences_not_product_specs"]); active["status"] = "passed"

                    capture = analyze(new_case("single_image_with_note", {"title": "A lamp illustration", "note": "I want a lamp for my reading corner."}, [lamp]))
                    require(bool(capture["result"]["analysis"]["products"]), "image_product_detected")
                    require(len(capture["result"]["preview"]["prompts"]) == 3, "image_predictive_prompts")
                    active["checks"].append("image_predictive_prompts"); active["status"] = "passed"

                    capture = analyze(new_case("multiple_images_with_exclusion", {
                        "title": "Lamp and wristwatch ideas", "note": "Compare their shapes. I do not want metal straps."}, [lamp, watch]))
                    require(len(capture["result"]["analysis"]["products"]) >= 2, "multiple_products_detected")
                    require(any("metal" in normalize(intent) and ("not" in normalize(intent) or "avoid" in normalize(intent))
                        for intent in capture["result"]["analysis"]["intent_context"]), "negative_preference_preserved")
                    active["checks"].extend(["multiple_products", "negative_preference"]); active["status"] = "passed"

                    capture = analyze(new_case("image_and_recorded_voice", {"title": "A wristwatch illustration"}, [watch], with_audio=True))
                    voice = next(asset for asset in capture["assets"] if asset["kind"] == "audio")
                    require(normalize(expected_audio_text) in normalize(voice["transcript"] or ""), "transcription_expected_content")
                    require(voice["id"] in capture["result"]["source_assets"], "voice_source_cited")
                    require(bool(capture["result"]["analysis"]["intent_context"]), "voice_intent_extracted")
                    active["checks"].extend(["transcription_expected_content", "voice_intent", "voice_source_citation"]); active["status"] = "passed"

                    active = {"name": "reviewed_transcript_reanalysis", "status": "running", "stages": [], "checks": []}
                    report["cases"].append(active)
                    capture = api("PATCH", f"/v1/multimodal/captures/{capture['id']}/assets/{voice['id']}",
                        {"revision": capture["revision"], "transcript": CORRECTED_VOICE})
                    require(capture["result"] is None and capture["stage"] == "draft", "correction_invalidates_previous_analysis")
                    capture = analyze(capture)
                    corrected = next(asset for asset in capture["assets"] if asset["kind"] == "audio")
                    require(corrected["transcript"] == CORRECTED_VOICE and corrected.get("transcript_origin") == "user", "reviewed_transcript_preserved")
                    require(any("fabric" in normalize(intent) for intent in capture["result"]["analysis"]["intent_context"]), "corrected_preference_used")
                    require(not any("dad" in normalize(intent) for intent in capture["result"]["analysis"]["intent_context"]), "old_voice_context_removed")
                    require(budget.transcription_calls == 1, "no_retranscription_after_review")
                    active["checks"].extend(["correction_invalidation", "corrected_preference", "no_retranscription"]); active["status"] = "passed"

                    decode_native(capture, directory)
                    report["checks"].append("real_response_native_sdk_decode")
                    publish_key = uuid.uuid4().hex
                    published = api("POST", f"/v1/multimodal/captures/{capture['id']}/publish", {"revision": capture["revision"]}, key=publish_key)
                    require(published["status"] == "ready", "explicit_shared_publication")
                    saved = api("GET", f"/v1/saves/{published['id']}")
                    require(saved["analysis"]["schema_version"] == 1 and saved["has_image"], "legacy_library_decode")
                    found = api("GET", "/v1/library/search?q=fabric")
                    require(any(item["id"] == published["id"] for item in found["items"]), "voice_preference_searchable")
                    api("GET", f"/v1/multimodal/captures/{capture['id']}", headers={"Authorization": "Bearer other-fixture-token"}, expected=404)
                    api("DELETE", f"/v1/saves/{published['id']}")
                    api("GET", f"/v1/multimodal/captures/{capture['id']}", expected=404)
                    api("GET", f"/v1/multimodal/captures/{capture['id']}/assets/{voice['id']}", expected=404)
                    api("POST", f"/v1/multimodal/captures/{capture['id']}/publish", {"revision": capture["revision"]}, key=publish_key, expected=410)
                    require(not api("GET", "/v1/library/search?q=fabric")["items"], "deleted_content_removed_from_search")
                    report["checks"].extend(["explicit_publication", "legacy_library_compatibility", "voice_search",
                        "account_isolation", "deletion_revocation", "retry_tombstone"])
                    require(budget.analysis_calls == 5 and budget.transcription_calls == 1, "bounded_complete_validation")
                    report["status"] = "passed"
    except ValidationFailure as error:
        report["failure"] = {"check": error.check, "provider_code": error.provider_code}
    except ProviderError as error:
        report["failure"] = {"check": "provider_configuration", "provider_code": error.code if error.code in SAFE_PROVIDER_CODES else "provider_error"}
    except Exception as error:
        report["failure"] = {"check": "validation_execution", "error_type": type(error).__name__}
    finally:
        if active is not None and active["status"] == "running":
            active["status"] = "failed"
        report["counts"] = budget.counts()
        report["elapsed_seconds"] = round(time.monotonic() - started, 2)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, help="Explicit backend dotenv file; only inference settings are read")
    parser.add_argument("--report", type=Path, help="Write sanitized JSON, preferably under ignored local-data/")
    parser.add_argument("--audio-file", type=Path, help="Use a WAV or AAC M4A fixture instead of generating local speech")
    parser.add_argument("--expected-audio-text", default=VOICE_FRAGMENT, help="A short phrase expected in the fixture transcript")
    args = parser.parse_args(argv)
    provider = None
    try:
        if args.env_file:
            load_server_env(args.env_file)
        require(bool(args.expected_audio_text.strip()), "expected_audio_text_required")
        with tempfile.TemporaryDirectory(prefix="mymah-live-audio-") as scratch:
            audio, mime = audio_fixture(Path(scratch), args.audio_file)
            provider = MeasuredProvider()
            report = run_validation(provider, audio, mime, expected_audio_text=args.expected_audio_text)
    except ServerConfigError:
        report = {"status": "failed", "failure": {"check": "explicit_configuration"}}
    except ValidationFailure as error:
        report = {"status": "failed", "failure": {"check": error.check, "provider_code": error.provider_code}}
    except ProviderError as error:
        report = {"status": "failed", "failure": {"check": "provider_configuration", "provider_code": error.code if error.code in SAFE_PROVIDER_CODES else "provider_error"}}
    except Exception as error:
        report = {"status": "failed", "failure": {"check": "validation_setup", "error_type": type(error).__name__}}
    finally:
        if provider is not None:
            provider.close()
    if args.report:
        try:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        except OSError:
            report["status"] = "failed"
            report["report_write_failed"] = True
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
