"""Run the explicitly single-device analysis API, independently of Library sync.

Uses .env.local inference credentials and .env.multimodal-device for its own
account token and database. Neither token is a shared-library destination.
"""
from pathlib import Path
import os
import sys
import json

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

if __name__ == "__main__":
    from backend.app.server_config import load_server_env
    load_server_env(ROOT / ".env.local")
    config = json.loads((ROOT / ".env.multimodal-device").read_text())
    os.environ["DATABASE_URL"] = config["database_url"]
    os.environ["API_TOKENS"] = json.dumps({config["access_token"]: config["account_id"]})
    os.environ["MULTIMODAL_ENABLED"] = "true"
    os.environ["DEMO_MODE"] = "false"
    os.environ["EMBEDDED_WORKER"] = "true"
    os.environ["ASTRA_MODEL"] = config.get("model", "gpt-6-astra")
    from alembic.config import Config
    from alembic import command
    os.chdir(ROOT)
    command.upgrade(Config(str(ROOT / "alembic.ini")), "head")
    import uvicorn
    uvicorn.run("backend.app.main:app", host="127.0.0.1", port=8788, access_log=False)
