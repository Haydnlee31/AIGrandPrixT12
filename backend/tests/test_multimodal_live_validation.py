"""The live harness is exercised with fake models; routine tests never incur API usage."""
from io import BytesIO
import json
from pathlib import Path
import wave

import pytest

from backend.app.server_config import ServerConfigError, load_server_env, read_server_env
from backend.app.predictive import ProviderError
from backend.app.multimodal_provider import MMInput
from scripts.validate_multimodal_live import BudgetedProvider, CORRECTED_VOICE, VOICE_TEXT, main, run_validation


def test_explicit_loader_is_allowlisted_inert_and_preserves_environment(tmp_path):
    path = tmp_path / ".env"
    path.write_text('''# Backend-only fixture settings
export ASTRA_API_KEY="fixture-key" # trailing comment
OPENAI_API_KEY='$(touch /tmp/must-not-execute)'
ASTRA_MODEL=gpt-6-astra
MULTIMODAL_TRANSCRIPTION_MODEL=gpt-transcribe
DATABASE_URL=must-not-change
UNRELATED=`must-not-execute`
''')
    values = read_server_env(path)
    assert set(values) == {"ASTRA_API_KEY", "OPENAI_API_KEY", "ASTRA_MODEL", "MULTIMODAL_TRANSCRIPTION_MODEL"}
    assert values["OPENAI_API_KEY"] == "$(touch /tmp/must-not-execute)"
    environment = {"ASTRA_API_KEY": "existing-fixture", "DATABASE_URL": "retained"}
    names = load_server_env(path, environ=environment)
    assert "ASTRA_API_KEY" not in names
    assert environment["ASTRA_API_KEY"] == "existing-fixture"
    assert environment["DATABASE_URL"] == "retained"
    load_server_env(path, environ=environment, overwrite=True)
    assert environment["ASTRA_API_KEY"] == "fixture-key"


@pytest.mark.parametrize("content", ['ASTRA_API_KEY="private-fixture', 'ASTRA_API_KEY=private-fixture extra', "ASTRA_API_KEY=" + "x" * 65536])
def test_invalid_configuration_never_exposes_source_text(tmp_path, content):
    path = tmp_path / ".env"
    path.write_text(content)
    with pytest.raises(ServerConfigError) as captured:
        read_server_env(path)
    assert "private-fixture" not in str(captured.value)
    assert str(path) not in str(captured.value)


def wav():
    stream = BytesIO()
    with wave.open(stream, "wb") as output:
        output.setnchannels(1); output.setsampwidth(2); output.setframerate(16000)
        output.writeframes(bytes(1600 * 2))
    return stream.getvalue()


class FixtureProvider:
    model = "fixture-model"
    transcription_model = "fixture-transcription"
    version = "fixture-model:multimodal-v1"

    def transcribe(self, raw, mime):
        assert raw and mime == "audio/wav"
        return VOICE_TEXT

    def analyze(self, value):
        products = []
        images = list(value.images)
        kinds = (["Lamp", "Wristwatch"] if len(images) == 2 else
                 ["Lamp" if "lamp" in value.title.casefold() else "Wristwatch"])
        for index, kind in enumerate(kinds):
            source = images[index][0] if images else None
            evidence = f"[{source}] Visible rectangular shape" if source else value.title
            products.append({"product_type": kind, "category_path": ["Products", kind], "brand": None, "model": None,
                "attributes": [{"name": "shape", "value": "Rectangular", "basis": "image" if source else "captured_text",
                    "evidence": evidence, "certainty": "observed"}], "use_cases": [], "search_terms": [kind]})
        intents = [text for _, text in value.transcripts] or ([value.note] if value.note else [])
        return {"analysis": {"schema_version": 1, "summary": "Saved shopping ideas.", "products": products,
                    "intent_context": intents, "uncertainties": ["Brand is unknown."]},
                "preview": {"product_name": kinds[0], "category_path": ["Products", kinds[0]], "brand": None,
                    "style": [], "summary": "Saved shopping ideas.", "uncertainties": ["Brand is unknown."],
                    "prompts": [{"id": f"p{index}", "text": text, "question": None} for index, text in enumerate([
                        "I like the rectangular shape.", "I want it for everyday use.", "I might choose this as a gift."], 1)],
                    "evidence": [products[0]["attributes"][0]["evidence"]], "schema_version": 2, "analyzed_at": 100},
                "source_assets": [identifier for identifier, _ in [*value.images, *value.transcripts]]}

    def close(self):
        pass


def test_call_budget_cannot_be_exceeded_by_worker_retries():
    provider = BudgetedProvider(FixtureProvider())
    for _ in range(1):
        provider.transcribe(b"fixture", "audio/wav")
    with pytest.raises(ProviderError) as captured:
        provider.transcribe(b"fixture", "audio/wav")
    assert captured.value.code == "validation_budget_exceeded"
    for _ in range(5):
        provider.analyze(MMInput(title="A watch", text="", note=""))
    with pytest.raises(ProviderError):
        provider.analyze(None)
    assert provider.analysis_calls == 5 and provider.transcription_calls == 1


def test_full_harness_uses_temporary_api_and_preserves_all_validation_steps():
    decoded = []
    report = run_validation(FixtureProvider(), wav(), "audio/wav", live=False,
        decode_native=lambda capture, directory: decoded.append(capture))
    assert report["status"] == "passed", report
    assert report["mode"] == "mock"
    assert len(report["cases"]) == 5
    assert all(case["status"] == "passed" for case in report["cases"])
    assert report["counts"]["analysis_invocations"] == 5
    assert report["counts"]["transcription_invocations"] == 1
    assert report["cases"][3]["stages"] == ["transcribing", "analyzing", "ready"]
    assert report["cases"][4]["stages"] == ["analyzing", "ready"]
    assert {"voice_search", "account_isolation", "deletion_revocation", "retry_tombstone"}.issubset(report["checks"])
    assert decoded[0]["assets"][-1]["transcript"] == CORRECTED_VOICE


def test_setup_errors_are_sanitized_and_written_without_credentials(tmp_path, capsys):
    config = tmp_path / ".env"
    config.write_text('ASTRA_API_KEY="secret-never-display')
    report = tmp_path / "report.json"
    assert main(["--env-file", str(config), "--report", str(report)]) == 1
    captured = capsys.readouterr()
    assert "secret-never-display" not in captured.out + captured.err + report.read_text()
    assert json.loads(report.read_text())["failure"]["check"] == "explicit_configuration"


def test_provider_failure_stops_the_run_and_never_reports_unrecognized_error_payload():
    class FailingProvider(FixtureProvider):
        def analyze(self, value):
            raise ProviderError("private-fixture-provider-response", False)
    report = run_validation(FailingProvider(), wav(), "audio/wav", live=False,
        decode_native=lambda *args: pytest.fail("No native decode after provider failure"))
    assert report["status"] == "failed"
    assert report["failure"] == {"check": "provider_pipeline", "provider_code": None}
    assert report["counts"]["analysis_invocations"] == 1 and report["counts"]["transcription_invocations"] == 0
    assert len(report["cases"]) == 1
    assert "private-fixture-provider-response" not in json.dumps(report)
