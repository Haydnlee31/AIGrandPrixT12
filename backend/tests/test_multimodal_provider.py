"""Mocked multimodal provider boundaries and native compatibility checks."""
import asyncio
import base64
from copy import deepcopy
from io import BytesIO
import json
import wave

import httpx
from PIL import Image
import pytest

from backend.app.multimodal_provider import (
    MAX_AUDIO_BYTES, MAX_RESPONSE_BYTES, MMInput, MultimodalProvider, NativePreview,
    RESPONSES_ENDPOINT, TRANSCRIPTION_ENDPOINT, _output_schema, validate_audio,
)
from backend.app.predictive import ProviderError


def photo():
    stream = BytesIO()
    Image.new("RGB", (16, 16), "#aabbaa").save(stream, "PNG")
    return "data:image/png;base64," + base64.b64encode(stream.getvalue()).decode()


def wav(*, duration=1, channels=1, rate=16000):
    stream = BytesIO()
    with wave.open(stream, "wb") as audio:
        audio.setnchannels(channels)
        audio.setsampwidth(2)
        audio.setframerate(rate)
        audio.writeframes(bytes(int(rate * duration) * channels * 2))
    return stream.getvalue()


def m4a(duration=2):
    def box(kind, payload):
        return (len(payload) + 8).to_bytes(4, "big") + kind + payload
    mdhd = bytes(12) + (16000).to_bytes(4, "big") + int(duration * 16000).to_bytes(4, "big") + bytes(4)
    hdlr = bytes(8) + b"soun" + bytes(12)
    stsd = box(b"stsd", bytes(4) + (1).to_bytes(4, "big") + box(b"mp4a", bytes(28)))
    mdia = box(b"mdia", box(b"mdhd", mdhd) + box(b"hdlr", hdlr) + box(b"minf", box(b"stbl", stsd)))
    return box(b"ftyp", b"M4A " + bytes(4) + b"isommp42") + box(b"moov", box(b"trak", mdia)) + box(b"mdat", b"MOCK-AAC")


def result():
    return {
        "analysis": {
            "schema_version": 1,
            "summary": "A rectangular digital wristwatch.",
            "products": [{
                "product_type": "Digital wristwatch", "category_path": ["Accessories", "Watches", "Digital watches"],
                "brand": None, "model": None,
                "attributes": [{"name": "display", "value": "Digital", "basis": "captured_text",
                                "evidence": "digital watch", "certainty": "observed"}],
                "use_cases": ["Everyday wear"], "search_terms": ["digital wristwatch"],
            }],
            "intent_context": [], "uncertainties": ["Brand is unknown."],
        },
        "preview": {
            "product_name": "Digital wristwatch", "category_path": ["Accessories", "Watches", "Digital watches"],
            "brand": None, "style": ["Rectangular"], "summary": "A rectangular digital wristwatch.",
            "uncertainties": ["Brand is unknown."],
            "prompts": [
                {"id": "p1", "text": "I like the rectangular watch face.", "question": "Does the rectangular face appeal to you?"},
                {"id": "p2", "text": "I want a watch for everyday wear.", "question": "Would you wear it every day?"},
                {"id": "p3", "text": "I am considering this as a gift.", "question": "Could this be a gift?"},
            ],
            "evidence": ["Rectangular digital watch"],
        },
        "source_assets": [],
    }


def envelope(value=None):
    return {"status": "completed", "output": [{"type": "message", "role": "assistant", "status": "completed",
             "content": [{"type": "output_text", "text": json.dumps(value if value is not None else result())}]}]}


def provider(handler=None, **kwargs):
    return MultimodalProvider(api_key="test-multimodal-key-never-display", transport=httpx.MockTransport(
        handler or (lambda _: httpx.Response(200, json=envelope()))), **kwargs)


def capture(**kwargs):
    return MMInput(**{"title": "Rectangular digital watch", "text": "", "note": "", **kwargs})


def test_two_images_and_voice_are_combined_with_exact_asset_identity():
    requests = []
    answer = result()
    answer["analysis"]["products"][0]["attributes"] = [
        {"name": "shape", "value": "Rectangular", "basis": "image", "evidence": "[front] Rectangular watch face", "certainty": "observed"},
        {"name": "color", "value": "Black", "basis": "image", "evidence": "[back] Black strap", "certainty": "observed"},
    ]
    answer["analysis"]["intent_context"] = ["I want a leather strap for Dad"]
    answer["preview"]["evidence"] = ["[front] Rectangular watch face", "[back] Black strap", "I want a leather strap for Dad"]
    answer["source_assets"] = ["front", "back", "voice"]

    def handle(request):
        requests.append(request)
        assert str(request.url) == RESPONSES_ENDPOINT
        body = json.loads(request.content)
        assert body["model"] == "gpt-6-astra"
        assert body["store"] is False
        assert "tools" not in body
        assert body["reasoning"] == {"effort": "low"}
        assert body["text"]["format"]["strict"] is True
        assert "UNTRUSTED DATA" in body["instructions"]
        assert "no purchase, reminder or tracking has been executed" in body["instructions"]
        content = body["input"][0]["content"]
        assert [part["type"] for part in content] == ["input_text", "input_text", "input_image", "input_text", "input_image"]
        context = json.loads(content[0]["text"])
        assert context["voice_transcripts"] == [{"asset_id": "voice", "text": "I want a leather strap for Dad"}]
        assert context["note"] == "It is a gift."
        assert context["url"] == "https://example.org/watch"
        assert content[1]["text"] == "Image asset [front]"
        assert content[3]["text"] == "Image asset [back]"
        return httpx.Response(200, json=envelope(answer))

    got = provider(handle).analyze(capture(note="It is a gift.", url="https://example.org/watch",
        images=(("front", photo()), ("back", photo())), transcripts=(("voice", "I want a leather strap for Dad"),)))
    assert len(requests) == 1
    assert got["analysis"]["intent_context"] == ["I want a leather strap for Dad"]
    assert got["preview"]["schema_version"] == 2
    assert isinstance(got["preview"]["analyzed_at"], int)
    assert got["preview"]["prompts"] == answer["preview"]["prompts"]


def test_native_projection_decodes_with_existing_v2_contract():
    from backend.app.capture_preview import PreviewOutput, PreviewResult
    got = provider().analyze(capture())
    parsed = PreviewResult.model_validate(got["preview"])
    assert parsed.schema_version == 2
    assert parsed.product_name == "Digital wristwatch"
    assert NativePreview.model_validate(result()["preview"]).model_dump() == PreviewOutput.model_validate(result()["preview"]).model_dump()
    assert set(NativePreview.model_fields) == set(PreviewOutput.model_fields)


def test_strict_schema_requires_all_fields_and_forbids_additional_properties():
    def check(value):
        if isinstance(value, list):
            for item in value:
                check(item)
        elif isinstance(value, dict):
            assert "$ref" not in value
            if value.get("type") == "object":
                assert value["additionalProperties"] is False
                assert set(value["required"]) == set(value["properties"])
            for child in value.values():
                check(child)
    check(_output_schema())


@pytest.mark.parametrize("mutation", [
    lambda r: r["analysis"]["products"][0]["attributes"][0].update(evidence="Nonexistent text"),
    lambda r: r["analysis"]["products"][0]["attributes"][0].update(basis="image", evidence="[missing] Digital display"),
    lambda r: r["analysis"]["products"][0]["attributes"][0].update(basis="image", evidence="Digital display"),
    lambda r: r["analysis"].update(intent_context=["I want a leather strap"]),
    lambda r: r["preview"].update(evidence=["The price is $50"]),
    lambda r: r["preview"].update(category_path=["Other"]),
    lambda r: r["preview"].update(brand="Invented"),
    lambda r: r["preview"].update(prompts=[r["preview"]["prompts"][0]]),
    lambda r: r.update(source_assets=["unknown"]),
    lambda r: r.update(source_assets=["front", "front"]),
    lambda r: r.update(extra_field="unexpected"),
    lambda r: r["analysis"].update(summary="Invalid\u0000content"),
])
def test_unsupported_facts_or_incompatible_preview_are_not_published(mutation):
    answer = result()
    mutation(answer)
    calls = []
    def handle(request):
        calls.append(request)
        return httpx.Response(200, json=envelope(answer))
    with pytest.raises(ProviderError) as error:
        provider(handle).analyze(capture(images=(("front", photo()),)))
    assert error.value.code == "multimodal_invalid_output"
    assert error.value.retryable is False
    assert len(calls) == 2


def test_voice_preferences_do_not_establish_product_material():
    answer = result()
    answer["analysis"]["products"][0]["attributes"] = [{"name": "material", "value": "Leather",
        "basis": "user_note", "evidence": "I want a leather strap", "certainty": "observed"}]
    with pytest.raises(ProviderError, match="multimodal_invalid_output"):
        provider(lambda _: httpx.Response(200, json=envelope(answer))).analyze(
            capture(transcripts=(("voice", "I want a leather strap"),)))


def test_image_evidence_must_be_in_returned_source_assets():
    answer = result()
    answer["analysis"]["products"][0]["attributes"][0].update(basis="image", evidence="[front] Digital display")
    with pytest.raises(ProviderError, match="multimodal_invalid_output"):
        provider(lambda _: httpx.Response(200, json=envelope(answer))).analyze(capture(images=(("front", photo()),)))


def test_voice_evidence_must_be_in_returned_source_assets():
    answer = result()
    answer["analysis"]["intent_context"] = ["I want a leather strap"]
    with pytest.raises(ProviderError, match="multimodal_invalid_output"):
        provider(lambda _: httpx.Response(200, json=envelope(answer))).analyze(
            capture(transcripts=(("voice", "I want a leather strap"),)))


def test_quotes_cannot_be_created_by_joining_different_sources():
    answer = result()
    answer["analysis"]["intent_context"] = ["a gift I want a leather strap"]
    answer["source_assets"] = ["voice"]
    with pytest.raises(ProviderError, match="multimodal_invalid_output"):
        provider(lambda _: httpx.Response(200, json=envelope(answer))).analyze(
            capture(note="This is a gift", transcripts=(("voice", "I want a leather strap"),)))


def test_corrective_generation_can_recover_within_same_total_deadline():
    first = result()
    first["preview"]["evidence"] = ["Invented source text"]
    calls = []
    def handle(request):
        calls.append(json.loads(request.content))
        return httpx.Response(200, json=envelope(first if len(calls) == 1 else result()))
    got = provider(handle).analyze(capture())
    assert got["preview"]["product_name"] == "Digital wristwatch"
    assert len(calls) == 2
    assert "Regenerate conservatively" in calls[1]["instructions"]
    assert "Invented source text" not in json.dumps(calls[1])


def test_empty_nonproduct_result_remains_empty():
    answer = result()
    answer["analysis"].update(products=[], summary="A product photo or caption is needed.")
    answer["preview"].update(product_name=None, brand=None, category_path=[], style=[], prompts=[], evidence=[])
    got = provider(lambda _: httpx.Response(200, json=envelope(answer))).analyze(
        capture(title="", url="https://example.org/unknown"))
    assert got["analysis"]["products"] == []
    assert got["preview"]["prompts"] == []


@pytest.mark.parametrize("input", [
    capture(images=(("remote", "https://example.org/private.png"),)),
    capture(images=tuple((str(i), photo()) for i in range(5))),
    capture(images=(("same", photo()),), transcripts=(("same", "hello"),)),
    capture(transcripts=(("voice", ""),)),
    capture(transcripts=(("voice", "a" * 8001),)),
    capture(images=(("../unsafe", photo()),)),
    capture(url="file:///private/data"),
    capture(url="https://user:password@example.org"),
    capture(url="https://example.org/\ud800"),
    capture(note="a" * 2001),
    capture(note="bad\ud800text"),
    capture(transcripts=(("voice", "bad\ud800text"),)),
    capture(title="", text="", note=""),
])
def test_invalid_input_never_reaches_provider(input):
    calls = []
    with pytest.raises(ProviderError):
        provider(lambda r: calls.append(r)).analyze(input)
    assert calls == []


@pytest.mark.parametrize("status,code,retryable", [(401, "multimodal_authentication_failed", False),
    (403, "multimodal_authentication_failed", False), (429, "multimodal_rate_limited", True),
    (503, "multimodal_unavailable", True), (400, "multimodal_request_rejected", False),
    (302, "multimodal_request_rejected", False)])
def test_provider_errors_are_bounded_and_do_not_expose_remote_body(status, code, retryable):
    calls = []
    def handle(request):
        calls.append(request)
        return httpx.Response(status, text="private product data and credentials", headers={"location": "https://other.example"})
    with pytest.raises(ProviderError) as error:
        provider(handle).analyze(capture())
    assert str(error.value) == code
    assert error.value.retryable is retryable
    assert len(calls) == 1


def test_timeout_bounds_whole_request():
    async def handle(request):
        await asyncio.sleep(1)
        return httpx.Response(200, json=envelope())
    with pytest.raises(ProviderError, match="multimodal_timeout") as error:
        provider(handle, timeout_seconds=0.01).analyze(capture())
    assert error.value.retryable


def test_response_size_is_bounded():
    with pytest.raises(ProviderError, match="multimodal_response_too_large"):
        provider(lambda _: httpx.Response(200, content=b"x" * (MAX_RESPONSE_BYTES + 1))).analyze(capture())


@pytest.mark.parametrize("payload,code", [
    ({"status": "incomplete", "output": []}, "multimodal_incomplete_response"),
    ({"status": "completed", "output": [{"type": "message", "status": "completed", "role": "assistant", "content": [{"type": "refusal"}]}]}, "multimodal_refused"),
    ({"status": "completed", "output": []}, "multimodal_invalid_response"),
])
def test_incomplete_and_refused_results_never_look_successful(payload, code):
    with pytest.raises(ProviderError, match=code):
        provider(lambda _: httpx.Response(200, json=payload)).analyze(capture())


@pytest.mark.parametrize("mime,raw,canonical", [("audio/wav", wav(), "audio/wav"),
    ("audio/x-wav", wav(), "audio/wav"), ("audio/mp4", m4a(), "audio/mp4"),
    ("audio/x-m4a", m4a(), "audio/mp4")])
def test_validated_recordings_use_separate_transcription_request(mime, raw, canonical):
    def handle(request):
        assert str(request.url) == TRANSCRIPTION_ENDPOINT
        assert request.headers["authorization"] == "Bearer test-multimodal-key-never-display"
        assert request.headers["content-type"].startswith("multipart/form-data;")
        assert b'name="model"\r\n\r\ngpt-transcribe' in request.content
        assert b'name="response_format"\r\n\r\njson' in request.content
        assert raw in request.content
        assert b'name="prompt"' not in request.content
        assert canonical.encode() in request.content
        return httpx.Response(200, json={"text": "  I want\na leather strap.  ", "languages": [{"code": "en"}]})
    assert validate_audio(raw, mime) == canonical
    assert provider(handle).transcribe(raw, mime) == "I want a leather strap."


@pytest.mark.parametrize("mime,raw", [("audio/webm", b"webm"), ("audio/mp3", b"ID3"),
    ("audio/mp4", wav()), ("audio/wav", m4a()), ("audio/wav", wav(duration=61)),
    ("audio/mp4", m4a(duration=62)), ("audio/wav", wav()[:-10]),
    ("audio/wav", b"a" * (MAX_AUDIO_BYTES + 1)), ("audio/wav", b""),
    ("audio/wav", wav(rate=7999)), ("audio/wav", wav(channels=3)), (None, wav())])
def test_invalid_or_unsupported_recording_rejected_before_paid_call(mime, raw):
    with pytest.raises(ValueError):
        validate_audio(raw, mime)
    calls = []
    with pytest.raises(ProviderError, match="multimodal_invalid_audio"):
        provider(lambda r: calls.append(r)).transcribe(raw, mime)
    assert calls == []


@pytest.mark.parametrize("text", ["", "  ", None, "a" * 8001, "bad\x00text", "bad\ud800text"])
def test_invalid_transcript_is_not_an_empty_success(text):
    with pytest.raises(ProviderError, match="multimodal_invalid_transcript"):
        provider(lambda _: httpx.Response(200, content=json.dumps({"text": text}).encode())).transcribe(wav(), "audio/wav")


def test_model_configuration_and_close(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "test-configured-key")
    monkeypatch.setenv("ASTRA_MODEL", "gpt-6-astra")
    monkeypatch.setenv("MULTIMODAL_TRANSCRIPTION_MODEL", "gpt-transcribe")
    configured = MultimodalProvider()
    assert configured.model == "gpt-6-astra"
    assert configured.transcription_model == "gpt-transcribe"
    assert configured.version == "gpt-6-astra:multimodal-v1"
    configured.close()
    with pytest.raises(ProviderError, match="multimodal_provider_closed"):
        configured.analyze(capture())
    with pytest.raises(ProviderError, match="multimodal_key_missing"):
        MultimodalProvider(api_key="")
