#!/bin/sh
# Compile the native SDK and test it against a temporary, migrated loopback API.
# Requires Xcode and the repository's .venv (or COMMONTHREAD_PYTHON override).
set -eu
ios_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_root=$(CDPATH= cd -- "$ios_root/../.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mymah-native-http.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
python_bin=${COMMONTHREAD_PYTHON:-"$repo_root/.venv/bin/python"}
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/modules" \
  "$ios_root"/Sources/CommonThreadKit/*.swift "$ios_root/Scripts/native_http_smoke.swift" \
  -o "$scratch/native-smoke"
"$python_bin" - "$repo_root" "$scratch" <<'PY'
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import urlopen

root, scratch = map(Path, sys.argv[1:])
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
origin = f"http://127.0.0.1:{port}"
env = dict(os.environ,
           DATABASE_URL=f"sqlite:///{scratch}/isolated.db",
           API_TOKENS=json.dumps({"demo-alex": "alex", "demo-sam": "sam"}),
           DEMO_MODE="true", EMBEDDED_WORKER="true", CORS_ORIGINS="[]")
env["ANNOTATION_PROVIDER"] = "fallback"
env.pop("ASTRA_API_KEY", None)
env.pop("OPENAI_API_KEY", None)
subprocess.run([sys.executable, "-m", "alembic", "upgrade", "head"],
               cwd=root, env=env, check=True, timeout=30)
with (scratch / "server.log").open("w+") as log:
    server = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "backend.app.main:app", "--host", "127.0.0.1", "--port", str(port)],
        cwd=root, env=env, stdout=log, stderr=log)
    try:
        for _ in range(100):
            if server.poll() is not None:
                raise RuntimeError("Isolated API exited before readiness")
            try:
                with urlopen(origin + "/health", timeout=1) as response:
                    if response.status == 200:
                        break
            except URLError:
                time.sleep(0.1)
        else:
            raise RuntimeError("Isolated API did not become ready")
        subprocess.run([str(scratch / "native-smoke"), origin, str(scratch / "outbox")],
                       cwd=root, env=env, check=True, timeout=60)
    except Exception:
        log.flush()
        log.seek(0)
        print(log.read(), file=sys.stderr)
        raise
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
PY
