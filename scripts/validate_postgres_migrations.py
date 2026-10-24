"""Validate concurrent deployment upgrades on a disposable local PostgreSQL.

Uses a private Unix socket with no TCP listener and never opens an existing DB.
"""
import argparse
import base64
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from alembic import command
from PIL import Image
from sqlalchemy import create_engine, text
from scripts.migrate_deployment import configuration, run


def validate_multimodal_journey(url):
    """Real PostgreSQL transactions with synthetic provider output, no paid calls."""
    from fastapi.testclient import TestClient
    from backend.app.main import create_app
    from backend.app.intelligence import DemoAnnotationProvider
    from backend.tests.test_multimodal_pipeline import FakeMultimodal, TOKENS, ready, publish, request, tick
    provider = FakeMultimodal()
    app = create_app(url, embedded_worker=False, tokens=TOKENS,
        annotation_provider=DemoAnnotationProvider(), multimodal_provider=provider)
    with TestClient(app, headers={"Authorization": "Bearer test-alex-token"}) as client:
        capture = ready(client, images=2, audio=True, note="A gift for Dad.")
        saved_id = publish(client, capture)["id"]
        saved = client.get(f"/v1/saves/{saved_id}").json()
        assert saved["features"]["multimodal_preview"] == capture["result"]["preview"]
        assert client.get("/v1/library/search", params={"q": "leather Dad"}).json()["total"] == 1
        assert client.get(f"/v1/saves/{saved_id}", headers={"Authorization": "Bearer test-sam-token"}).status_code == 404
        revision = client.get("/v1/sync").json()["revision"]
        assert request(client, "POST", f"/v1/saves/{saved_id}/responses", {"action": "edit", "text": "Please avoid metal straps."}).status_code == 200
        assert tick(client)
        assert client.get("/v1/sync").json()["revision"] > revision
        assert len(provider.recordings) == 1 and len(provider.snapshots) == 2
        assert request(client, "DELETE", f"/v1/saves/{saved_id}").status_code == 200
        assert client.get("/v1/library/search", params={"q": "leather Dad"}).json()["total"] == 0


def validate(binaries):
    old_url = os.environ.get("DATABASE_URL")
    with tempfile.TemporaryDirectory(prefix="mymah-pg-audit-", dir="/tmp") as scratch:
        root = Path(scratch)
        data, log = root / "data", root / "postgres.log"
        subprocess.run([str(binaries / "initdb"), "-D", str(data), "--auth=trust", "--no-locale", "--encoding=UTF8"], check=True, capture_output=True)
        started, engine = False, None
        runners = []
        try:
            subprocess.run([str(binaries / "pg_ctl"), "-D", str(data), "-l", str(log), "-o", f"-k {root} -h '' -p 55489", "-w", "start"], check=True, capture_output=True)
            started = True
            url = "postgresql+psycopg:///postgres?" + urllib.parse.urlencode({"host": str(root), "port": 55489})
            os.environ["DATABASE_URL"] = url
            command.upgrade(configuration(), "c4d905a137ab")
            engine = create_engine(url)
            stream = io.BytesIO()
            Image.new("RGB", (12, 12), "blue").save(stream, "PNG")
            image = "data:image/png;base64," + base64.b64encode(stream.getvalue()).decode()
            with engine.begin() as db:
                db.execute(text("INSERT INTO saved_items (id,user_id,original_url,canonical_url,title,source,selected_text,content_hash,note,captured_at,status,features,revision,deleted,client) VALUES ('kept','owner','https://example.com/watch','https://example.com/watch','Saved watch','web','','','Gift',1,'ready','{}',1,false,'chrome_extension')"))
                db.execute(text("INSERT INTO saved_media(item_id,user_id,image_data) VALUES ('kept','owner',:image)"), {"image": image})
            environment = {**os.environ, "VERCEL_ENV": "production"}
            for _ in range(2):
                runners.append(subprocess.Popen([sys.executable, "scripts/migrate_deployment.py"], cwd=ROOT, env=environment,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
            for process in runners:
                output, _ = process.communicate(timeout=90)
                if process.returncode or "migrated and verified" not in output:
                    raise RuntimeError("Concurrent PostgreSQL migration gate failed")
            assert "without changes" in run({**environment, "VERCEL_ENV": "preview"})
            with engine.connect() as db:
                assert db.execute(text("SELECT version_num FROM alembic_version")).scalars().all() == ["e93ab6824d10"]
                assert db.execute(text("SELECT image_data_url FROM saved_items WHERE id='kept'")).scalar().startswith("data:image/png;base64,")
                assert db.execute(text("SELECT count(*) FROM saved_media")).scalar() == 1
                assert db.execute(text("SELECT count(*) FROM multimodal_assets")).scalar() == 0
            validate_multimodal_journey(url)
            print("PASS: PostgreSQL legacy image upgrade, concurrent production migration locks, read-only preview gate, preserved capture, and multimodal voice/publication/search/reanalysis/isolation/deletion journey.")
        finally:
            for process in runners:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            if engine:
                engine.dispose()
            if started:
                subprocess.run([str(binaries / "pg_ctl"), "-D", str(data), "-m", "fast", "-w", "stop"], check=True, capture_output=True)
            if old_url is None:
                os.environ.pop("DATABASE_URL", None)
            else:
                os.environ["DATABASE_URL"] = old_url


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--postgres-bin", type=Path, default=Path("/Library/PostgreSQL/18/bin"))
    validate(parser.parse_args().postgres_bin)
