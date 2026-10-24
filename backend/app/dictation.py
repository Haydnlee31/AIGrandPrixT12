"""Bounded, authenticated-by-relay transcription without local audio persistence.

API contract verified against OpenAI's audio/transcriptions reference:
https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create
M4A/MP4 and gpt-4o-mini-transcribe support multipart input and JSON output.
The enclosing relay applies authorization/body limits before this module runs.
"""
from __future__ import annotations

import asyncio
import base64
import json
import time
from collections import deque
from typing import Callable

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator

TRANSCRIPTION_ENDPOINT = "https://api.openai.com/v1/audio/transcriptions"
TRANSCRIPTION_MODEL = "gpt-4o-mini-transcribe"
MAX_AUDIO_BYTES = 4 * 1024 * 1024
MAX_AUDIO_DATA_URL_LENGTH = 4 * ((MAX_AUDIO_BYTES + 2) // 3) + 40
MAX_DICTATION_BODY_BYTES = MAX_AUDIO_DATA_URL_LENGTH + 4096
MAX_TRANSCRIPTION_BYTES = 64 * 1024
MAX_TRANSCRIPT_CHARACTERS = 8000
MAX_DICTATION_INFLIGHT = 2
DICTATION_REQUESTS_PER_MINUTE = 8
SUPPORTED_HEADERS = {
    "data:audio/mp4;base64",
    "data:audio/m4a;base64",
    "data:audio/x-m4a;base64",
}


def _boxes(data: bytes):
    """Read bounded ISO BMFF box boundaries, without decoding AAC or loading files."""
    offset = 0
    count = 0
    while offset < len(data):
        count += 1
        if count > 4096 or len(data) - offset < 8:
            raise ValueError("Invalid M4A container")
        size = int.from_bytes(data[offset:offset + 4], "big")
        kind = data[offset + 4:offset + 8]
        header = 8
        if size == 1:
            if len(data) - offset < 16:
                raise ValueError("Invalid M4A container")
            size = int.from_bytes(data[offset + 8:offset + 16], "big")
            header = 16
        elif size == 0:
            size = len(data) - offset
        if size < header or offset + size > len(data):
            raise ValueError("Invalid M4A container")
        yield kind, data[offset + header:offset + size]
        offset += size


def _validate_m4a(raw: bytes):
    """Require an audio AAC track and a short, structurally bounded M4A container.

    AVAudioRecorder stops at 60 seconds. One second of encoder/container rounding
    is permitted here; invalid or long recordings never reach the paid endpoint.
    This checks format metadata, not whether speech is audible in the AAC bytes.
    """
    top = list(_boxes(raw))
    kinds = [kind for kind, _ in top]
    if not all(kind in kinds for kind in (b"ftyp", b"moov", b"mdat")):
        raise ValueError("Use an M4A recording")
    ftyp = next(value for kind, value in top if kind == b"ftyp")
    if len(ftyp) < 8 or (len(ftyp) - 8) % 4:
        raise ValueError("Invalid M4A format metadata")
    brands = [ftyp[:4], *(ftyp[index:index + 4] for index in range(8, len(ftyp), 4))]
    if not set(brands).intersection({b"M4A ", b"M4B ", b"mp41", b"mp42", b"isom", b"iso2", b"iso5", b"iso6"}):
        raise ValueError("Use an M4A recording")
    if not any(value for kind, value in top if kind == b"mdat"):
        raise ValueError("Recording has no audio data")
    tracks = []
    for kind, moov in top:
        if kind == b"moov":
            tracks.extend(value for subkind, value in _boxes(moov) if subkind == b"trak")
    if not 1 <= len(tracks) <= 4:
        raise ValueError("Invalid audio tracks")
    audio_tracks = 0
    for track in tracks:
        for kind, mdia in _boxes(track):
            if kind != b"mdia":
                continue
            media = dict(_boxes(mdia))
            handler = media.get(b"hdlr", b"")
            if len(handler) < 12 or handler[8:12] != b"soun":
                raise ValueError("Only audio recordings are supported")
            header = media.get(b"mdhd", b"")
            if len(header) >= 20 and header[0] == 0:
                timescale = int.from_bytes(header[12:16], "big")
                duration = int.from_bytes(header[16:20], "big")
            elif len(header) >= 32 and header[0] == 1:
                timescale = int.from_bytes(header[20:24], "big")
                duration = int.from_bytes(header[24:32], "big")
            else:
                raise ValueError("Invalid recording duration")
            if not timescale or not duration or duration / timescale > 61:
                raise ValueError("Record for at most 60 seconds")
            minf = dict(_boxes(media.get(b"minf", b"")))
            stbl = dict(_boxes(minf.get(b"stbl", b"")))
            stsd = stbl.get(b"stsd", b"")
            if len(stsd) < 16 or int.from_bytes(stsd[4:8], "big") != 1:
                raise ValueError("Use an AAC recording")
            entries = list(_boxes(stsd[8:]))
            if len(entries) != 1 or entries[0][0] != b"mp4a":
                raise ValueError("Use an AAC recording")
            audio_tracks += 1
    if not audio_tracks:
        raise ValueError("Recording has no audio track")


class DictationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    audio_data_url: str = Field(min_length=1, max_length=MAX_AUDIO_DATA_URL_LENGTH)

    @field_validator("audio_data_url")
    @classmethod
    def validate_audio(cls, value):
        header, separator, encoded = value.partition(",")
        if not separator or header not in SUPPORTED_HEADERS:
            raise ValueError("Use a base64 M4A audio recording")
        try:
            raw = base64.b64decode(encoded, validate=True)
        except ValueError:
            raise ValueError("Audio base64 is invalid") from None
        if not raw or len(raw) > MAX_AUDIO_BYTES:
            raise ValueError("Recording must be at most 4 MiB")
        _validate_m4a(raw)
        return value

    def audio_bytes(self) -> bytes:
        # Only the currently active request holds these bytes; no cache/file exists.
        return base64.b64decode(self.audio_data_url.split(",", 1)[1], validate=True)


class DictationResult(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    text: str = Field(min_length=1, max_length=MAX_TRANSCRIPT_CHARACTERS)


class DictationError(Exception):
    def __init__(self, status: int, code: str, message: str, retryable: bool = False):
        self.status, self.code, self.message, self.retryable = status, code, message, retryable
        super().__init__(code)


def dictation_error_response(error: DictationError):
    return JSONResponse({"error": {"code": error.code, "message": error.message, "retryable": error.retryable}},
                        status_code=error.status,
                        headers={"Cache-Control": "no-store", **({"Retry-After": "60"} if error.status == 429 else {})})


class DictationService:
    def __init__(self, *, api_key: str, transport=None, clock: Callable = time.monotonic,
                 rate_limit: int = DICTATION_REQUESTS_PER_MINUTE, timeout: float = 30):
        self.api_key, self.transport, self.clock = api_key, transport, clock
        self.rate_limit, self.timeout = rate_limit, timeout
        self.starts: deque[float] = deque()
        self.active = 0
        self.lock = asyncio.Lock()

    async def transcribe(self, capture: DictationRequest) -> DictationResult:
        if not self.api_key:
            raise DictationError(503, "not_configured", "Voice transcription is not connected yet. You can type your note instead.")
        async with self.lock:
            now = self.clock()
            while self.starts and self.starts[0] <= now - 60:
                self.starts.popleft()
            if len(self.starts) >= self.rate_limit or self.active >= MAX_DICTATION_INFLIGHT:
                raise DictationError(429, "dictation_rate_limited", "Voice transcription is busy. Try again shortly or type your note.", True)
            self.starts.append(now)
            self.active += 1
        try:
            return await asyncio.wait_for(self._request(capture.audio_bytes()), timeout=self.timeout)
        except (asyncio.TimeoutError, httpx.TimeoutException):
            raise DictationError(504, "dictation_timeout", "Transcription took too long. Try again or type your note.", True) from None
        except httpx.HTTPError:
            raise DictationError(503, "dictation_unavailable", "Voice transcription is temporarily unavailable. Try again or type your note.", True) from None
        finally:
            async with self.lock:
                self.active -= 1

    async def _request(self, raw: bytes) -> DictationResult:
        async with httpx.AsyncClient(transport=self.transport, trust_env=False, follow_redirects=False,
                                     timeout=httpx.Timeout(self.timeout, connect=min(5, self.timeout))) as client:
            async with client.stream("POST", TRANSCRIPTION_ENDPOINT,
                headers={"Authorization": f"Bearer {self.api_key}"},
                data={"model": TRANSCRIPTION_MODEL, "response_format": "json", "temperature": "0"},
                files={"file": ("voice-note.m4a", raw, "audio/mp4")}) as response:
                if response.status_code in {401, 403}:
                    raise DictationError(503, "provider_authentication_failed", "The voice connection needs its server configuration checked.")
                if response.status_code == 429:
                    raise DictationError(429, "dictation_rate_limited", "Voice transcription has reached its usage limit. Try again later.", True)
                if response.status_code >= 500 or response.status_code in {408, 425}:
                    raise DictationError(503, "dictation_unavailable", "Voice transcription is temporarily unavailable.", True)
                if response.status_code in {400, 413, 415, 422}:
                    raise DictationError(422, "audio_unreadable", "The recording could not be read. Try recording a new note.")
                if response.status_code != 200:
                    raise DictationError(502, "dictation_failed", "The recording could not be transcribed. Try again or type your note.")
                payload = bytearray()
                async for chunk in response.aiter_bytes():
                    if len(payload) + len(chunk) > MAX_TRANSCRIPTION_BYTES:
                        raise DictationError(502, "invalid_transcript", "The transcription response could not be verified.")
                    payload.extend(chunk)
                try:
                    result = json.loads(payload)
                except (ValueError, UnicodeDecodeError, RecursionError):
                    raise DictationError(502, "invalid_transcript", "The transcription response could not be verified.") from None
                text = result.get("text") if isinstance(result, dict) else None
                if not isinstance(text, str) or len(text) > MAX_TRANSCRIPT_CHARACTERS:
                    raise DictationError(502, "invalid_transcript", "The transcription response could not be verified.")
                if any(ord(char) < 32 and char not in "\t\n\r" or ord(char) == 127 for char in text):
                    raise DictationError(502, "invalid_transcript", "The transcription response could not be verified.")
                text = text.strip()
                if not text:
                    raise DictationError(422, "no_speech", "No speech was detected. Try speaking a little closer to the microphone.")
                return DictationResult(text=text)


def register_dictation(app: FastAPI, *, api_key: str, transport=None, clock: Callable = time.monotonic,
                       rate_limit: int = DICTATION_REQUESTS_PER_MINUTE, timeout: float = 30):
    service = DictationService(api_key=api_key, transport=transport, clock=clock, rate_limit=rate_limit, timeout=timeout)
    app.state.dictation_service = service

    @app.exception_handler(DictationError)
    async def dictation_error(_request: Request, error: DictationError):
        return dictation_error_response(error)

    @app.post("/v1/dictation", response_model=DictationResult)
    async def dictation(capture: DictationRequest):
        result = await service.transcribe(capture)
        return JSONResponse(result.model_dump(), headers={"Cache-Control": "no-store"})
