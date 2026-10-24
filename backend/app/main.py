import base64
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

from fastapi import Depends, FastAPI, Header, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.openapi.utils import get_openapi
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy import and_, delete, or_, select, update
from sqlalchemy.exc import IntegrityError
from starlette.exceptions import HTTPException

from .contracts import AnnotationResponse, Capture, CreateWatch, DiscoveryEvent, HypothesisFeedback, SimulatedPrice, StartDiscovery, UpdateWatch, canonical_url
from .db import Base, DiscoverySession, Evidence, Job, MultimodalAsset, MultimodalCapture, Mutation, Notification, Observation, SavedItem, Suggestion, UserEvent, UserState, Watch, make_database
from .intelligence import CATALOG, claims_in, context, shortlist
from .worker import enqueue, run_forever
from .predictive import get_annotation_provider
from .request_limits import BodyLimitMiddleware
from . import responses as schema
from .catalog import schemas as catalog_schema
from .catalog import service as catalog_service
from .catalog.registry import DATASET_SOURCES
from .catalog.rakuten import RakutenClient
from . import library as library_service
from .explore import ExplorePage, explore as explore_products
from .multimodal import MultimodalService, register_multimodal, erase_for_saved_item, reserve_analysis


class APIError(Exception):
    def __init__(self, status, code, message, current=None, retryable=None):
        self.status, self.code, self.message, self.current = status, code, message, current
        self.retryable = retryable


def row_dict(row):
    return {column.name: getattr(row, column.name) for column in row.__table__.columns if column.name not in {"user_id", "image_data_url"}}


def create_app(database_url=None, embedded_worker=None, tokens=None, demo_mode=None, allowed_origins=None, annotation_provider=None, rakuten_client=None,
               multimodal_provider=None, multimodal_enabled=None):
    engine, factory = make_database(database_url)
    provider = annotation_provider if annotation_provider is not None else get_annotation_provider()
    multimodal = MultimodalService(factory, provider=multimodal_provider, enabled=multimodal_enabled)
    rakuten = rakuten_client if rakuten_client is not None else RakutenClient.from_env()
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
            worker = threading.Thread(target=run_forever, args=(factory, stop, provider, multimodal), daemon=True)
            worker.start()
        yield
        stop.set()
        if worker:
            worker.join(timeout=45)
        elif hasattr(provider, "close"):
            provider.close()
        if not embedded_worker:
            multimodal.close()
        rakuten.close()
        engine.dispose()

    app = FastAPI(title="Mymah Finds API", version="0.4.0", lifespan=lifespan,
        description="Shared Chrome and iOS backend. Server-configured predictive annotations; integer minor-unit prices; Unix seconds UTC. Mutation requests require Idempotency-Key. Suggestions record intent only; actions require separate confirmation and implementation.",
        responses={status: {"model": schema.ErrorEnvelope} for status in [400, 401, 404, 409, 410, 422, 429, 500, 503]})
    app.state.factory = factory
    app.state.annotation_provider = provider
    app.state.rakuten_client = rakuten
    app.state.multimodal = multimodal
    app.add_middleware(BodyLimitMiddleware, max_bytes=6 * 1024 * 1024)
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

    def error_response(request, status, code, message, current=None, retryable=None):
        body = {"code": code, "message": message, "retryable": status in {429, 503} if retryable is None else retryable, "request_id": request.state.request_id}
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
        return error_response(request, error.status, error.code, error.message, error.current, error.retryable)

    @app.exception_handler(catalog_service.CatalogError)
    async def catalog_error(request, error):
        if error.code.startswith("rakuten_"):
            retryable = error.code in {"rakuten_rate_limited", "rakuten_unavailable"}
            status = 429 if error.code == "rakuten_rate_limited" else 503
            return error_response(request, status, error.code, error.message, retryable=retryable)
        status = 503 if error.code in {"catalog_not_configured", "explore_context_changed"} else 404 if error.code == "catalog_record_not_found" else 422
        return error_response(request, status, error.code, error.message, retryable=error.code == "explore_context_changed")

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
        analysis = library_service.product_analysis(item)
        analysis_status = "pending" if item.status == "pending" else "failed" if item.status == "enrichment_failed" else "ready" if analysis else "unavailable"
        order = {claim: index for index, claim in enumerate(item.features.get("suggestion_order", []))}
        suggestions = sorted(db.scalars(select(Suggestion).where(Suggestion.item_id == item.id, Suggestion.user_id == item.user_id)), key=lambda s: (order.get(s.claim, 99), s.id))
        return {**row_dict(item), "analysis": analysis, "analysis_status": analysis_status, "has_image": item.has_image, "image_path": f"/v1/saves/{item.id}/image" if item.has_image else None,
            "suggestions": [{**row_dict(s), "status": "proposed", "intent": s.claim if s.kind == "intent" else None, "requires_confirmation": True} for s in suggestions], "responses": [row_dict(e) for e in db.scalars(select(UserEvent).where(UserEvent.item_id == item.id, UserEvent.user_id == item.user_id))]}

    register_multimodal(app, multimodal, user=user, database=database, mutate=mutate,
                        state_for=state_for, APIError=APIError)

    def invalidate_predictions(db, user_id, evidence_ids):
        # Recorded provenance lets removal/rejection also retract predictions
        # that have already been published on other saves.
        if not evidence_ids:
            return
        for item in db.scalars(select(SavedItem).where(SavedItem.user_id == user_id, SavedItem.deleted.is_(False))):
            if not evidence_ids.intersection(item.features.get("context_evidence_ids", [])):
                continue
            item.revision += 1
            item.features = {}
            item.status = "pending"
            library_service.update_search_document(db, item)
            db.execute(delete(Suggestion).where(Suggestion.item_id == item.id, Suggestion.user_id == user_id))
            if item.canonical_url.startswith("multimodal:"):
                if not multimodal.enabled:
                    item.status = "enrichment_failed"
                    continue
                try:
                    reserve_analysis(db, user_id, APIError)
                except APIError:
                    # Revoked observations stay withdrawn, while the explicit
                    # edit/deletion succeeds even if reanalysis is rate limited.
                    item.status = "enrichment_failed"
                    continue
            enqueue(db, user_id, "enrich", {"item_id": item.id, "revision": item.revision})

    def queue_analysis(db, item, preserve_suggestions=False):
        pending = db.scalars(select(Job).where(Job.user_id == item.user_id, Job.kind == "enrich", Job.status.in_(["pending", "running"]))).all()
        existing = next((job for job in pending if job.payload.get("item_id") == item.id and job.payload.get("revision") == item.revision), None)
        if item.status == "pending" and existing:
            return {"id": item.id, "status": item.status, "revision": item.revision, "job_id": existing.id, "queued": False}
        if item.canonical_url.startswith("multimodal:"):
            if not multimodal.enabled:
                raise APIError(503, "multimodal_disabled", "Multimodal analysis is not enabled. The saved content is still available.", retryable=False)
            reserve_analysis(db, item.user_id, APIError)
        item.revision += 1
        item.features = {}
        item.status = "pending"
        if not preserve_suggestions:
            db.execute(delete(Suggestion).where(Suggestion.item_id == item.id, Suggestion.user_id == item.user_id))
        library_service.update_search_document(db, item)
        job_id = enqueue(db, item.user_id, "enrich", {"item_id": item.id, "revision": item.revision})
        return {"id": item.id, "status": item.status, "revision": item.revision, "job_id": job_id, "queued": True}

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
        return {"status": "ok", "demo_mode": demo_mode, "inference_provider": provider.version}

    @app.get("/v1/me", response_model=schema.Identity, tags=["System"])
    def me(user_id=Depends(user)):
        return {"user_id": user_id, "demo_mode": demo_mode, "inference_provider": provider.version}

    @app.get("/v1/capabilities", response_model=schema.Capabilities, tags=["System"])
    def capabilities(user_id=Depends(user)):
        return {"api_version": "v1", "contract_version": "0.4.0", "authentication": "development_bearer",
            "capture": {"clients": ["web", "chrome_extension", "ios_app", "ios_share_extension"], "content_types": ["url", "selected_text", "note", "image"], "max_url_length": 2048, "max_title_length": 300, "max_selected_text_length": 12000, "max_note_length": 2000, "max_image_bytes": 4194304},
            "data_modes": {"annotations": getattr(provider, "data_mode", "demo_rules"), "catalog": "fixture", "tracking": "simulated"},
            "features": {"annotations": True, "predictive_prompts": hasattr(provider, "understand_capture"), "product_analysis": getattr(provider, "supports_product_analysis", False), "library_search": True, "explore": True, "discovery": True, "watches": True, "price_simulation": demo_mode, "demo_reset": demo_mode, "image_upload": True, "live_price_monitoring": False, "push_notifications": False, "merchant_handoff": False, "personal_agent_connector": False, "reminder_scheduling": False},
            "currencies": ["SGD"], "refresh": {"strategy": "poll_on_foreground", "pending_save_interval_ms": 1500, "pending_save_timeout_ms": 30000, "incremental_sync": False}}

    @app.get("/v1/commerce/sources", response_model=catalog_schema.CatalogSources, tags=["Catalog integration"])
    def commerce_sources(user_id=Depends(user), db=Depends(database)):
        result = catalog_service.source_status(db)
        result["items"].append(rakuten.status())
        return result

    @app.get("/v1/commerce/search", response_model=catalog_schema.CatalogSearchPage, tags=["Catalog integration"])
    def commerce_search(source: catalog_schema.SourceID, q: str = Query(min_length=1, max_length=100),
                        limit: int = Query(default=20, ge=1, le=50), offset: int = Query(default=0, ge=0, lt=1000000),
                        delivery_country: str | None = Query(default=None, pattern=r"^[A-Z]{2}$"), user_id=Depends(user)):
        """Explicit source selection; local datasets, approved feeds, or configured live APIs.

        Rakuten uses 1–30 items per page and offsets divisible by the limit,
        within its first 100 pages. Its Japan-market results are not included
        in local Explore or dataset exports.
        """
        if not q.strip() or any(ord(c) < 32 for c in q):
            raise APIError(422, "invalid_search", "Enter a search query without control characters")
        if source == "rakuten":
            return rakuten.search(q, limit=limit, offset=offset, delivery_country=delivery_country)
        if delivery_country is not None:
            raise APIError(422, "delivery_unknown", "Catalog data does not establish delivery eligibility; confirm with the merchant")
        with factory() as db:
            return catalog_service.search_feed(db, source, q, limit, offset)

    @app.get("/v1/commerce/items/{source}/{record_id}", response_model=catalog_schema.CatalogRecord, tags=["Catalog integration"])
    def commerce_item(source: catalog_schema.SourceID, record_id: str, user_id=Depends(user)):
        if source == "rakuten":
            return rakuten.get_item(record_id)
        with factory() as db:
            return catalog_service.get_record(db, source, record_id)

    @app.get("/v1/commerce/datasets/{source}/export", tags=["Catalog integration"], response_class=StreamingResponse,
             responses={200: {"description": "Source-isolated JSON Lines with license attribution", "content": {"application/x-ndjson": {"schema": {"type": "string"}}}}})
    def commerce_dataset_export(source: catalog_schema.SourceID, user_id=Depends(user)):
        if source not in DATASET_SOURCES:
            raise APIError(422, "source_not_exportable", "Only registered local datasets support a licensed export")
        with factory() as db:
            status = next(item for item in catalog_service.source_status(db)["items"] if item["source_id"] == source)
        if not status["configured"]:
            raise APIError(503, "catalog_not_configured", "Import this dataset before exporting it", retryable=False)
        headers = {"Content-Disposition": f'attachment; filename="mymah-{source}.jsonl"', "Cache-Control": "no-store"}
        if status["license_url"]:
            headers["Link"] = f'<{status["license_url"]}>; rel="license"'
        return StreamingResponse(catalog_service.export_dataset(factory, source), media_type="application/x-ndjson", headers=headers)

    @app.post("/v1/saves", status_code=201, response_model=schema.CaptureResult, tags=["Capture"])
    def capture(body: Capture, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        def operation():
            canonical = canonical_url(body.url) if body.url else "image:" + hashlib.sha256(body.image_data_url.encode()).hexdigest()
            item = db.scalar(select(SavedItem).where(SavedItem.user_id == user_id, SavedItem.canonical_url == canonical))
            if item and not item.deleted:
                return {"id": item.id, "status": item.status, "duplicate": True}
            if item:
                item.deleted = False
                item.revision += 1
                item.status = "pending"
                item.title, item.selected_text, item.note = body.title, body.selected_text, body.note
                item.original_url, item.source, item.captured_at = body.url or "", body.source, time.time()
                item.client = body.client
                item.image_data_url = body.image_data_url
                item.features = {}
                db.execute(delete(Suggestion).where(Suggestion.item_id == item.id))
            else:
                item = SavedItem(user_id=user_id, original_url=body.url or "", canonical_url=canonical, title=body.title, source=body.source, client=body.client, selected_text=body.selected_text, note=body.note, image_data_url=body.image_data_url)
                db.add(item)
                db.flush()
            normalized = " ".join(body.selected_text.casefold().split())
            item.content_hash = hashlib.sha256(normalized.encode()).hexdigest() if normalized else ""
            enqueue(db, user_id, "enrich", {"item_id": item.id, "revision": item.revision})
            if body.note.strip():
                event = UserEvent(user_id=user_id, item_id=item.id, event_type="capture_note", payload={"text": body.note})
                db.add(event)
                db.flush()
                for claim in claims_in(body.note):
                    db.add(Evidence(user_id=user_id, item_id=item.id, event_id=event.id, claim=claim, text=body.note, origin="explicit_statement"))
            state_for(db, user_id).version += 1
            library_service.update_search_document(db, item)
            return {"id": item.id, "status": item.status, "duplicate": False}
        return mutate(db, user_id, key, "capture", body.model_dump(exclude_none=True), operation)

    @app.get("/v1/collection", response_model=schema.CollectionPage, tags=["Capture"])
    def collection(offset: int = 0, limit: int = 30, user_id=Depends(user), db=Depends(database)):
        if offset < 0 or not 1 <= limit <= 100:
            raise APIError(422, "invalid_pagination", "Offset must be nonnegative and limit between 1 and 100")
        rows = db.scalars(select(SavedItem).where(SavedItem.user_id == user_id, SavedItem.deleted.is_(False)).order_by(SavedItem.captured_at.desc(), SavedItem.id).offset(offset).limit(limit + 1)).all()
        return {"items": [item_view(db, item) for item in rows[:limit]], "next_offset": offset + limit if len(rows) > limit else None}

    @app.get("/v1/library/search", response_model=schema.LibrarySearchPage, tags=["Library"])
    def library_search(q: str = Query(default="", max_length=200), category: str | None = Query(default=None, min_length=1, max_length=80),
                       limit: int = Query(default=20, ge=1, le=100), offset: int = Query(default=0, ge=0, le=100000), user_id=Depends(user), db=Depends(database)):
        if any(ord(char) < 32 for char in q + (category or "")):
            raise APIError(422, "invalid_search", "Search text cannot contain control characters")
        rows, total, next_offset = library_service.search_library(db, user_id, q, category, limit, offset)
        return {"items": [item_view(db, item) for item in rows], "total": total, "next_offset": next_offset, "query": q, "category": category}

    @app.get("/v1/explore", response_model=ExplorePage, tags=["Explore"])
    def explore(source: catalog_schema.SourceID | None = None, q: str = Query(default="", max_length=100),
                limit: int = Query(default=20, ge=1, le=50), offset: int = Query(default=0, ge=0, lt=500), user_id=Depends(user), db=Depends(database)):
        if any(ord(char) < 32 for char in q):
            raise APIError(422, "invalid_search", "Search text cannot contain control characters")
        return explore_products(db, user_id, source or os.getenv("EXPLORE_CATALOG_SOURCE", "abo"), q, limit, offset)

    @app.get("/v1/saves/{item_id}", response_model=schema.SavedItemView, tags=["Capture"])
    def get_save(item_id: str, user_id=Depends(user), db=Depends(database)):
        return item_view(db, owned(db, SavedItem, item_id, user_id))

    @app.post("/v1/saves/{item_id}/analyze", status_code=202, response_model=schema.AnalysisQueued, tags=["Capture"])
    def analyze_save(item_id: str, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        def operation():
            result = queue_analysis(db, owned(db, SavedItem, item_id, user_id))
            if result["queued"]:
                state_for(db, user_id).version += 1
            return result
        return mutate(db, user_id, key, f"analyze:{item_id}", {}, operation)

    @app.get("/v1/saves/{item_id}/image", tags=["Capture"], response_class=Response,
             responses={200: {"description": "Private normalized saved image. Authenticate as the save owner.", "content": {"image/jpeg": {"schema": {"type": "string", "format": "binary"}}, "image/png": {"schema": {"type": "string", "format": "binary"}}}}})
    def get_save_image(item_id: str, user_id=Depends(user), db=Depends(database)):
        item = owned(db, SavedItem, item_id, user_id)
        if not item.image_data_url:
            raise APIError(404, "image_not_found", "This save has no image")
        header, encoded = item.image_data_url.split(",", 1)
        return Response(base64.b64decode(encoded), media_type=header[5:].split(";", 1)[0], headers={"Cache-Control": "no-store"})

    @app.post("/v1/saves/{item_id}/responses", response_model=schema.AnnotationResult, tags=["Capture"])
    def respond(item_id: str, body: AnnotationResponse, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        def operation():
            item = owned(db, SavedItem, item_id, user_id)
            revoked = set()
            suggestion = owned(db, Suggestion, body.suggestion_id, user_id) if body.suggestion_id else None
            if suggestion and suggestion.item_id != item_id:
                raise APIError(422, "wrong_suggestion", "Suggestion belongs to a different save")
            if body.action == "select" and not suggestion:
                raise APIError(422, "suggestion_required", "Select a suggestion or use edit for your own text")
            if body.action == "edit" and not body.text.strip():
                raise APIError(422, "text_required", "An edit needs your own explanation")
            # Responses supersede earlier evidence for this proposal, retaining history.
            if suggestion:
                prior = db.scalars(select(UserEvent).where(UserEvent.user_id == user_id, UserEvent.item_id == item_id)).all()
                prior_ids = [e.id for e in prior if e.payload.get("suggestion_id") == suggestion.id]
                matching = Evidence.event_id.in_(prior_ids)
                if suggestion.kind == "intent":
                    matching = or_(matching, and_(Evidence.claim == suggestion.claim, Evidence.origin == "confirmed_annotation"))
                revoked = set(db.scalars(select(Evidence.id).where(Evidence.user_id == user_id, Evidence.item_id == item_id, matching, Evidence.active.is_(True))))
                if revoked:
                    db.execute(update(Evidence).where(Evidence.id.in_(revoked), Evidence.user_id == user_id).values(active=False))
                    invalidate_predictions(db, user_id, revoked)
            event_payload = body.model_dump()
            if suggestion:
                event_payload.update({"suggestion_text": suggestion.text, "claim": suggestion.claim, "kind": suggestion.kind})
            event = UserEvent(user_id=user_id, item_id=item_id, event_type="annotation_response", payload=event_payload)
            db.add(event)
            db.flush()
            if body.action in {"select", "edit"}:
                text = suggestion.text if body.action == "select" else body.text
                claims = [suggestion.claim] if body.action == "select" else claims_in(text)
                for claim in claims:
                    db.add(Evidence(user_id=user_id, item_id=item_id, event_id=event.id, claim=claim, text=text, origin="confirmed_annotation" if body.action == "select" else "explicit_statement"))
            state_for(db, user_id).version += 1
            db.flush()
            refinement = None
            media_save = item.canonical_url.startswith("multimodal:")
            if (media_save or getattr(provider, "supports_product_analysis", False)) and (body.action in {"select", "edit"} or revoked):
                try:
                    refinement = queue_analysis(db, item, preserve_suggestions=True)
                except APIError as error:
                    if not media_save or error.code not in {"multimodal_disabled", "multimodal_rate_limited"}:
                        raise
                    # Record the person's choice even while AI is unavailable;
                    # do not display analysis based on superseded preferences.
                    item.revision += 1
                    item.features, item.status = {}, "enrichment_failed"
            library_service.update_search_document(db, item)
            return {"event_id": event.id, "hypothesis": context(db, user_id),
                "intent": suggestion.claim if body.action == "select" and suggestion.kind == "intent" else None,
                "execution_status": "annotation_only", "analysis_job_id": refinement["job_id"] if refinement else None, "saved_revision": item.revision}
        return mutate(db, user_id, key, f"respond:{item_id}", body.model_dump(), operation)

    @app.delete("/v1/saves/{item_id}", response_model=schema.Deleted, tags=["Capture"])
    def remove_save(item_id: str, user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        def operation():
            item = owned(db, SavedItem, item_id, user_id)
            item.deleted = True
            erase_for_saved_item(db, user_id, item_id)
            item.revision += 1
            # Erase captured text while keeping a dedupe tombstone and event provenance.
            item.title, item.note, item.selected_text, item.features = "Deleted save", "", "", {}
            item.image_data_url = None
            item.search_text = item.category_text = ""
            revoked = set(db.scalars(select(Evidence.id).where(Evidence.item_id == item_id, Evidence.user_id == user_id, Evidence.active.is_(True))))
            db.execute(update(Evidence).where(Evidence.item_id == item_id, Evidence.user_id == user_id).values(active=False, text="[removed]"))
            db.execute(update(UserEvent).where(UserEvent.item_id == item_id, UserEvent.user_id == user_id).values(payload={"removed": True}))
            db.execute(delete(Suggestion).where(Suggestion.item_id == item_id, Suggestion.user_id == user_id))
            invalidate_predictions(db, user_id, revoked)
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
        return {"hypothesis": context(db, user_id), "jobs": [{"id": j.id, "kind": j.kind, "status": j.status, "attempts": j.attempts, "error": j.error} for j in db.scalars(select(Job).where(Job.user_id == user_id).order_by(Job.due_at.desc()).limit(30))], "provider": provider.version, "catalog_mode": "fixture", "tracking_mode": "simulated"}

    @app.post("/v1/demo/reset", response_model=schema.Reset, tags=["Demo"])
    def reset(user_id=Depends(user), db=Depends(database), key: str = Header(default="", alias="Idempotency-Key")):
        if not demo_mode:
            raise APIError(404, "not_found", "Demo reset is disabled")
        def operation():
            for model in [Notification, Observation, Watch, DiscoverySession, Evidence, Suggestion, UserEvent, Job, MultimodalAsset, MultimodalCapture, SavedItem, Mutation]:
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
