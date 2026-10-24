import hashlib
import json
import logging
import os
import secrets
import threading
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlsplit

from fastapi import Depends, FastAPI, Header, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.openapi.utils import get_openapi
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy import delete, select, update
from sqlalchemy.exc import IntegrityError
from starlette.exceptions import HTTPException

from .contracts import AnnotationResponse, Capture, CreateWatch, DiscoveryEvent, HypothesisFeedback, SimulatedPrice, StartDiscovery, UpdateWatch, canonical_url
from .db import Base, DiscoverySession, Evidence, Job, Mutation, Notification, Observation, SavedItem, SavedMedia, Suggestion, UserEvent, UserState, Watch, make_database
from .content import MAX_IMAGE_BYTES, NEXT_STEPS, decode_image, provider_name
from .intelligence import CATALOG, claims_in, context, shortlist
from .worker import enqueue, run_forever
from . import responses as schema


class APIError(Exception):
    def __init__(self, status, code, message, current=None):
        self.status, self.code, self.message, self.current = status, code, message, current


def row_dict(row):
    return {column.name: getattr(row, column.name) for column in row.__table__.columns if column.name != "user_id"}


def create_app(database_url=None, embedded_worker=None, tokens=None, demo_mode=None, allowed_origins=None):
    engine, factory = make_database(database_url)
    tokens = tokens if tokens is not None else json.loads(os.getenv("API_TOKENS", '{"demo-alex":"alex","demo-sam":"sam"}'))
    demo_mode = demo_mode if demo_mode is not None else os.getenv("DEMO_MODE", "true").lower() == "true"
    embedded_worker = embedded_worker if embedded_worker is not None else os.getenv("EMBEDDED_WORKER", "true").lower() == "true"
    if not tokens or not all(isinstance(k, str) and isinstance(v, str) and k and v for k, v in tokens.items()):
        raise RuntimeError("API_TOKENS must map nonempty bearer tokens to user IDs")
    if not demo_mode and any(k in {"demo-alex", "demo-sam"} for k in tokens):
        raise RuntimeError("Replace demo tokens before disabling demo mode")

    @asynccontextmanager
    async def lifespan(app):
        # Local convenience only; PostgreSQL/managed environments use Alembic.
        if engine.dialect.name == "sqlite":
            Base.metadata.create_all(engine)
        stop = threading.Event()
        worker = None
        if embedded_worker:
            worker = threading.Thread(target=run_forever, args=(factory, stop), daemon=True)
            worker.start()
        yield
        stop.set()
        if worker:
            worker.join(timeout=5)
        engine.dispose()

    app = FastAPI(title="Mynah Finds API", version="0.3.0", lifespan=lifespan,
        description="Shared Chrome and iOS backend. Local development bearer tokens; integer minor-unit prices; Unix seconds UTC. Mutation requests require Idempotency-Key. Demo inference and commerce are explicitly labeled.",
        responses={status: {"model": schema.ErrorEnvelope} for status in [400, 401, 404, 409, 410, 422, 500, 503]})
    app.state.factory = factory
    origins = allowed_origins if allowed_origins is not None else json.loads(os.getenv("CORS_ORIGINS", "[]"))
    def exact_origin(origin):
        if not isinstance(origin, str) or "*" in origin:
            return False
        parsed = urlsplit(origin)
        return parsed.scheme in {"http", "https", "chrome-extension"} and bool(parsed.netloc) and not (parsed.path or parsed.query or parsed.fragment or parsed.username or parsed.password)
    if not isinstance(origins, list) or not all(exact_origin(origin) for origin in origins):
        raise RuntimeError("CORS_ORIGINS must be a JSON list of exact origins without wildcards")
    app.add_middleware(CORSMiddleware, allow_origins=origins, allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"], allow_headers=["Authorization", "Content-Type", "Idempotency-Key"], expose_headers=["X-Request-ID"], allow_credentials=False)
    bearer = HTTPBearer(auto_error=False, scheme_name="DevelopmentBearer", description="Use a configured development token, e.g. demo-alex locally. Production identity is a separate backend integration.")

    @app.middleware("http")
    async def request_metadata(request, call_next):
        request.state.request_id = uuid.uuid4().hex
        # Bound streaming uploads as well as requests with Content-Length.
        if request.method in {"POST", "PATCH"}:
            chunks, size = [], 0
            async for chunk in request.stream():
                size += len(chunk)
                if size > 6 * 1024 * 1024:
                    return error_response(request, 413, "payload_too_large", "Capture exceeds the 6 MiB request limit")
                chunks.append(chunk)
            request._body = b"".join(chunks)
        response = await call_next(request)
        response.headers["X-Request-ID"] = request.state.request_id
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        if request.url.path.startswith("/v1/"):
            response.headers["Cache-Control"] = "no-store"
        response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'"
        if request.url.path in {"/docs", "/redoc"}:
            # FastAPI's optional documentation UI uses its standard CDN bundles.
            response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data: https://fastapi.tiangolo.com; connect-src 'self'; frame-ancestors 'none'"
        return response

    def error_response(request, status, code, message, current=None):
        body = {"code": code, "message": message, "retryable": status in {429, 503}, "request_id": request.state.request_id}
        if current is not None:
            body["current"] = schema.DiscoveryView.model_validate(current).model_dump()
        # Unhandled exceptions are rendered outside the user middleware stack.
        # Preserve correlation and configured browser access on those errors too.
        headers = {"X-Request-ID": request.state.request_id}
        origin = request.headers.get("origin")
        if origin in origins:
            headers.update({"Access-Control-Allow-Origin": origin, "Access-Control-Expose-Headers": "X-Request-ID", "Vary": "Origin"})
        return JSONResponse(status_code=status, content={"error": body}, headers=headers)

    @app.exception_handler(APIError)
    async def api_error(request, error):
        return error_response(request, error.status, error.code, error.message, error.current)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request, error):
        return error_response(request, 422, "invalid_request", "; ".join(f"{'.'.join(str(p) for p in e['loc'])}: {e['msg']}" for e in error.errors()))

    @app.exception_handler(IntegrityError)
    async def conflict_error(request, error):
        return error_response(request, 409, "concurrent_mutation", "A concurrent request changed this record. Retry with the same idempotency key.")

    @app.exception_handler(HTTPException)
    async def http_error(request, error):
        return error_response(request, error.status_code, "http_error", str(error.detail))

    @app.exception_handler(Exception)
    async def unexpected_error(request, error):
        logging.getLogger(__name__).error("request_failed id=%s error_type=%s", request.state.request_id, type(error).__name__)
        return error_response(request, 500, "internal_error", "The request could not be completed. Use the request ID to inspect server diagnostics.")

    def user(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
        provided = credentials.credentials if credentials else ""
        for token, user_id in tokens.items():
            if secrets.compare_digest(provided, token):
                return user_id
        raise APIError(401, "unauthorized", "A valid bearer token is required")

    def database(request: Request):
        with factory.begin() as db:
            # SQLite FOR UPDATE is a no-op. Reserve its writer lock before any
            # mutation reads so two clients cannot both accept the same version.
            if engine.dialect.name == "sqlite" and request.method in {"POST", "PATCH", "DELETE"}:
                db.connection().exec_driver_sql("BEGIN IMMEDIATE")
            yield db

    def page_rows(db, query, offset, limit):
        if offset < 0 or not 1 <= limit <= 100:
            raise APIError(422, "invalid_pagination", "Offset must be nonnegative and limit between 1 and 100")
        rows = db.scalars(query.offset(offset).limit(limit + 1)).all()
        return rows[:limit], offset + limit if len(rows) > limit else None

    def owned(db, model, record_id, user_id):
        row = db.scalar(select(model).where(model.id == record_id, model.user_id == user_id))
        if row is None or (isinstance(row, SavedItem) and row.deleted):
            raise APIError(404, "not_found", "Record not found")
        return row

    def state_for(db, user_id):
        # Lock all API writes by user on PostgreSQL; SQLite serializes writes.
        state = db.scalar(select(UserState).where(UserState.user_id == user_id).with_for_update())
        if state is None:
            state = UserState(user_id=user_id, version=1, suppressed=False, cooldown_until=0)
            db.add(state)
            db.flush()
        return state

    def mutate(db, user_id, key, operation, payload, callback):
        if not key or len(key) > 128:
            raise APIError(400, "idempotency_key_required", "Provide an Idempotency-Key header (1–128 characters)")
        state_for(db, user_id)
        fingerprint = hashlib.sha256(json.dumps([operation, payload], sort_keys=True).encode()).hexdigest()
        existing = db.scalar(select(Mutation).where(Mutation.user_id == user_id, Mutation.key == key))
        if existing:
            if existing.fingerprint != fingerprint:
                raise APIError(409, "idempotency_conflict", "This key was already used for a different request")
            if existing.response.get("_expired"):
                raise APIError(410, "mutation_expired", "This result was invalidated by a deletion. Refresh state; do not automatically replay this action with a new key.")
            return existing.response
        response = callback()
        db.add(Mutation(user_id=user_id, key=key, fingerprint=fingerprint, response=response))
        db.flush()
        return response

    def item_view(db, item):
        return {**row_dict(item), "has_image": db.scalar(select(SavedMedia.item_id).where(SavedMedia.item_id == item.id, SavedMedia.user_id == item.user_id)) is not None,
                "suggestions": [{**row_dict(s), "status": "proposed", "next_step": NEXT_STEPS.get(s.kind, NEXT_STEPS["explore"])} for s in db.scalars(select(Suggestion).where(Suggestion.item_id == item.id, Suggestion.user_id == item.user_id))],
                "responses": [row_dict(e) for e in db.scalars(select(UserEvent).where(UserEvent.item_id == item.id, UserEvent.user_id == item.user_id).order_by(UserEvent.occurred_at, UserEvent.id))]}

    def session_view(db, session):
        current = context(db, session.user_id)
        valid = {e["id"] for e in current["evidence"]}
        stale = not set(session.evidence_ids).issubset(valid)
        paused = session.stage in {"paused", "dismissed"}
        action = "wait" if paused else "clarify" if stale else "track" if session.stage == "ready" else "compare" if session.stage == "comparing" else "choose_direction"
        products = [] if stale or paused or session.stage not in {"comparing", "ready", "handed_off"} else shortlist(session.preferences)
        return {**row_dict(session), "context_stale": stale, "products": products, "next_action": {"action_type": action, "evidence_ids": [e for e in session.evidence_ids if e in valid], "reason_codes": ["source_evidence_removed"] if stale else ["session_preferences"], "missing_information": [] if session.preferences.get("budget_minor") else ["budget"]}}

    @app.get("/health", response_model=schema.Health, tags=["System"])
    def health():
        return {"status": "ok", "demo_mode": demo_mode, "inference_provider": provider_name()}

    @app.get("/v1/me", response_model=schema.Identity, tags=["System"])
    def me(user_id=Depends(user)):
        return {"user_id": user_id, "demo_mode": demo_mode, "inference_provider": provider_name()}

    @app.get("/v1/capabilities", response_model=schema.Capabilities, tags=["System"])
    def capabilities(user_id=Depends(user)):
        return {"api_version": "v1", "contract_version": "0.3.0", "authentication": "development_bearer",
            "capture": {"clients": ["web", "chrome_extension", "ios_app", "ios_share_extension"], "content_types": ["url", "selected_text", "note", "image"], "max_url_length": 2048, "max_title_length": 300, "max_selected_text_length": 12000, "max_note_length": 2000, "max_image_bytes": MAX_IMAGE_BYTES},
            "data_modes": {"annotations": provider_name(), "catalog": "fixture", "tracking": "simulated"},
            "features": {"annotations": True, "discovery": True, "watches": True, "price_simulation": demo_mode, "demo_reset": demo_mode, "image_upload": True, "multimodal_ai": provider_name() == "openai" and bool(os.getenv("OPENAI_API_KEY")), "live_price_monitoring": False, "push_notifications": False, "merchant_handoff": False, "personal_agent_connector": False},
            "currencies": ["SGD"], "refresh": {"strategy": "poll_on_foreground", "pending_save_interval_ms": 1500, "pending_save_timeout_ms": 30000, "incremental_sync": False}}

    @app.post("/v1/saves", status_code=201, response_model=schema.CaptureResult, tags=["Capture"])
    def capture(body: Capture, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        def operation():
            image_hash = hashlib.sha256(decode_image(body.image_data)).hexdigest() if body.image_data else ""
            canonical = f"image:{image_hash}" if image_hash else canonical_url(body.url)
            item = db.scalar(select(SavedItem).where(SavedItem.user_id == user_id, SavedItem.canonical_url == canonical))
            if item and not item.deleted:
                return {"id": item.id, "status": item.status, "duplicate": True}
            if item:
                item.deleted = False
                item.revision += 1
                item.status = "pending"
                item.title, item.selected_text, item.note = body.title, body.selected_text, body.note
                item.original_url, item.source, item.captured_at = body.url, body.source, time.time()
                item.client = body.client
                item.features = {}
                db.execute(delete(Suggestion).where(Suggestion.item_id == item.id))
            else:
                item = SavedItem(user_id=user_id, original_url=body.url, canonical_url=canonical, title=body.title, source=body.source, client=body.client, selected_text=body.selected_text, note=body.note)
                db.add(item)
                db.flush()
            if body.image_data:
                db.merge(SavedMedia(item_id=item.id, user_id=user_id, image_data=body.image_data))
            normalized = " ".join(body.selected_text.casefold().split())
            item.content_hash = image_hash or (hashlib.sha256(normalized.encode()).hexdigest() if normalized else "")
            enqueue(db, user_id, "enrich", {"item_id": item.id, "revision": item.revision})
            if body.note.strip():
                event = UserEvent(user_id=user_id, item_id=item.id, event_type="capture_note", payload={"text": body.note})
                db.add(event)
                db.flush()
                for claim in claims_in(body.note):
                    db.add(Evidence(user_id=user_id, item_id=item.id, event_id=event.id, claim=claim, text=body.note, origin="explicit_statement"))
            state_for(db, user_id).version += 1
            return {"id": item.id, "status": item.status, "duplicate": False}
        return mutate(db, user_id, key, "capture", body.model_dump(), operation)

    @app.get("/v1/collection", response_model=schema.CollectionPage, tags=["Capture"])
    def collection(offset: int = 0, limit: int = 30, user_id=Depends(user), db=Depends(database)):
        if offset < 0 or not 1 <= limit <= 100:
            raise APIError(422, "invalid_pagination", "Offset must be nonnegative and limit between 1 and 100")
        rows = db.scalars(select(SavedItem).where(SavedItem.user_id == user_id, SavedItem.deleted.is_(False)).order_by(SavedItem.captured_at.desc(), SavedItem.id).offset(offset).limit(limit + 1)).all()
        return {"items": [item_view(db, item) for item in rows[:limit]], "next_offset": offset + limit if len(rows) > limit else None}

    @app.get("/v1/saves/{item_id}", response_model=schema.SavedItemView, tags=["Capture"])
    def get_save(item_id: str, user_id=Depends(user), db=Depends(database)):
        return item_view(db, owned(db, SavedItem, item_id, user_id))

    @app.get("/v1/saves/{item_id}/media", response_model=schema.SavedMediaView, tags=["Capture"])
    def get_media(item_id: str, user_id=Depends(user), db=Depends(database)):
        owned(db, SavedItem, item_id, user_id)
        media = db.get(SavedMedia, item_id)
        if not media or media.user_id != user_id:
            raise APIError(404, "not_found", "Image not found")
        return {"image_data": media.image_data}

    @app.post("/v1/saves/{item_id}/retry", response_model=schema.CaptureResult, tags=["Capture"])
    def retry_save(item_id: str, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        def operation():
            item = owned(db, SavedItem, item_id, user_id)
            if item.status == "enrichment_failed" or (item.status == "ready" and provider_name() == "openai" and item.features.get("data_mode") != "openai"):
                item.revision += 1
                item.status = "pending"
                item.features = {}
                db.execute(delete(Suggestion).where(Suggestion.item_id == item.id, Suggestion.user_id == user_id))
                enqueue(db, user_id, "enrich", {"item_id": item.id, "revision": item.revision})
            return {"id": item.id, "status": item.status, "duplicate": False}
        return mutate(db, user_id, key, f"retry:{item_id}", {}, operation)

    @app.post("/v1/saves/{item_id}/responses", response_model=schema.AnnotationResult, tags=["Capture"])
    def respond(item_id: str, body: AnnotationResponse, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        def operation():
            item = owned(db, SavedItem, item_id, user_id)
            suggestion = owned(db, Suggestion, body.suggestion_id, user_id) if body.suggestion_id else None
            if suggestion and suggestion.item_id != item_id:
                raise APIError(422, "wrong_suggestion", "Suggestion belongs to a different save")
            if body.action == "select" and not suggestion:
                raise APIError(422, "suggestion_required", "Select a suggestion or use edit for your own text")
            if body.action == "edit" and not body.text.strip():
                raise APIError(422, "text_required", "An edit needs your own explanation")
            # Responses supersede earlier evidence for this proposal, retaining history.
            if suggestion or item.features.get("question"):
                prior = db.scalars(select(UserEvent).where(UserEvent.user_id == user_id, UserEvent.item_id == item_id)).all()
                prior_ids = [e.id for e in prior if e.event_type == "annotation_response" and (item.features.get("question") or e.payload.get("suggestion_id") == suggestion.id)]
                if prior_ids:
                    db.execute(update(Evidence).where(Evidence.user_id == user_id, Evidence.event_id.in_(prior_ids)).values(active=False))
            event = UserEvent(user_id=user_id, item_id=item_id, event_type="annotation_response", payload={**body.model_dump(),
                              "label": suggestion.text if suggestion and body.action == "select" else body.text,
                              "next_step": NEXT_STEPS.get(suggestion.kind, NEXT_STEPS["explore"]) if suggestion else "Your context is saved. No purchase or monitoring has been started."})
            db.add(event)
            db.flush()
            if body.action in {"select", "edit"}:
                text = suggestion.text if body.action == "select" else body.text
                claims = [suggestion.claim] if body.action == "select" else claims_in(text)
                for claim in claims:
                    db.add(Evidence(user_id=user_id, item_id=item_id, event_id=event.id, claim=claim, text=text, origin="confirmed_annotation" if body.action == "select" else "explicit_statement"))
            state_for(db, user_id).version += 1
            db.flush()
            return {"event_id": event.id, "hypothesis": context(db, user_id)}
        return mutate(db, user_id, key, f"respond:{item_id}", body.model_dump(), operation)

    @app.delete("/v1/saves/{item_id}", response_model=schema.Deleted, tags=["Capture"])
    def remove_save(item_id: str, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        def operation():
            item = owned(db, SavedItem, item_id, user_id)
            item.deleted = True
            item.revision += 1
            # Erase captured text while keeping a dedupe tombstone and event provenance.
            item.title, item.note, item.selected_text, item.features = "Deleted save", "", "", {}
            db.execute(update(Evidence).where(Evidence.item_id == item_id, Evidence.user_id == user_id).values(active=False, text="[removed]"))
            db.execute(update(UserEvent).where(UserEvent.item_id == item_id, UserEvent.user_id == user_id).values(payload={"removed": True}))
            db.execute(delete(Suggestion).where(Suggestion.item_id == item_id, Suggestion.user_id == user_id))
            db.execute(delete(SavedMedia).where(SavedMedia.item_id == item_id, SavedMedia.user_id == user_id))
            # Cached mutation responses may contain an old evidence snapshot.
            db.execute(update(Mutation).where(Mutation.user_id == user_id).values(response={"_expired": True}))
            state_for(db, user_id).version += 1
            return {"deleted": True}
        return mutate(db, user_id, key, f"delete:{item_id}", {}, operation)

    @app.get("/v1/hypotheses", response_model=schema.Hypotheses, tags=["Discovery"])
    def hypotheses(user_id=Depends(user), db=Depends(database)):
        return {"items": [context(db, user_id)]}

    @app.post("/v1/hypotheses/{hypothesis_id}/feedback", response_model=schema.HypothesisView, tags=["Discovery"])
    def feedback(hypothesis_id: str, body: HypothesisFeedback, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        if hypothesis_id != "desk-lighting":
            raise APIError(404, "not_found", "Hypothesis not found")
        def operation():
            state = state_for(db, user_id)
            state.suppressed = body.action in {"dismiss", "misunderstood"}
            state.cooldown_until = time.time() + 86400 if body.action == "keep_collecting" else 0
            state.version += 1
            db.add(UserEvent(user_id=user_id, event_type="hypothesis_feedback", payload=body.model_dump()))
            if body.action != "confirm":
                db.execute(update(DiscoverySession).where(DiscoverySession.user_id == user_id, DiscoverySession.stage.not_in(["dismissed", "handed_off"])).values(stage="paused" if body.action == "keep_collecting" else "dismissed", version=DiscoverySession.version + 1))
            return context(db, user_id)
        return mutate(db, user_id, key, "hypothesis_feedback", body.model_dump(), operation)

    @app.post("/v1/discovery-sessions", status_code=201, response_model=schema.DiscoveryView, tags=["Discovery"])
    def start_discovery(body: StartDiscovery, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        def operation():
            current = context(db, user_id)
            if not body.explicit and current["status"] != "invitable":
                raise APIError(409, "not_eligible", "Keep collecting or explicitly start an exploration")
            session = DiscoverySession(user_id=user_id, context_version=current["context_version"], evidence_ids=current["decision"]["evidence_ids"], preferences={"low_clutter": "low_clutter" in current["confirmed_preferences"]})
            db.add(session)
            db.flush()
            return session_view(db, session)
        return mutate(db, user_id, key, "start_discovery", body.model_dump(), operation)

    @app.get("/v1/discovery-sessions", response_model=schema.Discoveries, tags=["Discovery"])
    def sessions(offset: int = 0, limit: int = 30, user_id=Depends(user), db=Depends(database)):
        rows, next_offset = page_rows(db, select(DiscoverySession).where(DiscoverySession.user_id == user_id).order_by(DiscoverySession.created_at.desc(), DiscoverySession.id), offset, limit)
        return {"items": [session_view(db, s) for s in rows], "next_offset": next_offset}

    @app.get("/v1/discovery-sessions/{session_id}", response_model=schema.DiscoveryView, tags=["Discovery"])
    def get_session(session_id: str, user_id=Depends(user), db=Depends(database)):
        return session_view(db, owned(db, DiscoverySession, session_id, user_id))

    @app.post("/v1/discovery-sessions/{session_id}/events", response_model=schema.DiscoveryView, tags=["Discovery"])
    def session_event(session_id: str, body: DiscoveryEvent, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        def operation():
            session = owned(db, DiscoverySession, session_id, user_id)
            if session.version != body.expected_version:
                raise APIError(409, "stale_version", "Session changed. Refresh before applying your feedback.", session_view(db, session))
            if session.stage == "dismissed" or (session.stage == "paused" and body.action != "resume"):
                raise APIError(409, "inactive_session", "Start a new exploration or resume your paused session")
            if session_view(db, session)["context_stale"] and body.action not in {"pause", "dismiss"}:
                raise APIError(409, "stale_evidence", "Source evidence changed. Start a new exploration.")
            preferences = dict(session.preferences)
            if body.action == "direction":
                if body.value not in {"warm", "focused"}:
                    raise APIError(422, "invalid_direction", "Choose warm or focused")
                preferences["direction"] = body.value
                session.stage = "exploring"
            elif body.action in {"budget", "max_width"}:
                if body.action == "max_width" and body.value is None:
                    preferences.pop("max_width_cm", None)
                elif type(body.value) is not int or body.value <= 0 or body.value > 10000000:
                    raise APIError(422, "invalid_constraint", "Enter a positive integer (budget in cents, width in cm)")
                else:
                    preferences["budget_minor" if body.action == "budget" else "max_width_cm"] = body.value
                session.stage = "exploring"
            elif body.action == "less_clutter":
                preferences["low_clutter"] = True
                session.stage = "exploring"
            elif body.action == "already_own":
                if body.value not in {p["variant_id"] for p in CATALOG}:
                    raise APIError(422, "invalid_variant", "Choose a catalog variant")
                preferences["owned"] = sorted(set(preferences.get("owned", []) + [body.value]))
                session.stage = "exploring"
            elif body.action == "too_expensive":
                preferences.pop("budget_minor", None)
                session.stage = "exploring"
            elif body.action == "retrieve":
                if not preferences.get("budget_minor"):
                    raise APIError(422, "budget_required", "Set an item-price budget before retrieving products")
                session.stage = "comparing"
            elif body.action == "choose":
                if session.stage != "comparing" or body.value not in {p["variant_id"] for p in shortlist(preferences)}:
                    raise APIError(422, "invalid_choice", "Choose a variant from the current shortlist")
                preferences["selected_variant"] = body.value
                session.stage = "ready"
            elif body.action == "handoff":
                raise APIError(409, "fixture_catalog", "Demo products have no verified purchase link. Connect a real catalog adapter first.")
            elif body.action in {"pause", "dismiss", "resume"}:
                session.stage = {"pause": "paused", "dismiss": "dismissed", "resume": "exploring"}[body.action]
            if body.action not in {"choose", "handoff"}:
                preferences.pop("selected_variant", None)
            session.preferences = preferences
            session.version += 1
            db.add(UserEvent(user_id=user_id, event_type="discovery_feedback", payload={"session_id": session.id, **body.model_dump()}))
            db.flush()
            return session_view(db, session)
        return mutate(db, user_id, key, f"session:{session_id}", body.model_dump(), operation)

    @app.get("/v1/catalog", response_model=schema.Catalog, tags=["Commerce"])
    def catalog(user_id=Depends(user)):
        return {"items": CATALOG, "data_mode": "fixture"}

    @app.post("/v1/watches", status_code=201, response_model=schema.WatchView, tags=["Commerce"])
    def create_watch(body: CreateWatch, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        def operation():
            if body.variant_id not in {p["variant_id"] for p in CATALOG}:
                raise APIError(422, "invalid_variant", "Unknown exact variant")
            watch = Watch(user_id=user_id, **body.model_dump())
            db.add(watch)
            db.flush()
            return {**row_dict(watch), "price_basis": "item_price_excluding_shipping", "data_mode": "simulated"}
        return mutate(db, user_id, key, "create_watch", body.model_dump(), operation)

    @app.get("/v1/watches", response_model=schema.Watches, tags=["Commerce"])
    def watches(offset: int = 0, limit: int = 30, user_id=Depends(user), db=Depends(database)):
        rows, next_offset = page_rows(db, select(Watch).where(Watch.user_id == user_id).order_by(Watch.id), offset, limit)
        return {"items": [row_dict(w) for w in rows], "next_offset": next_offset}

    @app.get("/v1/watches/{watch_id}", response_model=schema.WatchView, tags=["Commerce"])
    def get_watch(watch_id: str, user_id=Depends(user), db=Depends(database)):
        return row_dict(owned(db, Watch, watch_id, user_id))

    @app.patch("/v1/watches/{watch_id}", response_model=schema.WatchView, tags=["Commerce"])
    def update_watch(watch_id: str, body: UpdateWatch, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        def operation():
            watch = owned(db, Watch, watch_id, user_id)
            changed = {field: value for field, value in body.model_dump(exclude_none=True).items() if getattr(watch, field) != value}
            for field, value in changed.items():
                setattr(watch, field, value)
            if changed:
                watch.rule_version += 1
                watch.below = False
            return row_dict(watch)
        return mutate(db, user_id, key, f"watch:{watch_id}", body.model_dump(), operation)

    @app.post("/v1/watches/{watch_id}/simulate", response_model=schema.QueuedPriceCheck, tags=["Demo"])
    def simulate_price(watch_id: str, body: SimulatedPrice, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        if not demo_mode:
            raise APIError(404, "not_found", "Demo simulation is disabled")
        def operation():
            watch = owned(db, Watch, watch_id, user_id)
            if not watch.enabled:
                raise APIError(409, "watch_paused", "Resume this watch before checking")
            if body.variant_id != watch.variant_id or body.currency != watch.currency:
                raise APIError(422, "variant_mismatch", "Observation must match the exact variant and currency")
            job_id = enqueue(db, user_id, "price_check", {"watch_id": watch.id, "rule_version": watch.rule_version, "observed_at": time.time(), **body.model_dump()})
            return {"job_id": job_id, "data_mode": "simulated"}
        return mutate(db, user_id, key, f"simulate:{watch_id}", body.model_dump(), operation)

    @app.get("/v1/notifications", response_model=schema.Notifications, tags=["Commerce"])
    def notifications(offset: int = 0, limit: int = 30, user_id=Depends(user), db=Depends(database)):
        rows, next_offset = page_rows(db, select(Notification).where(Notification.user_id == user_id).order_by(Notification.id), offset, limit)
        return {"items": [row_dict(n) for n in rows], "next_offset": next_offset}

    @app.get("/v1/jobs/{job_id}", response_model=schema.JobView, tags=["System"])
    def job_status(job_id: str, user_id=Depends(user), db=Depends(database)):
        return row_dict(owned(db, Job, job_id, user_id))

    @app.get("/v1/trace", response_model=schema.TraceView, tags=["Demo"])
    def trace(user_id=Depends(user), db=Depends(database)):
        return {"hypothesis": context(db, user_id), "jobs": [{"id": j.id, "kind": j.kind, "status": j.status, "attempts": j.attempts, "error": j.error} for j in db.scalars(select(Job).where(Job.user_id == user_id).order_by(Job.due_at.desc()).limit(30))], "provider": "demo-rules-v1", "catalog_mode": "fixture", "tracking_mode": "simulated"}

    @app.post("/v1/demo/reset", response_model=schema.Reset, tags=["Demo"])
    def reset(user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        if not demo_mode:
            raise APIError(404, "not_found", "Demo reset is disabled")
        def operation():
            for model in [Notification, Observation, Watch, DiscoverySession, Evidence, Suggestion, UserEvent, Job, SavedMedia, SavedItem, Mutation]:
                db.execute(delete(model).where(model.user_id == user_id))
            state = state_for(db, user_id)
            state.version += 1
            state.suppressed, state.cooldown_until = False, 0
            return {"reset": True}
        return mutate(db, user_id, key, "reset", {}, operation)

    def public_openapi():
        if app.openapi_schema is None:
            contract = get_openapi(title=app.title, version=app.version, description=app.description, routes=app.routes)
            for path in contract["paths"].values():
                for operation in path.values():
                    if not isinstance(operation, dict):
                        continue
                    for parameter in operation.get("parameters", []):
                        if parameter.get("name") == "Idempotency-Key":
                            parameter["required"] = True
                            parameter["description"] = "Required for every mutation. Persist before sending; reuse the key and identical body after an uncertain result. Missing/empty keys return 400."
                            parameter["schema"] = {"type": "string", "minLength": 1, "maxLength": 128}
            app.openapi_schema = contract
        return app.openapi_schema
    app.openapi = public_openapi
    app.mount("/", StaticFiles(directory=Path(__file__).resolve().parents[2] / "frontend", html=True), name="frontend")
    return app


app = create_app()
