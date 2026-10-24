"""Narrow same-origin transport for Neon's managed email-code sessions.

Neon owns codes, users, sessions, expiry and revocation. This proxy only keeps
its HTTP-only session cookie first-party so Safari/third-party-cookie blocking
does not break login. Library APIs still require a verified Neon JWT.
"""
import json
import os
import re
from http.cookies import SimpleCookie

import httpx
from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.middleware.cors import CORSMiddleware

COOKIE = "__Secure-neon-auth.session_token"
OPERATIONS = {
    ("GET", "get-session"), ("GET", "token"),
    ("POST", "email-otp/send-verification-otp"),
    ("POST", "sign-in/email-otp"), ("POST", "sign-out"),
}


class LoginCORSMiddleware:
    """Credentials are accepted only by the explicit session transport."""
    def __init__(self, app, allow_origins):
        common = dict(allow_origins=allow_origins, allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
                      allow_headers=["Authorization", "Content-Type", "Idempotency-Key"], expose_headers=["X-Request-ID"])
        self.api = CORSMiddleware(app, **common, allow_credentials=False)
        self.login = CORSMiddleware(app, **{**common, "allow_headers":["Content-Type", "X-Mynah-Auth"]}, allow_credentials=True)

    async def __call__(self, scope, receive, send):
        middleware = self.login if scope.get("path", "").startswith("/v1/auth/session/") else self.api
        await middleware(scope, receive, send)


def install_login_routes(app, login, origins):
    web_origin = os.getenv("AUTH_WEB_ORIGIN", "https://mynah-finds.vercel.app").rstrip("/")
    trusted = {web_origin, *origins}

    @app.api_route("/v1/auth/session/{operation:path}", methods=["GET", "POST"], include_in_schema=False)
    async def managed_session(operation: str, request: Request):
        def error(message, status):
            return JSONResponse({"message": message}, status_code=status, headers={"Cache-Control":"no-store"})
        if not login.enabled:
            return error("Email login is not configured yet.", 503)
        if (request.method, operation) not in OPERATIONS:
            return error("Unknown login operation.", 404)
        # Reject browser CSRF, including simple-form POSTs and credentialed GETs.
        # Native clients also send this header; it contains no secret.
        origin = request.headers.get("origin")
        if request.headers.get("x-mynah-auth") != "1" or (origin is not None and origin not in trusted):
            return error("Login request origin is not allowed.", 403)
        if request.query_params and not (operation == "get-session" and all(
            key == "disableCookieCache" and value in {"true", "false"}
            for key, value in request.query_params.multi_items()
        )):
            return error("Invalid login query.", 400)
        body = await request.body()
        if len(body) > 8192:
            return error("Login request is too large.", 413)
        if request.method == "POST":
            if request.headers.get("content-type", "").split(";")[0].strip() != "application/json":
                return error("Login requires JSON.", 415)
            try:
                payload = json.loads(body)
                if not isinstance(payload, dict):
                    raise ValueError()
                if operation == "email-otp/send-verification-otp":
                    if set(payload) != {"email", "type"} or payload["type"] != "sign-in":
                        raise ValueError()
                elif operation == "sign-in/email-otp":
                    if set(payload) != {"email", "otp"}:
                        raise ValueError()
                elif payload:
                    raise ValueError()
            except (ValueError, TypeError):
                return error("Invalid login request.", 400)
        headers = {"Accept": "application/json", "Content-Type": "application/json", "Origin": web_origin}
        # Never forward library keys, unrelated cookies or client-selected hosts.
        if value := request.cookies.get(COOKIE):
            cookie = SimpleCookie(); cookie[COOKIE] = value
            headers["Cookie"] = cookie.output(header="", sep="").strip()
        try:
            async with httpx.AsyncClient(timeout=15, follow_redirects=False) as client:
                upstream = await client.request(request.method, login.base_url + "/" + operation,
                                                headers=headers, content=body, params=request.query_params)
            data = upstream.json()
        except (httpx.HTTPError, ValueError):
            return error("Login is temporarily unavailable. Please try again.", 503)
        if upstream.is_redirect:
            return error("Unexpected login response.", 502)
        # The opaque session belongs only in HttpOnly cookies (Keychain on iOS).
        # The frontend only needs the verified user after sign-in.
        if operation in {"sign-in/email-otp", "get-session"} and upstream.is_success and isinstance(data, dict):
            data = {"user": data.get("user")}
        response = JSONResponse(data, status_code=upstream.status_code, headers={"Cache-Control":"no-store"})
        if retry_after := upstream.headers.get("retry-after"):
            response.headers["Retry-After"] = retry_after
        for raw in upstream.headers.get_list("set-cookie"):
            cookies = SimpleCookie()
            cookies.load(re.sub(r";\s*Partitioned\b", "", raw, flags=re.I))
            if COOKIE not in cookies:
                continue
            cookie = cookies[COOKIE]
            # Host-only, HTTPS-only, inaccessible to page JS. Preserve Neon's TTL.
            cookie["domain"] = ""; cookie["path"] = "/v1/auth/session"
            cookie["secure"] = True; cookie["httponly"] = True; cookie["samesite"] = "Lax"
            response.headers.append("Set-Cookie", cookie.OutputString())
        return response
