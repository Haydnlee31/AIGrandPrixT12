"""One authenticated origin for native intelligence, Chrome and shared Library."""
from contextlib import AsyncExitStack, asynccontextmanager
import asyncio
import hashlib
import json
import os
from pathlib import Path
import secrets

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

RELAY_PATHS = frozenset({
    "/v1/capture-preview", "/v1/refine-intent", "/v1/recommendations",
    "/v1/catalog/status", "/v1/dictation", "/v1/radar", "/v1/price-check",
    "/v1/price-watch", "/v1/discover", "/v1/taste-lab", "/v1/taste-interpret",
})


def create_app(*, tokens=None, api_key=None, model=None, price_directory=None,
               main_options=None, relay_options=None):
    from .main import APIError, create_app as create_main
    from .capture_preview import create_app as create_relay

    tokens = tokens if tokens is not None else json.loads(os.getenv("API_TOKENS", '{"demo-alex":"alex","demo-sam":"sam"}'))
    main = create_main(tokens=tokens, **(main_options or {}))
    key = api_key if api_key is not None else os.getenv("ASTRA_API_KEY") or os.getenv("OPENAI_API_KEY", "")
    selected_model = model or os.getenv("ASTRA_MODEL", "gpt-6-astra")
    store = Path(price_directory or ("/tmp/mymah-price-watches" if os.getenv("VERCEL")
        else os.getenv("MYMAH_PRICE_DIRECTORY", "local-data/price-watches")))
    relays = {}
    relay_lifespans = AsyncExitStack()
    relay_lock = asyncio.Lock()

    def make_relay(user_id):
        internal_token = secrets.token_urlsafe(32)
        account_path = store / (hashlib.sha256(user_id.encode()).hexdigest() + ".json")
        relay = create_relay(api_key=key, token=internal_token, model=selected_model,
            recommendation_factory=main.state.factory, price_store=account_path,
            **({"price_background": not bool(os.getenv("VERCEL"))} | (relay_options or {})))
        return relay, internal_token

    for user_id in set(tokens.values()):
        relays[user_id] = make_relay(user_id)

    @asynccontextmanager
    async def lifespan(app):
        async with AsyncExitStack() as stack, relay_lifespans:
            await stack.enter_async_context(main.router.lifespan_context(main))
            for relay, _ in relays.values():
                await relay_lifespans.enter_async_context(relay.router.lifespan_context(relay))
            yield

    app = FastAPI(title="Mymah Finds", lifespan=lifespan, docs_url=None,
                  redoc_url=None, openapi_url=None)
    app.state.main = main
    app.state.relays = {user: relay for user, (relay, _) in relays.items()}
    origins = (main_options or {}).get("allowed_origins")
    if origins is None:
        origins = json.loads(os.getenv("CORS_ORIGINS", "[]"))

    @app.get("/health")
    async def health():
        return JSONResponse({"status": "ok", "ready": bool(key),
                             "multimodal": main.state.multimodal.enabled},
                            headers={"Cache-Control": "no-store"})

    async def relay_dispatch(scope, receive, send):
        credentials = [value for name, value in scope.get("headers", []) if name.lower() == b"authorization"]
        user_id = None
        if len(credentials) == 1:
            supplied = credentials[0]
            try:
                if supplied.startswith(b"Bearer "):
                    user_id = await run_in_threadpool(main.state.resolve_bearer, supplied[7:].decode())
            except (UnicodeError, APIError) as error:
                if isinstance(error, APIError) and error.status == 503:
                    return await JSONResponse({"error": {"code": "login_unavailable", "message": "Sign-in is temporarily unavailable.", "retryable": True}}, status_code=503)(scope, receive, send)
        if user_id is None:
            return await JSONResponse({"error": {"code": "unauthorized",
                "message": "Reconnect your account to continue.", "retryable": False}},
                status_code=401, headers={"Cache-Control": "no-store"})(scope, receive, send)
        if os.getenv("VERCEL") and scope["path"].rstrip("/") == "/v1/price-watch":
            return await JSONResponse({"error": {"code": "tracking_unavailable", "message": "Price monitoring is unavailable on this service.", "retryable": False}}, status_code=503)(scope, receive, send)
        async with relay_lock:
            if user_id not in relays:
                if len(relays) >= 128:
                    return await JSONResponse({"error": {"code": "service_busy", "message": "Try again shortly.", "retryable": True}}, status_code=503)(scope, receive, send)
                relay, internal_token = make_relay(user_id)
                await relay_lifespans.enter_async_context(relay.router.lifespan_context(relay))
                relays[user_id] = (relay, internal_token)
                app.state.relays[user_id] = relay
        relay, internal_token = relays[user_id]
        headers = [(name, value) for name, value in scope.get("headers", []) if name.lower() != b"authorization"]
        headers.append((b"authorization", ("Bearer " + internal_token).encode()))
        await relay(dict(scope, headers=headers), receive, send)

    relay_cors = CORSMiddleware(relay_dispatch, allow_origins=origins,
        allow_methods=["GET", "POST", "OPTIONS"],
        allow_headers=["Authorization", "Content-Type", "Idempotency-Key"],
        expose_headers=["X-Request-ID"], allow_credentials=False)

    async def dispatch(scope, receive, send):
        if scope["type"] == "http" and scope["path"].rstrip("/") in RELAY_PATHS:
            return await relay_cors(scope, receive, send)
        # Main owns its login-cookie CORS policy; don't intercept its preflights.
        return await main(scope, receive, send)

    app.mount("/", dispatch)
    return app
