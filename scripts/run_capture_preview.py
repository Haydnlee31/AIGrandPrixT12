"""Run the private capture-intelligence relay without printing credentials."""
from pathlib import Path
import os

ROOT = Path(__file__).resolve().parents[1]
NAMES = {"OPENAI_API_KEY", "MYNAH_PREVIEW_TOKEN", "MYNAH_PREVIEW_MODEL"}

if __name__ == "__main__":
    path = ROOT / ".env.local"
    if path.is_file():
        for line in path.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                name, value = line.split("=", 1)
                if name.strip() in NAMES:
                    os.environ.setdefault(name.strip(), value.strip().strip("\"'"))
    if not all(os.environ.get(name) for name in ("OPENAI_API_KEY", "MYNAH_PREVIEW_TOKEN")):
        raise SystemExit("Configure the provider key and private service token in the environment or ignored .env.local.")
    os.chdir(ROOT)
    import sys
    sys.path.insert(0, str(ROOT))
    import uvicorn
    uvicorn.run("backend.app.capture_preview:app", host="127.0.0.1", port=8787, access_log=False)
