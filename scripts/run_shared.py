"""Start the shared web/API service with durable storage and explicit credentials.

Managed email login and existing account access keys share one backend identity.
Secrets come from hosting environment variables; this never reads local .env files.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from backend.app.db import database_url


def configure(environment):
    configured_url = environment.get("DATABASE_URL", "")
    if not configured_url:
        raise ValueError("The shared service requires a PostgreSQL DATABASE_URL.")
    url = database_url(configured_url)
    if not url.startswith("postgresql+psycopg://"):
        raise ValueError("The shared service requires a PostgreSQL DATABASE_URL.")
    raw = environment.get("API_TOKENS", "")
    try:
        tokens = json.loads(raw) if raw else ({
            environment.get("MYNAH_ACCOUNT_TOKEN", ""): environment.get("MYNAH_ACCOUNT_ID", "chime")
        } if environment.get("MYNAH_ACCOUNT_TOKEN") else {})
    except (ValueError, TypeError):
        raise ValueError("API_TOKENS must be an account-token mapping.") from None
    if not isinstance(tokens, dict) or (not tokens and not environment.get("NEON_AUTH_URL")) or any(
        not isinstance(token, str) or len(token) < 32 or token.strip() != token
        or not isinstance(account, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", account)
        for token, account in tokens.items()
    ):
        raise ValueError("Configure random account access keys of at least 32 characters and valid account IDs.")
    environment.update(DATABASE_URL=url, API_TOKENS=json.dumps(tokens), DEMO_MODE="false")
    environment.setdefault("MULTIMODAL_ENABLED", "true")


def main():
    try:
        configure(os.environ)
        port = int(os.environ.get("PORT", "10000"))
        if not 1 <= port <= 65535:
            raise ValueError("PORT must be between 1 and 65535.")
    except ValueError as error:
        raise SystemExit(str(error)) from None
    os.chdir(ROOT)
    subprocess.run([sys.executable, "-m", "alembic", "upgrade", "head"], check=True)
    import uvicorn
    uvicorn.run("backend.app.combined:create_app", factory=True, host="0.0.0.0", port=port, access_log=False)


if __name__ == "__main__":
    main()
