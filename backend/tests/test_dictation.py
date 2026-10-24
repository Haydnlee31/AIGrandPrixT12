"""Dictation route and multipart transport checks. No live provider calls."""
import asyncio
import base64
import json

import httpx
from fastapi.testclient import TestClient
import pytest

from backend.app.capture_preview import create_app
from backend.app.dictation import (
    DictationError, DictationRequest, DictationService, MAX_AUDIO_BYTES,
    MAX_DICTATION_BODY_BYTES, MAX_TRANSCRIPTION_BYTES, TRANSCRIPTION_ENDPOINT,
)

TOKEN = "dictation-test-access-token"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


def box(kind, payload):
    return (len(payload) + 8).to_bytes(4, "big") + kind + payload


def audio_container(*, duration=2, handler=b"soun", codec=b"mp4a", version=0):
    """Structurally valid test metadata with MOCK bytes, not decodable speech."""
    ftyp = box(b"ftyp", b"M4A " + bytes(4) + b"isommp42")
    if version == 0:
        mdhd = bytes(12) + (16000).to_bytes(4, "big") + int(duration * 16000).to_bytes(4, "big") + bytes(4)
    else:
        mdhd = bytes([1]) + bytes(19) + (16000).to_bytes(4, "big") + int(duration * 16000).to_bytes(8, "big") + bytes(4)
    hdlr = bytes(8) + handler + bytes(12)
    stsd = box(b"stsd", bytes(4) + (1).to_bytes(4, "big") + box(codec, bytes(28)))
    minf = box(b"minf", box(b"stbl", stsd))
    mdia = box(b"mdia", box(b"mdhd", mdhd) + box(b"hdlr", hdlr) + minf)
    return ftyp + box(b"moov", box(b"trak", mdia)) + box(b"mdat", b"MOCK-AAC-PAYLOAD")


def payload(raw=None, mime="audio/mp4"):
    return {"audio_data_url": f"data:{mime};base64," + base64.b64encode(audio_container() if raw is None else raw).decode()}


def app(handler=None, **kwargs):
    return create_app(api_key="test-openai-key-do-not-echo", token=TOKEN,
        transport=httpx.MockTransport(handler or (lambda _: httpx.Response(200, json={"text": "I like the smaller watch."}))), **kwargs)


def post(client, value=None):
    return client.post("/v1/dictation", headers=AUTH, json=payload() if value is None else value)


def test_auth_happens_before_body_parsing_or_upstream():
    calls = []
    with TestClient(app(lambda request: calls.append(request))) as client:
        response = client.post("/v1/dictation", content=b"not-valid-json")
        assert response.status_code == 401
        assert not calls
        response = client.post("/v1/dictation", headers={"Authorization": "Bearer wrong"}, json=payload())
        assert response.status_code == 401
        assert "test-openai-key" not in response.text
        assert TOKEN not in response.text


@pytest.mark.parametrize("mime", ["audio/mp4", "audio/m4a", "audio/x-m4a"])
def test_audio_bytes_use_multipart_file_and_json_transcription(mime):
    calls = []
    raw = audio_container()

    def handle(request):
        calls.append(request)
        assert str(request.url) == TRANSCRIPTION_ENDPOINT
        assert request.headers["Authorization"] == "Bearer test-openai-key-do-not-echo"
        assert request.headers["Content-Type"].startswith("multipart/form-data; boundary=")
        assert b'name="model"\r\n\r\ngpt-4o-mini-transcribe' in request.content
        assert b'name="response_format"\r\n\r\njson' in request.content
        assert b'filename="voice-note.m4a"' in request.content
        assert b"Content-Type: audio/mp4" in request.content
        assert raw in request.content
        assert b"base64" not in request.content
        # No product prompt is supplied that could contaminate spoken words.
        assert b'name="prompt"' not in request.content
        return httpx.Response(200, json={"text": "  I like the smaller watch.  ", "usage": {"seconds": 2}})

    with TestClient(app(handle)) as client:
        response = post(client, payload(raw, mime=mime))
        assert response.status_code == 200
        assert response.json() == {"text": "I like the smaller watch."}
        assert response.headers["Cache-Control"] == "no-store"
        assert len(calls) == 1


@pytest.mark.parametrize("value", [
    {}, {"audio_data_url": None}, {"audio_data_url": "https://example.com/recording.m4a"},
    {"audio_data_url": "data:audio/mp4;base64,"}, {"audio_data_url": "data:audio/mp4;base64,***"},
    payload(b"RIFF....WAVE"), payload(mime="audio/wav"), payload(mime="video/mp4"),
    payload(audio_container(handler=b"vide")), payload(audio_container(codec=b"alac")),
    payload(audio_container(duration=0)), payload(audio_container(duration=62)),
    {**payload(), "text": "private-user-note"},
    payload(audio_container()[:-3]),
])
def test_invalid_audio_never_reaches_upstream_or_echoes_input(value):
    calls = []
    with TestClient(app(lambda request: calls.append(request))) as client:
        response = post(client, value)
        assert response.status_code == 422
        assert response.json()["error"]["code"] == "invalid_audio"
        assert "private-user-note" not in response.text
        assert "audio_data_url" not in response.text
        assert not calls


def test_duration_v1_and_encoder_rounding_are_supported():
    with TestClient(app()) as client:
        assert post(client, payload(audio_container(duration=60.05, version=1))).status_code == 200


def test_body_bound_auth_precedence_and_decoded_byte_bound():
    with TestClient(app()) as client:
        content = b"x" * (MAX_DICTATION_BODY_BYTES + 1)
        assert client.post("/v1/dictation", content=content).status_code == 401
        response = client.post("/v1/dictation", content=content, headers=AUTH)
        assert response.status_code == 413
        assert response.json()["error"]["code"] == "request_too_large"
        assert post(client, payload(b"x" * (MAX_AUDIO_BYTES + 1))).status_code == 422


@pytest.mark.parametrize("text", ["", "  \n\t\r "])
def test_silence_response_is_not_replaced_with_a_fake_transcript(text):
    with TestClient(app(lambda _: httpx.Response(200, json={"text": text}))) as client:
        response = post(client)
        assert response.status_code == 422
        assert response.json()["error"]["code"] == "no_speech"
        assert "text" not in response.json()


@pytest.mark.parametrize("status,expected,code", [
    (401, 503, "provider_authentication_failed"), (403, 503, "provider_authentication_failed"),
    (429, 429, "dictation_rate_limited"), (500, 503, "dictation_unavailable"),
    (400, 422, "audio_unreadable"), (413, 422, "audio_unreadable"),
    (302, 502, "dictation_failed"),
])
def test_upstream_errors_do_not_echo_body_credentials_or_follow_redirects(status, expected, code):
    calls = []

    def handle(request):
        calls.append(request)
        return httpx.Response(status, text="test-openai-key-do-not-echo private-audio-transcript", headers={"location": "https://elsewhere.example"})

    with TestClient(app(handle)) as client:
        response = post(client)
        assert response.status_code == expected
        assert response.json()["error"]["code"] == code
        assert "test-openai-key" not in response.text
        assert "private-audio-transcript" not in response.text
        assert len(calls) == 1


@pytest.mark.parametrize("response", [
    {}, {"text": None}, {"text": 123}, ["private-transcript"], {"text": "secret\x00data"}, {"text": "x" * 8001},
])
def test_malformed_transcripts_fail_without_echo(response):
    with TestClient(app(lambda _: httpx.Response(200, json=response))) as client:
        result = post(client)
        assert result.status_code == 502
        assert result.json()["error"]["code"] == "invalid_transcript"
        assert "private-transcript" not in result.text


def test_no_audio_or_transcript_cache_and_rate_budget():
    calls = []
    clock = [100.0]

    def handle(request):
        calls.append(1)
        return httpx.Response(200, json={"text": "An editable note."})

    with TestClient(app(handle, rate_limit=2, clock=lambda: clock[0])) as client:
        assert post(client).status_code == 200
        assert post(client).status_code == 200
        assert len(calls) == 2  # identical recordings aren't retained in a cache
        assert client.app.state.dictation_service.active == 0
        assert not hasattr(client.app.state.dictation_service, "cache")
        response = post(client)
        assert response.status_code == 429
        assert response.headers["Retry-After"] == "60"
        clock[0] += 61
        assert post(client).status_code == 200


def test_concurrent_requests_are_bounded_and_cancellation_releases_slot():
    async def run():
        started = asyncio.Event()
        hold = asyncio.Event()
        requests = []

        async def handle(request):
            requests.append(1)
            if len(requests) == 2:
                started.set()
            await hold.wait()
            return httpx.Response(200, json={"text": "My real spoken note."})

        service = DictationService(api_key="test", transport=httpx.MockTransport(handle))
        capture = DictationRequest(**payload())
        tasks = [asyncio.create_task(service.transcribe(capture)) for _ in range(2)]
        await asyncio.wait_for(started.wait(), timeout=2)
        with pytest.raises(DictationError) as error:
            await service.transcribe(capture)
        assert error.value.code == "dictation_rate_limited"
        tasks[0].cancel()
        with pytest.raises(asyncio.CancelledError):
            await tasks[0]
        assert service.active == 1
        hold.set()
        assert (await tasks[1]).text == "My real spoken note."
        assert service.active == 0
    asyncio.run(run())


def test_timeout_response_bound_missing_key_and_connection_failure():
    async def slow(_):
        await asyncio.sleep(0.1)
        return httpx.Response(200, json={"text": "late"})

    with TestClient(app(slow, timeout=0.01)) as client:
        response = post(client)
        assert response.status_code == 504
        assert response.json()["error"]["code"] == "dictation_timeout"
        assert client.app.state.dictation_service.active == 0
    with TestClient(app(lambda _: httpx.Response(200, content=b"x" * (MAX_TRANSCRIPTION_BYTES + 1)))) as client:
        assert post(client).json()["error"]["code"] == "invalid_transcript"
    with TestClient(create_app(api_key="", token=TOKEN)) as client:
        assert post(client).json()["error"]["code"] == "not_configured"

    def connection_failure(request):
        raise httpx.ConnectError("private-network-detail", request=request)

    with TestClient(app(connection_failure)) as client:
        response = post(client)
        assert response.status_code == 503
        assert response.json()["error"]["code"] == "dictation_unavailable"
        assert "private-network-detail" not in response.text
