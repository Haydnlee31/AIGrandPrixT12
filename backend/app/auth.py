"""Verify managed Neon login tokens; never trust client-supplied user IDs."""
import json
import os
import uuid
from urllib.parse import urlsplit

import jwt
from jwt import PyJWKClient


class LoginUnavailable(Exception):
    pass


class InvalidLogin(Exception):
    pass


class NeonAuth:
    def __init__(self, base_url=None, jwks=None):
        self.base_url = (base_url if base_url is not None else os.getenv("NEON_AUTH_URL", "")).rstrip("/")
        self.enabled = bool(self.base_url)
        self.account_links = json.loads(os.getenv("NEON_ACCOUNT_LINKS", "{}"))
        if not isinstance(self.account_links, dict) or not all(isinstance(k, str) and isinstance(v, str) and v and not v.startswith("neon:") for k, v in self.account_links.items()) or len(set(self.account_links.values())) != len(self.account_links):
            raise RuntimeError("NEON_ACCOUNT_LINKS must map verified Neon user IDs to distinct existing library IDs")
        try:
            if any(str(uuid.UUID(key)) != key for key in self.account_links):
                raise ValueError()
        except ValueError as error:
            raise RuntimeError("NEON_ACCOUNT_LINKS keys must be exact verified Neon user UUIDs") from error
        if not self.enabled:
            return
        url = urlsplit(self.base_url)
        if url.scheme != "https" or not url.hostname or url.query or url.fragment or url.username or url.password or not url.path.endswith("/auth"):
            raise RuntimeError("NEON_AUTH_URL must be the exact HTTPS Auth URL from Neon")
        self.origin = f"https://{url.netloc}"
        self.jwks = jwks or PyJWKClient(self.base_url + "/.well-known/jwks.json", timeout=5, lifespan=300)

    def subject(self, token):
        if not self.enabled or not isinstance(token, str) or len(token) > 16384:
            raise InvalidLogin()
        try:
            key = self.jwks.get_signing_key_from_jwt(token).key
            # Neon session JWTs use the branch Auth origin for both iss and aud.
            # Do not accept another branch's JWT just because the key is shared.
            claims = jwt.decode(token, key, algorithms=["EdDSA"], issuer=self.origin,
                                audience=self.origin, options={"require": ["exp", "iat", "sub", "iss", "aud"]}, leeway=5)
            subject = str(uuid.UUID(claims["sub"]))
            if subject != claims["sub"] or claims.get("banned") or claims.get("emailVerified") is not True:
                raise InvalidLogin()
            return subject
        except jwt.PyJWKClientConnectionError as error:
            raise LoginUnavailable() from error
        except (jwt.PyJWTError, ValueError, TypeError, KeyError, AttributeError) as error:
            raise InvalidLogin() from error

    def public_config(self):
        return {"enabled": self.enabled, "provider": "neon" if self.enabled else None,
                "auth_url": self.base_url if self.enabled else None}
