"""Routine tests never inherit a developer's paid inference configuration."""
import pytest


@pytest.fixture(autouse=True)
def isolate_inference_environment(monkeypatch):
    for key in ("ASTRA_API_KEY", "OPENAI_API_KEY", "ASTRA_MODEL", "ASTRA_SERVICE_TIER", "ANNOTATION_PROVIDER",
                "MULTIMODAL_ENABLED", "MULTIMODAL_TRANSCRIPTION_MODEL"):
        monkeypatch.delenv(key, raising=False)
