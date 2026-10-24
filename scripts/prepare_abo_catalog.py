"""Fetch the licensed ABO metadata (not image binaries) for local recommendations.

The source and license are documented in docs/catalog-integration.md. Downloads
are bounded and resumable by complete files; products stay in ignored local-data.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import json
import sys

import httpx

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from backend.app.catalog.datasets import load_source
from backend.app.catalog.search_index import ensure_index
from backend.app.catalog.recommendation_index import ensure_recommendation_index
from backend.app.db import Base, make_database

BASE = "https://amazon-berkeley-objects.s3.us-east-1.amazonaws.com/"
DIRECTORY = ROOT / "local-data" / "abo"
DATABASE = ROOT / "local-data" / "recommendation-catalog.db"
MAX_FILE = 20 * 1024 * 1024


def download(entry):
    name, remote = entry
    destination = DIRECTORY / name
    if not destination.exists():
        temporary = destination.with_suffix(destination.suffix + ".download")
        try:
            size = 0
            with httpx.Client(timeout=60, follow_redirects=False, trust_env=False) as client:
                with client.stream("GET", BASE + remote) as response:
                    response.raise_for_status()
                    if int(response.headers.get("content-length", "0")) > MAX_FILE:
                        raise ValueError("Source metadata exceeds the expected file size")
                    with temporary.open("wb") as output:
                        for chunk in response.iter_bytes():
                            size += len(chunk)
                            if size > MAX_FILE:
                                raise ValueError("Source metadata exceeds the expected file size")
                            output.write(chunk)
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)
    data = destination.read_bytes()
    if not 0 < len(data) <= MAX_FILE:
        raise ValueError("Invalid metadata file size")
    return {"file": name, "source_url": BASE + remote, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def main():
    DIRECTORY.mkdir(parents=True, exist_ok=True)
    entries = [(f"listings_{suffix}.json.gz", f"listings/metadata/listings_{suffix}.json.gz") for suffix in "0123456789abcdef"]
    entries += [("images.csv.gz", "images/metadata/images.csv.gz")]
    with ThreadPoolExecutor(max_workers=4) as executor:
        files = list(executor.map(download, entries))
    engine, factory = make_database("sqlite:///" + str(DATABASE))
    try:
        Base.metadata.create_all(engine)
        with engine.begin() as connection:
            ensure_index(connection)
        result = load_source(factory, "abo", DIRECTORY, images=DIRECTORY / "images.csv.gz",
                             version="abo-official-2026-10-25", expected_count=147702)
        with engine.begin() as connection:
            ensure_recommendation_index(connection)
        manifest = {"source": "Amazon Berkeley Objects", "license": "CC-BY-4.0", "files": files,
                    "total_download_bytes": sum(item["bytes"] for item in files), "import": result}
        (DIRECTORY / "download-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(json.dumps({"source": "abo", "records": result["row_count"],
                          "download_bytes": manifest["total_download_bytes"], "database": str(DATABASE)}), flush=True)
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
