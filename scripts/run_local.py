"""Start the combined app with explicit backend-only configuration."""
import argparse
import json
import os
from pathlib import Path
import shlex
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
SETTINGS = frozenset({"DATABASE_URL", "API_TOKENS", "DEMO_MODE", "EMBEDDED_WORKER", "CORS_ORIGINS",
    "ANNOTATION_PROVIDER", "ASTRA_API_KEY", "OPENAI_API_KEY", "ASTRA_MODEL", "ASTRA_SERVICE_TIER",
    "MULTIMODAL_ENABLED", "MULTIMODAL_TRANSCRIPTION_MODEL", "EXPLORE_CATALOG_SOURCE",
    "RAKUTEN_APPLICATION_ID", "RAKUTEN_ACCESS_KEY", "RAKUTEN_AFFILIATE_ID", "MYMAH_PRICE_DIRECTORY",
    "NEON_AUTH_URL", "NEON_ACCOUNT_LINKS", "AUTH_WEB_ORIGIN", "CAPTURE_IMAGE_BYTES", "CRON_SECRET"})


def configure(path, environ=None):
    """Parse only known inert values; never execute shell expansions or print secrets."""
    target = os.environ if environ is None else environ
    try:
        if Path(path).exists():
            with Path(path).open("rb") as stream:
                raw = stream.read(65537)
            if len(raw) > 65536:
                raise ValueError()
            for line in raw.decode().splitlines():
                line = line.strip().removeprefix("export ")
                name, sep, value = line.partition("=")
                name, value = name.strip(), value.strip()
                if not sep or name not in SETTINGS:
                    continue
                if value.startswith(("{", "[")):
                    json.loads(value)
                else:
                    fields = shlex.split(value, comments=True)
                    if len(fields) > 1:
                        raise ValueError()
                    value = fields[0] if fields else ""
                if any(ord(c) < 32 or ord(c) == 127 for c in value):
                    raise ValueError()
                if not target.get(name):
                    target[name] = value
    except (OSError, UnicodeError, ValueError):
        raise ValueError("Backend configuration could not be read. Check the environment file format.") from None
    target.setdefault("MULTIMODAL_ENABLED", "true")
    target.setdefault("EMBEDDED_WORKER", "true")
    target.setdefault("ANNOTATION_PROVIDER", "auto")
    for flag in ("MULTIMODAL_ENABLED", "EMBEDDED_WORKER"):
        value = target[flag].strip().lower()
        if value not in {"true", "false"}:
            raise ValueError(f"Set {flag} to true or false.")
        target[flag] = value
    if target["MULTIMODAL_ENABLED"].lower() == "true" and not (target.get("ASTRA_API_KEY") or target.get("OPENAI_API_KEY")):
        raise ValueError("Configure ASTRA_API_KEY or OPENAI_API_KEY on the backend before starting multimodal analysis.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", default=str(ROOT / ".env"))
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    try:
        configure(args.env_file)
    except ValueError as error:
        raise SystemExit(str(error)) from None
    os.chdir(ROOT)
    from alembic.config import Config
    from alembic import command
    command.upgrade(Config(str(ROOT / "alembic.ini")), "head")
    import uvicorn
    uvicorn.run("backend.app.combined:create_app", factory=True,
                host=args.host, port=args.port, access_log=False)


if __name__ == "__main__":
    main()
