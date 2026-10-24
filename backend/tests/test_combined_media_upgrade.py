"""Upgrade both teammate database histories without losing private captures."""
import base64
from io import BytesIO
from pathlib import Path

from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from PIL import Image, PngImagePlugin
import pytest
from sqlalchemy import create_engine, inspect, text

from backend.app.main import create_app


ROOT = Path(__file__).resolve().parents[2]


def image():
    stream = BytesIO()
    metadata = PngImagePlugin.PngInfo()
    metadata.add_text("private-location", "remove me")
    Image.new("RGB", (12, 12), "blue").save(stream, "PNG", pnginfo=metadata)
    return "data:image/png;base64," + base64.b64encode(stream.getvalue()).decode()


def setup_database(tmp_path, monkeypatch, revision):
    url = f"sqlite:///{tmp_path / 'upgrade.db'}"
    monkeypatch.setenv("DATABASE_URL", url)
    config = Config(str(ROOT / "alembic.ini"))
    config.set_main_option("script_location", str(ROOT / "backend/migrations"))
    command.upgrade(config, revision)
    engine = create_engine(url)
    with engine.begin() as db:
        db.execute(text("INSERT INTO saved_items "
                        "(id,user_id,original_url,canonical_url,title,source,selected_text,content_hash,note,captured_at,status,features,revision,deleted,client) "
                        "VALUES ('kept','owner','https://example.org/image','https://example.org/image','Saved watch','web','','','Gift',1,'ready','{}',1,0,'chrome_extension')"))
    return config, engine, url


@pytest.mark.parametrize("previous", ["b82a03563197", "c4d905a137ab"])
def test_main_and_chrome_databases_upgrade_to_one_head_with_private_media(tmp_path, monkeypatch, previous):
    config, engine, url = setup_database(tmp_path, monkeypatch, previous)
    raw = image()
    with engine.begin() as db:
        if previous == "c4d905a137ab":
            db.execute(text("INSERT INTO saved_media (item_id,user_id,image_data) VALUES ('kept','owner',:image)"), {"image": raw})
        else:
            db.execute(text("UPDATE saved_items SET image_data_url=:image WHERE id='kept'"), {"image": raw})
    command.upgrade(config, "head")
    with engine.connect() as db:
        assert db.execute(text("SELECT version_num FROM alembic_version")).scalars().all() == ["e93ab6824d10"]
        assert db.execute(text("SELECT count(*) FROM saved_media")).scalar() == 0
        assert {"saved_items", "multimodal_captures", "multimodal_assets"} <= set(inspect(engine).get_table_names())
    app = create_app(url, embedded_worker=False, tokens={"mine": "owner", "theirs": "other"})
    with TestClient(app, headers={"Authorization": "Bearer mine"}) as client:
        saved = client.get("/v1/saves/kept").json()
        assert saved["has_image"] and saved["title"] == "Saved watch" and saved["note"] == "Gift"
        encoded = client.get("/v1/saves/kept/media").json()["image_data"]
        pixels = Image.open(BytesIO(base64.b64decode(encoded.split(",", 1)[1])))
        assert pixels.getpixel((0, 0)) == (0, 0, 255)
        if previous == "c4d905a137ab":
            assert not pixels.info
        assert client.get("/v1/saves/kept/media", headers={"Authorization": "Bearer theirs"}).status_code == 404
        assert client.delete("/v1/saves/kept", headers={"Idempotency-Key": "remove"}).status_code == 200
        assert client.get("/v1/saves/kept/media").status_code == 404
    engine.dispose()


def test_legacy_owner_mismatch_stops_upgrade_without_discarding_media(tmp_path, monkeypatch):
    config, engine, _ = setup_database(tmp_path, monkeypatch, "c4d905a137ab")
    with engine.begin() as db:
        db.execute(text("INSERT INTO saved_media (item_id,user_id,image_data) VALUES ('kept','other',:image)"), {"image": image()})
    with pytest.raises(RuntimeError, match="ownership mismatch"):
        command.upgrade(config, "head")
    with engine.connect() as db:
        assert db.execute(text("SELECT count(*) FROM saved_media")).scalar() == 1
    engine.dispose()


def test_capture_alias_is_normalized_and_conflicting_fields_are_rejected(tmp_path):
    app = create_app(f"sqlite:///{tmp_path / 'aliases.db'}", embedded_worker=False, tokens={"mine": "owner"})
    with TestClient(app, headers={"Authorization": "Bearer mine"}) as client:
        payload = {"title": "Watch", "url": "", "image_data": image()}
        first = client.post("/v1/saves", json=payload, headers={"Idempotency-Key": "same"})
        assert first.status_code == 201
        canonical = {"title": "Watch", "image_data_url": image()}
        assert client.post("/v1/saves", json=canonical, headers={"Idempotency-Key": "same"}).json() == first.json()
        bad = {**payload, "image_data_url": "data:image/png;base64,AAAA"}
        assert client.post("/v1/saves", json=bad, headers={"Idempotency-Key": "bad"}).status_code == 422
