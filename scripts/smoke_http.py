"""Run an actual HTTP/JavaScript/backend journey against an isolated temporary database."""
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen
from urllib.error import URLError

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="common-thread-http-") as directory:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        env = dict(os.environ, DATABASE_URL=f"sqlite:///{directory}/smoke.db", API_TOKENS='{"http-smoke-token":"http-smoke-user"}', EMBEDDED_WORKER="true", DEMO_MODE="true", CORS_ORIGINS="[]", SMOKE_API_URL=f"http://127.0.0.1:{port}", SMOKE_API_TOKEN="http-smoke-token")
        subprocess.run([sys.executable, "-m", "alembic", "upgrade", "head"], cwd=ROOT, env=env, check=True)
        with open(Path(directory) / "server.log", "w+") as log:
            server = subprocess.Popen([sys.executable, "-m", "uvicorn", "backend.app.main:app", "--host", "127.0.0.1", "--port", str(port)], cwd=ROOT, env=env, stdout=log, stderr=log)
            try:
                for _ in range(100):
                    if server.poll() is not None:
                        raise RuntimeError("Isolated API exited before readiness")
                    try:
                        with urlopen(env["SMOKE_API_URL"] + "/health", timeout=1) as response:
                            if response.status == 200:
                                break
                    except URLError:
                        time.sleep(0.1)
                else:
                    raise RuntimeError("Isolated API did not become ready")
                subprocess.run(["node", "scripts/smoke_http.mjs"], cwd=ROOT, env=env, check=True, timeout=60)
            except Exception:
                log.flush(); log.seek(0)
                print(log.read(), file=sys.stderr)
                raise
            finally:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill(); server.wait()


if __name__ == "__main__":
    main()
