"""Verify a supplied catalog bundle and add its licensed real datasets.

This never executes archive contents or replaces a working ABO snapshot. Imports
are additive and atomic per source. Fictional/synthetic sources remain excluded.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tempfile
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.import_catalog_bundle import _manifest
from backend.app.catalog.datasets import load_source
from backend.app.catalog.recommendation_index import ensure_recommendation_index
from backend.app.catalog.search_index import ensure_index
from backend.app.catalog.service import source_status
from backend.app.db import Base, make_database


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    output = ROOT / "local-data" / "recommendation-catalog.db"
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="mynah-verified-catalog-") as temporary:
        staging = Path(temporary)
        with ZipFile(args.archive) as archive:
            entries = archive.infolist()
            if len(entries) > 60 or sum(entry.file_size for entry in entries) > 200 * 1024 * 1024:
                raise ValueError("Catalog archive exceeds expected bounds")
            seen = set()
            for entry in entries:
                path = PurePosixPath(entry.filename)
                if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != "mymah-finds-catalogs" or entry.filename in seen:
                    raise ValueError("Invalid or duplicate archive path")
                seen.add(entry.filename)
                if stat.S_ISLNK(entry.external_attr >> 16) or entry.file_size > 128 * 1024 * 1024:
                    raise ValueError("Invalid archive entry")
                destination = staging.joinpath(*path.parts)
                if entry.is_dir():
                    destination.mkdir(parents=True, exist_ok=True)
                    continue
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(entry) as source, destination.open("wb") as target:
                    shutil.copyfileobj(source, target, length=1024 * 1024)
        directory = staging / "mymah-finds-catalogs"
        sources = _manifest(directory)
        # Verify all source bytes before writing any dataset, including sources
        # intentionally excluded from shopping recommendations.
        for entry in sources:
            digest = hashlib.sha256()
            with (directory / entry["file"]).open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            if digest.hexdigest() != entry["sha256"]:
                raise ValueError("Catalog source checksum mismatch")
        engine, factory = make_database("sqlite:///" + str(output))
        try:
            Base.metadata.create_all(engine)
            with engine.begin() as connection:
                ensure_index(connection)
            with factory() as db:
                before = {item["source_id"]: item["record_count"] for item in source_status(db)["items"]}
            for entry in sources:
                if entry["data_kind"] != "open_dataset":
                    continue
                if entry["source_id"] == "abo" and before.get("abo") == entry["row_count"]:
                    with gzip.open(directory / entry["file"], "rb") as stream:
                        if sum(1 for line in stream if line.strip()) != entry["row_count"]:
                            raise ValueError("ABO source count mismatch")
                    print(json.dumps({"source_id": "abo", "row_count": entry["row_count"], "retained_official_snapshot": True}), flush=True)
                    continue
                result = load_source(factory, entry["source_id"], directory / entry["file"], normalized=True,
                                     version=entry["version"], expected_count=entry["row_count"])
                print(json.dumps({"source_id": entry["source_id"], "row_count": result["row_count"]}), flush=True)
            with engine.begin() as connection:
                ensure_recommendation_index(connection)
            with factory() as db:
                imported = [row for row in source_status(db)["items"] if row["data_kind"] == "open_dataset" and row["configured"]]
            summary = {"archive": args.archive.name, "verified_bundle_sources": len(sources),
                       "bundle_records": sum(entry["row_count"] for entry in sources),
                       "eligible_records": sum(row["record_count"] for row in imported), "sources": imported}
            (output.parent / "recommendation-catalog-inventory.json").write_text(json.dumps(summary, indent=2) + "\n")
            print(json.dumps({"eligible_records": summary["eligible_records"], "verified_bundle_sources": len(sources)}), flush=True)
        finally:
            engine.dispose()


if __name__ == "__main__":
    main()
