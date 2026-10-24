"""Additive multimodal capture API and independently leased processing stages.

The v1 save/preview contracts and client-local libraries are not redirected here.
Publishing to the shared Library is an explicit, idempotent action. Model work
never runs in an API transaction. Each provider call has its own durable job.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import time
from typing import Literal
from urllib.parse import urlsplit

from fastapi import Depends, Header
from fastapi.responses import Response
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from sqlalchemy import delete, func, select, update

from .db import Evidence, Job, MultimodalAsset, MultimodalCapture, Mutation, SavedItem, UserEvent, UserState
from .media import validate_image_data_url
from .predictive import ACTION_TEXT, ProviderError
from .understanding import ProductAnalysis
from . import library

MAX_ASSET_BYTES = 4 * 1024 * 1024
MAX_CAPTURE_BYTES = 16 * 1024 * 1024
MAX_USER_BYTES = 128 * 1024 * 1024
MAX_USER_CAPTURES = 200
ANALYSES_PER_MINUTE = 8
ANALYSES_PER_DAY = 100
MAX_QUEUED_PER_USER = 2
JOB_KINDS = ("multimodal_transcribe", "multimodal_analyze")


class MMModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, allow_inf_nan=False)


class MultimodalCreate(MMModel):
    title: str = Field(default="", max_length=300)
    text: str = Field(default="", max_length=12000)
    note: str = Field(default="", max_length=2000)
    url: str | None = Field(default=None, max_length=2048)
    client: Literal["web", "chrome_extension", "ios_app", "ios_share_extension"] = "web"

    @field_validator("title", "text", "note", "url")
    @classmethod
    def clean(cls, value):
        if value is not None and any(ord(c) < 32 and c not in "\n\r\t" or ord(c) == 127 for c in value):
            raise ValueError("Text contains unsupported control characters")
        if value is not None:
            try:
                value.encode("utf-8")
            except UnicodeEncodeError:
                raise ValueError("Text must contain valid Unicode") from None
        return value

    @field_validator("url")
    @classmethod
    def valid_url(cls, value):
        if value is not None:
            try:
                parsed = urlsplit(value)
                if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
                    raise ValueError()
                if any(c.isspace() for c in value):
                    raise ValueError()
            except ValueError:
                raise ValueError("Use an HTTP(S) URL without credentials") from None
        return value


class MultimodalRevision(MMModel):
    revision: int = Field(ge=1)


class MultimodalEdit(MultimodalRevision):
    title: str | None = Field(default=None, max_length=300)
    text: str | None = Field(default=None, max_length=12000)
    note: str | None = Field(default=None, max_length=2000)

    @model_validator(mode="after")
    def valid_edit(self):
        fields = self.model_fields_set - {"revision"}
        if not fields or any(getattr(self, name) is None for name in fields):
            raise ValueError("Supply at least one non-null field to edit")
        MultimodalCreate(title=self.title or "", text=self.text or "", note=self.note or "")
        return self


class MultimodalUpload(MultimodalRevision):
    media_type: Literal["image/jpeg", "image/png", "image/webp", "audio/wav", "audio/mp4", "audio/m4a", "audio/x-m4a"]
    data_base64: str = Field(min_length=1, max_length=4 * ((MAX_ASSET_BYTES + 2) // 3))


class MultimodalTranscriptEdit(MultimodalRevision):
    transcript: str = Field(min_length=1, max_length=8000)

    @field_validator("transcript")
    @classmethod
    def clean_transcript(cls, value):
        MultimodalCreate.clean(value)
        if not value.strip():
            raise ValueError("Enter the corrected transcript")
        return " ".join(value.split())


class MultimodalResult(MMModel):
    analysis: ProductAnalysis
    preview: dict
    source_assets: list[str] = Field(max_length=5)


class MultimodalAssetView(MMModel):
    id: str
    media_type: str
    kind: Literal["image", "audio"]
    size_bytes: int
    status: Literal["pending", "ready", "failed"]
    transcript: str | None
    transcript_origin: Literal["provider", "user"] | None


class MultimodalView(MultimodalCreate):
    id: str
    revision: int
    status: Literal["pending", "ready", "enrichment_failed"]
    stage: Literal["draft", "transcribing", "analyzing", "ready", "failed"]
    assets: list[MultimodalAssetView]
    result: MultimodalResult | None
    error_code: str | None
    created_at: float
    updated_at: float
    published_save_id: str | None


class MultimodalCapabilities(MMModel):
    enabled: bool
    schema_version: Literal[1] = 1
    content_types: list[str] = ["text", "image", "audio"]
    max_assets: int = 5
    max_images: int = 4
    max_audio: int = 1
    max_asset_bytes: int = MAX_ASSET_BYTES
    actions_execute: Literal[False] = False


def assets_for(db, capture):
    return db.scalars(select(MultimodalAsset).where(
        MultimodalAsset.capture_id == capture.id, MultimodalAsset.user_id == capture.user_id
    ).order_by(MultimodalAsset.created_at, MultimodalAsset.id)).all()


def capture_view(db, capture):
    return {name: getattr(capture, name) for name in (
        "id", "revision", "status", "stage", "title", "text", "note", "url", "client",
        "result", "error_code", "created_at", "updated_at", "published_save_id"
    )} | {"assets": [{name: getattr(asset, name) for name in (
        "id", "media_type", "kind", "size_bytes", "status", "transcript", "transcript_origin"
    )} for asset in assets_for(db, capture)]}


def cancel_jobs(db, capture):
    for job in db.scalars(select(Job).where(Job.user_id == capture.user_id,
            Job.kind.in_(JOB_KINDS), Job.status.in_(["pending", "running"]))):
        if job.payload.get("capture_id") == capture.id:
            job.status, job.lease_token, job.lease_until = "done", None, 0
            job.error = None


def invalidate_capture(db, capture):
    cancel_jobs(db, capture)
    capture.revision += 1
    capture.status, capture.stage = "pending", "draft"
    capture.result, capture.error_code, capture.model_version = None, None, None
    capture.updated_at = time.time()


def erase_capture(db, capture):
    """Retain only the identity tombstone; revoke every delayed retry/result."""
    cancel_jobs(db, capture)
    capture.deleted, capture.revision = True, capture.revision + 1
    capture.title = capture.text = capture.note = ""
    capture.url = capture.result = capture.error_code = capture.model_version = None
    capture.updated_at = time.time()
    db.execute(delete(MultimodalAsset).where(MultimodalAsset.capture_id == capture.id,
                                            MultimodalAsset.user_id == capture.user_id))
    # Match the existing Library deletion contract: no cached private snapshots.
    db.execute(update(Mutation).where(Mutation.user_id == capture.user_id).values(response={"_expired": True}))


def erase_for_saved_item(db, user_id, item_id):
    for capture in db.scalars(select(MultimodalCapture).where(
            MultimodalCapture.user_id == user_id, MultimodalCapture.published_save_id == item_id,
            MultimodalCapture.deleted.is_(False))):
        erase_capture(db, capture)


def snapshot_for_capture(db, capture, extra_notes=()):
    from .multimodal_provider import MMInput
    assets = assets_for(db, capture)
    if any(asset.status != "ready" for asset in assets):
        raise ProviderError("multimodal_assets_not_ready", True)
    return MMInput(title=capture.title, text=capture.text,
        note="\n".join(dict.fromkeys([*extra_notes, capture.note]))[:2000], url=capture.url,
        images=tuple((a.id, "data:" + a.media_type + ";base64," + base64.b64encode(a.content).decode())
                     for a in assets if a.kind == "image"),
        transcripts=tuple((a.id, a.transcript) for a in assets if a.kind == "audio" and a.transcript))


def lock_job_owner(db, job_id):
    # Read ownership without locking the job, then match the API's lock order.
    # Otherwise API state->capture->job and worker job->capture can deadlock.
    owner = db.scalar(select(Job.user_id).where(Job.id == job_id))
    if owner is not None:
        db.scalar(select(UserState).where(UserState.user_id == owner).with_for_update())
    return owner


def reserve_analysis(db, user_id, APIError):
    """One owner-serialized allowance for drafts and published media saves."""
    now = time.time()
    requests = select(func.count()).select_from(UserEvent).where(UserEvent.user_id == user_id,
        UserEvent.event_type == "multimodal_analysis_requested")
    recent = db.scalar(requests.where(UserEvent.occurred_at >= now - 60))
    daily = db.scalar(requests.where(UserEvent.occurred_at >= now - 86400))
    jobs = db.scalars(select(Job).where(Job.user_id == user_id,
        Job.kind.in_([*JOB_KINDS, "enrich"]), Job.status.in_(["pending", "running"]))).all()
    media_saves = set(db.scalars(select(MultimodalCapture.published_save_id).where(
        MultimodalCapture.user_id == user_id, MultimodalCapture.deleted.is_(False),
        MultimodalCapture.published_save_id.is_not(None))))
    queued = sum(job.kind in JOB_KINDS or job.payload.get("item_id") in media_saves for job in jobs)
    if recent >= ANALYSES_PER_MINUTE or daily >= ANALYSES_PER_DAY or queued >= MAX_QUEUED_PER_USER:
        raise APIError(429, "multimodal_rate_limited", "Wait for current analysis to finish or for the analysis allowance to reset.")
    db.add(UserEvent(user_id=user_id, event_type="multimodal_analysis_requested", payload={}, occurred_at=now))


def annotation_from_result(result, model_version, *, image_present=False):
    """Publish the rich analysis through the existing Library/Explore contract.

    Native product-specific choices stay in preview. Shared intent choices keep
    their stable action identities and annotation-only semantics.
    """
    from .worker import validate_annotation
    parsed = MultimodalResult.model_validate(result)
    analysis = parsed.analysis.model_dump()
    preview = parsed.preview
    return validate_annotation({"features": {
        "subject": preview.get("product_name") or "Saved content",
        "content_kind": "product" if analysis["products"] else "unclear",
        "visual_attributes": preview.get("style", []),
        "image_analyzed": image_present,
        "data_mode": "astra", "analysis": analysis,
        "source_assets": parsed.source_assets,
        "provenance": "captured content and explicit voice/text notes",
        "suggestion_order": ["save_inspiration", "compare_options", "buy_intent"],
    }, "suggestions": [{"kind": "intent", "claim": claim, "text": ACTION_TEXT[claim]}
                       for claim in ("save_inspiration", "compare_options", "buy_intent")]}, model_version)


class MultimodalService:
    def __init__(self, factory, provider=None, enabled=None):
        self.factory = factory
        self.enabled = (provider is not None or os.getenv("MULTIMODAL_ENABLED", "false").lower() == "true") if enabled is None else enabled
        self.provider = provider
        if self.enabled and provider is None:
            from .multimodal_provider import MultimodalProvider
            self.provider = MultimodalProvider()

    def close(self):
        if self.provider and hasattr(self.provider, "close"):
            self.provider.close()

    def run_claimed(self, job_id, token):
        from .worker import finish_job, leased_job, transaction, LostLease
        try:
            with transaction(self.factory) as db:
                lock_job_owner(db, job_id)
                job = leased_job(db, job_id, token)
                if job is None:
                    return
                capture = self._current(db, job)
                if capture is None:
                    finish_job(job)
                    return
                owner, revision, kind = job.user_id, capture.revision, job.kind
                asset_id = job.payload.get("asset_id")
                assets = assets_for(db, capture)
                if kind == "multimodal_transcribe":
                    asset = next((a for a in assets if a.id == asset_id and a.kind == "audio"), None)
                    if asset is None or asset.status == "ready":
                        finish_job(job)
                        return
                    audio, mime = bytes(asset.content), asset.media_type
                else:
                    snapshot = snapshot_for_capture(db, capture)

            # Provider calls run without a database session or lock. Each stage
            # has its own <=40s request, below the existing 60s job lease.
            output = self.provider.transcribe(audio, mime) if kind == "multimodal_transcribe" else self.provider.analyze(snapshot)
            if kind == "multimodal_transcribe":
                if not isinstance(output, str) or not output.strip() or len(output) > 8000:
                    raise ProviderError("multimodal_invalid_transcript", False)
            else:
                output = MultimodalResult.model_validate(output).model_dump()
                if len(json.dumps(output).encode()) > 32768:
                    raise ProviderError("multimodal_output_too_large", False)

            with transaction(self.factory) as db:
                db.scalar(select(UserState).where(UserState.user_id == owner).with_for_update())
                job = leased_job(db, job_id, token)
                if job is None:
                    return
                capture = self._current(db, job)
                if capture is None or capture.revision != revision:
                    finish_job(job)
                    return
                if kind == "multimodal_transcribe":
                    asset = db.scalar(select(MultimodalAsset).where(MultimodalAsset.id == asset_id,
                        MultimodalAsset.user_id == owner, MultimodalAsset.capture_id == capture.id))
                    if asset is None:
                        finish_job(job)
                        return
                    asset.transcript, asset.status = output.strip(), "ready"
                    asset.transcript_origin = "provider"
                    self.queue_analysis(db, capture)
                else:
                    capture.result = output
                    capture.model_version = self.provider.version
                    capture.status, capture.stage = "ready", "ready"
                    capture.error_code = None
                capture.updated_at = time.time()
                finish_job(job)
        except LostLease:
            return
        except Exception as error:
            # Provider bodies/audio/transcripts never enter error logs or jobs.
            with transaction(self.factory) as db:
                lock_job_owner(db, job_id)
                job = leased_job(db, job_id, token)
                if job is None:
                    return
                capture = self._current(db, job)
                if capture is None:
                    finish_job(job)
                    return
                retryable = isinstance(error, ProviderError) and error.retryable
                code = error.code if isinstance(error, ProviderError) else "multimodal_invalid_output"
                job.error = code
                job.status = "pending" if retryable and job.attempts < 3 else "failed"
                job.due_at = time.time() + 2 ** job.attempts
                job.lease_token, job.lease_until = None, 0
                if job.status == "failed":
                    capture.status, capture.stage, capture.error_code = "enrichment_failed", "failed", code
                    capture.updated_at = time.time()
                    asset = db.get(MultimodalAsset, job.payload.get("asset_id")) if job.payload.get("asset_id") else None
                    if asset and asset.capture_id == capture.id and asset.user_id == capture.user_id:
                        asset.status = "failed"

    @staticmethod
    def _current(db, job):
        capture = db.scalar(select(MultimodalCapture).where(MultimodalCapture.id == job.payload.get("capture_id"),
            MultimodalCapture.user_id == job.user_id).with_for_update())
        if capture and not capture.deleted and capture.revision == job.payload.get("revision") and capture.status == "pending":
            return capture
        return None

    @staticmethod
    def queue_analysis(db, capture):
        from .worker import enqueue
        capture.stage = "analyzing"
        enqueue(db, capture.user_id, "multimodal_analyze", {"capture_id": capture.id, "revision": capture.revision})


def register_multimodal(app, service, *, user, database, mutate, state_for, APIError):
    """Reuse the main API's ownership, serialized mutations and retry protocol."""
    from .responses import CaptureResult, Deleted

    def enabled():
        if not service.enabled:
            raise APIError(503, "multimodal_disabled", "Multimodal processing is not enabled on this backend.", retryable=False)

    def owned(db, user_id, capture_id):
        capture = db.scalar(select(MultimodalCapture).where(MultimodalCapture.id == capture_id,
            MultimodalCapture.user_id == user_id, MultimodalCapture.deleted.is_(False)).with_for_update())
        if capture is None:
            raise APIError(404, "not_found", "Capture not found")
        return capture

    def editable(capture, revision):
        if capture.published_save_id:
            raise APIError(409, "capture_published", "This capture is already in the shared Library. Create a new capture to analyze different content.")
        if capture.revision != revision:
            raise APIError(409, "capture_revision_conflict", "The capture changed. Fetch its current revision before editing or analyzing.")

    @app.get("/v1/multimodal/capabilities", response_model=MultimodalCapabilities, tags=["Multimodal"])
    def capabilities(user_id=Depends(user)):
        return MultimodalCapabilities(enabled=service.enabled)

    @app.post("/v1/multimodal/captures", response_model=MultimodalView, status_code=201, tags=["Multimodal"])
    def create(body: MultimodalCreate, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        enabled()
        def operation():
            count = db.scalar(select(func.count()).select_from(MultimodalCapture).where(
                MultimodalCapture.user_id == user_id, MultimodalCapture.deleted.is_(False)))
            if count >= MAX_USER_CAPTURES:
                raise APIError(429, "multimodal_storage_limit", "Remove older captures before adding more.", retryable=False)
            capture = MultimodalCapture(user_id=user_id, **body.model_dump())
            db.add(capture)
            db.flush()
            return capture_view(db, capture)
        return mutate(db, user_id, key, "multimodal:create", body.model_dump(), operation)

    @app.get("/v1/multimodal/captures/{capture_id}", response_model=MultimodalView, tags=["Multimodal"])
    def get_capture(capture_id: str, user_id=Depends(user), db=Depends(database)):
        return capture_view(db, owned(db, user_id, capture_id))

    @app.patch("/v1/multimodal/captures/{capture_id}", response_model=MultimodalView, tags=["Multimodal"])
    def edit(capture_id: str, body: MultimodalEdit, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        enabled()
        def operation():
            capture = owned(db, user_id, capture_id)
            editable(capture, body.revision)
            changes = body.model_dump(exclude_unset=True, exclude={"revision"})
            if any(getattr(capture, name) != value for name, value in changes.items()):
                invalidate_capture(db, capture)
                for name, value in changes.items():
                    setattr(capture, name, value)
            return capture_view(db, capture)
        return mutate(db, user_id, key, f"multimodal:edit:{capture_id}", body.model_dump(exclude_unset=True), operation)

    @app.post("/v1/multimodal/captures/{capture_id}/assets", response_model=MultimodalView, tags=["Multimodal"])
    def upload(capture_id: str, body: MultimodalUpload, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        enabled()
        def operation():
            from .multimodal_provider import validate_audio
            capture = owned(db, user_id, capture_id)
            editable(capture, body.revision)
            try:
                raw = base64.b64decode(body.data_base64, validate=True)
                if not 0 < len(raw) <= MAX_ASSET_BYTES:
                    raise ValueError("Use an attachment of at most 4 MiB")
                mime = body.media_type
                kind = "image" if mime.startswith("image/") else "audio"
                if kind == "image":
                    normalized = validate_image_data_url(f"data:{mime};base64,{body.data_base64}")
                    header, encoded = normalized.split(",", 1)
                    raw, mime = base64.b64decode(encoded), header[5:-7]
                else:
                    mime = validate_audio(raw, mime)
            except (ValueError, binascii.Error):
                raise APIError(422, "invalid_asset", "Use a valid JPEG, PNG, WebP, or an AAC M4A/PCM WAV voice note of at most 60 seconds and 4 MiB.") from None
            content_hash = hashlib.sha256(mime.encode() + b"\0" + raw).hexdigest()
            assets = assets_for(db, capture)
            if any(a.content_hash == content_hash for a in assets):
                return capture_view(db, capture)
            if len(assets) >= 5 or sum(a.kind == kind for a in assets) >= (4 if kind == "image" else 1):
                raise APIError(422, "asset_limit", "Use at most four images and one voice note per capture.")
            user_bytes = db.scalar(select(func.coalesce(func.sum(MultimodalAsset.size_bytes), 0)).where(MultimodalAsset.user_id == user_id))
            if sum(a.size_bytes for a in assets) + len(raw) > MAX_CAPTURE_BYTES or user_bytes + len(raw) > MAX_USER_BYTES:
                raise APIError(429, "multimodal_storage_limit", "Remove older attachments before uploading more.", retryable=False)
            invalidate_capture(db, capture)
            db.add(MultimodalAsset(user_id=user_id, capture_id=capture.id, kind=kind, media_type=mime,
                content=raw, size_bytes=len(raw), content_hash=content_hash, status="ready" if kind == "image" else "pending"))
            db.flush()
            return capture_view(db, capture)
        # Only the digest is retained in mutation identity, never base64 bytes.
        payload = {"revision": body.revision, "media_type": body.media_type,
                   "sha256": hashlib.sha256(body.data_base64.encode()).hexdigest()}
        return mutate(db, user_id, key, f"multimodal:upload:{capture_id}", payload, operation)

    @app.get("/v1/multimodal/captures/{capture_id}/assets/{asset_id}", response_class=Response, tags=["Multimodal"],
             responses={200: {"description": "Private normalized attachment; authenticate as the capture owner.",
                 "content": {mime: {"schema": {"type": "string", "format": "binary"}}
                             for mime in ("image/jpeg", "image/png", "audio/mp4", "audio/wav")}}})
    def download(capture_id: str, asset_id: str, user_id=Depends(user), db=Depends(database)):
        owned(db, user_id, capture_id)
        asset = db.scalar(select(MultimodalAsset).where(MultimodalAsset.id == asset_id,
            MultimodalAsset.capture_id == capture_id, MultimodalAsset.user_id == user_id))
        if asset is None:
            raise APIError(404, "not_found", "Attachment not found")
        return Response(asset.content, media_type=asset.media_type, headers={"Cache-Control": "no-store", "Content-Disposition": "attachment"})

    @app.delete("/v1/multimodal/captures/{capture_id}/assets/{asset_id}", response_model=MultimodalView, tags=["Multimodal"])
    def remove_asset(capture_id: str, asset_id: str, body: MultimodalRevision, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        def operation():
            capture = owned(db, user_id, capture_id)
            editable(capture, body.revision)
            asset = db.scalar(select(MultimodalAsset).where(MultimodalAsset.id == asset_id,
                MultimodalAsset.capture_id == capture_id, MultimodalAsset.user_id == user_id))
            if asset is None:
                raise APIError(404, "not_found", "Attachment not found")
            invalidate_capture(db, capture)
            db.delete(asset)
            db.flush()
            db.execute(update(Mutation).where(Mutation.user_id == user_id).values(response={"_expired": True}))
            return capture_view(db, capture)
        return mutate(db, user_id, key, f"multimodal:remove_asset:{capture_id}:{asset_id}", body.model_dump(), operation)

    @app.patch("/v1/multimodal/captures/{capture_id}/assets/{asset_id}", response_model=MultimodalView, tags=["Multimodal"])
    def edit_transcript(capture_id: str, asset_id: str, body: MultimodalTranscriptEdit, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        enabled()
        def operation():
            capture = owned(db, user_id, capture_id)
            editable(capture, body.revision)
            asset = db.scalar(select(MultimodalAsset).where(MultimodalAsset.id == asset_id,
                MultimodalAsset.capture_id == capture_id, MultimodalAsset.user_id == user_id))
            if asset is None:
                raise APIError(404, "not_found", "Attachment not found")
            if asset.kind != "audio":
                raise APIError(422, "not_audio", "Only voice notes have editable transcripts.")
            if asset.transcript != body.transcript or asset.transcript_origin != "user":
                invalidate_capture(db, capture)
                asset.transcript, asset.transcript_origin, asset.status = body.transcript, "user", "ready"
            db.flush()
            return capture_view(db, capture)
        return mutate(db, user_id, key, f"multimodal:transcript:{capture_id}:{asset_id}", body.model_dump(), operation)

    @app.post("/v1/multimodal/captures/{capture_id}/analyze", response_model=MultimodalView, tags=["Multimodal"])
    def analyze(capture_id: str, body: MultimodalRevision, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        enabled()
        def operation():
            from .worker import enqueue
            capture = owned(db, user_id, capture_id)
            editable(capture, body.revision)
            if capture.stage in {"transcribing", "analyzing", "ready"}:
                return capture_view(db, capture)
            assets = assets_for(db, capture)
            if not assets and not any(value.strip() for value in (capture.title, capture.text, capture.note)):
                raise APIError(422, "capture_empty", "Add a photo, voice note, or product description before analyzing.")
            reserve_analysis(db, user_id, APIError)
            capture.status, capture.error_code = "pending", None
            capture.updated_at = time.time()
            audio = next((a for a in assets if a.kind == "audio" and a.status != "ready"), None)
            if audio:
                audio.status = "pending"
                capture.stage = "transcribing"
                enqueue(db, user_id, "multimodal_transcribe", {"capture_id": capture.id, "revision": capture.revision, "asset_id": audio.id})
            else:
                service.queue_analysis(db, capture)
            return capture_view(db, capture)
        return mutate(db, user_id, key, f"multimodal:analyze:{capture_id}", body.model_dump(), operation)

    @app.post("/v1/multimodal/captures/{capture_id}/publish", response_model=CaptureResult, tags=["Multimodal"])
    def publish(capture_id: str, body: MultimodalRevision, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        enabled()
        def operation():
            from .worker import publish_annotation
            from .intelligence import claims_in
            capture = owned(db, user_id, capture_id)
            if capture.revision != body.revision:
                raise APIError(409, "capture_revision_conflict", "Fetch the current capture before publishing.")
            if capture.published_save_id:
                return {"id": capture.published_save_id, "status": "ready", "duplicate": True}
            if capture.status != "ready" or capture.result is None:
                raise APIError(409, "analysis_not_ready", "Wait for analysis to finish before publishing to the shared Library.")
            assets = assets_for(db, capture)
            image = next((a for a in assets if a.kind == "image"), None)
            item = SavedItem(user_id=user_id, title=capture.title or capture.result["preview"].get("product_name") or "Saved content",
                original_url=capture.url or "", canonical_url="multimodal:" + capture.id, source="other", client=capture.client,
                selected_text=capture.text, note=capture.note,
                image_data_url="data:" + image.media_type + ";base64," + base64.b64encode(image.content).decode() if image else None)
            db.add(item)
            db.flush()
            annotation = annotation_from_result(capture.result, capture.model_version, image_present=image is not None)
            publish_annotation(db, item, annotation, capture.model_version)
            capture.published_save_id = item.id
            # Voice is explicit user context, not an inferred personal preference.
            for note in [capture.note, *(a.transcript for a in assets if a.transcript)]:
                if not note.strip():
                    continue
                event = UserEvent(user_id=user_id, item_id=item.id, event_type="capture_note", payload={"text": note})
                db.add(event)
                db.flush()
                for claim in claims_in(note):
                    db.add(Evidence(user_id=user_id, item_id=item.id, event_id=event.id, claim=claim, text=note, origin="explicit_statement"))
            library.update_search_document(db, item)
            state_for(db, user_id).version += 1
            return {"id": item.id, "status": "ready", "duplicate": False}
        return mutate(db, user_id, key, f"multimodal:publish:{capture_id}", body.model_dump(), operation)

    @app.delete("/v1/multimodal/captures/{capture_id}", response_model=Deleted, tags=["Multimodal"])
    def remove(capture_id: str, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        def operation():
            capture = owned(db, user_id, capture_id)
            if capture.published_save_id:
                raise APIError(409, "capture_published", "Delete this item through its shared Library save so all supporting evidence is removed together.")
            erase_capture(db, capture)
            return {"deleted": True}
        return mutate(db, user_id, key, f"multimodal:delete:{capture_id}", {}, operation)
