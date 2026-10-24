"""Run the local API and web app, loading only known settings from the ignored .env."""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = {"DATABASE_URL", "API_TOKENS", "DEMO_MODE", "EMBEDDED_WORKER", "CORS_ORIGINS",
            "ANNOTATION_PROVIDER", "OPENAI_API_KEY", "OPENAI_MODEL", "ASTRA_API_KEY", "ASTRA_MODEL",
            "ASTRA_SERVICE_TIER", "EXPLORE_CATALOG_SOURCE", "CJ_PERSONAL_ACCESS_TOKEN", "CJ_COMPANY_ID"}


def main():
    os.chdir(ROOT)
    if (ROOT / ".env").exists():
        for line in (ROOT / ".env").read_text().splitlines():
            name, separator, value = line.partition("=")
            if separator and name.strip() in SETTINGS:
                os.environ.setdefault(name.strip(), value.strip())
    if os.getenv("ANNOTATION_PROVIDER") == "openai" and not os.getenv("OPENAI_API_KEY"):
        sys.exit("Set OPENAI_API_KEY in .env, or use ANNOTATION_PROVIDER=demo for basic mode.")
    subprocess.run([str(ROOT / ".venv/bin/alembic"), "upgrade", "head"], check=True)
    import uvicorn
    uvicorn.run("backend.app.main:app", host="127.0.0.1", port=8000, app_dir=str(ROOT))


if __name__ == "__main__":
    main()
