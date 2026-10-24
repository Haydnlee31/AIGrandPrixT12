"""Run the web app and its matching API locally, on a separate development port."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ENV_KEYS = {
    "DATABASE_URL", "API_TOKENS", "DEMO_MODE", "EMBEDDED_WORKER", "CORS_ORIGINS",
    "ANNOTATION_PROVIDER", "OPENAI_API_KEY", "OPENAI_MODEL", "EXPLORE_CATALOG_SOURCE",
    "ASTRA_API_KEY", "ASTRA_MODEL", "ASTRA_BASE_URL",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8001)
    args = parser.parse_args()
    os.chdir(ROOT)
    env_file = ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            key, separator, value = line.strip().partition("=")
            if separator and key in ENV_KEYS:
                os.environ.setdefault(key, value.strip().strip("\"'"))
    subprocess.run([sys.executable, "-m", "alembic", "upgrade", "head"], check=True)
    subprocess.run([sys.executable, "-m", "uvicorn", "backend.app.main:app",
                    "--host", "127.0.0.1", "--port", str(args.port)], check=True)


if __name__ == "__main__":
    main()
