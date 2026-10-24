"""Build a deterministic, source-separated licensed dataset handoff.

Reads DATABASE_URL. Never exports private Library tables or affiliate feeds.
Run after dataset imports complete; concurrent source changes abort publication.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile
from zipfile import ZIP_STORED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from sqlalchemy import func, select

from backend.app.catalog import service as catalog_service
from backend.app.catalog.registry import DATASET_SOURCES
from backend.app.db import CatalogFeed, make_database

DIST = ROOT / "dist"
LICENSES = ROOT / "docs" / "catalog-licenses"
BUNDLE_NAME = "mymah-finds-catalogs"
LICENSE_FILES = {
    "abo": ("ABO-NOTICE.txt", "CC-BY-4.0.txt"), "uci_retail": ("CC-BY-4.0.txt",),
    "wands": ("WANDS-MIT.txt",), "northwind": ("Microsoft-MIT.txt",),
    "adventureworks": ("Microsoft-MIT.txt",),
    "open_beauty_facts": ("ODbL-1.0.txt", "DbCL-1.0.txt"),
    "open_products_facts": ("ODbL-1.0.txt", "DbCL-1.0.txt"),
    "open_food_facts": ("ODbL-1.0.txt", "DbCL-1.0.txt"),
}
OPEN_FACTS_SOURCES = {"open_beauty_facts", "open_products_facts", "open_food_facts"}


class CatalogBundleError(Exception):
    pass


def _canonical_json(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":"))


def _sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _source_state(factory, source_id):
    """Snapshot markers and count from the shared catalog only."""
    with factory() as db:
        feeds = tuple(db.execute(select(CatalogFeed.id, CatalogFeed.last_import_id)
                                 .where(CatalogFeed.source_id == source_id, CatalogFeed.enabled.is_(True))
                                 .order_by(CatalogFeed.id)).all())
        count = db.scalar(select(func.count()).select_from(catalog_service.visible_records(source_id).subquery()))
    return feeds, count


def _write_export(factory, source_id, target):
    source = DATASET_SOURCES[source_id]
    digest = hashlib.sha256()
    count, uncompressed_size = 0, 0
    version = checksum = None
    with target.open("wb") as raw:
        # Omit the filename header and use epoch mtime so source mtimes/clock do
        # not affect bytes. No network or image fetch occurs during packaging.
        with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0, compresslevel=6) as compressed:
            for line in catalog_service.export_dataset(factory, source_id):
                record = json.loads(line)
                provenance = record.get("provenance", {})
                if (record.get("source_id") != source_id or record.get("data_kind") != source.kind
                        or provenance.get("license_id") != source.license_id
                        or provenance.get("license_url") != source.license_url
                        or provenance.get("attribution") != source.attribution):
                    raise CatalogBundleError(f"{source_id}: source or rights metadata does not match the reviewed registry")
                row_version, row_checksum = provenance.get("dataset_version"), provenance.get("source_checksum")
                if not isinstance(row_version, str) or not row_version or not isinstance(row_checksum, str) or not re.fullmatch(r"[a-f0-9]{64}", row_checksum):
                    raise CatalogBundleError(f"{source_id}: normalized records lack dataset version/checksum metadata")
                if version is None:
                    version, checksum = row_version, row_checksum
                if (version, checksum) != (row_version, row_checksum):
                    raise CatalogBundleError(f"{source_id}: export spans multiple dataset versions")
                encoded = (_canonical_json(record) + "\n").encode("utf-8")
                compressed.write(encoded)
                digest.update(encoded)
                count += 1
                uncompressed_size += len(encoded)
    if not count:
        raise CatalogBundleError(f"{source_id}: enabled source has no exportable records")
    notices = LICENSE_FILES.get(source_id, ())
    if source.license_id != "Generated locally" and not notices:
        raise CatalogBundleError(f"{source_id}: add its reviewed license notice before packaging")
    return {
        "source_id": source_id, "name": source.name, "data_kind": source.kind,
        "license_id": source.license_id, "license_url": source.license_url,
        "attribution": source.attribution, "version": version, "source_checksum": checksum,
        "row_count": count, "file": target.name, "format": "jsonl.gz",
        "sha256": _sha256(target), "uncompressed_sha256": digest.hexdigest(),
        "compressed_bytes": target.stat().st_size, "uncompressed_bytes": uncompressed_size,
        "license_files": [f"LICENSES/{notice}" for notice in notices],
        **({"contents_license_id": "DbCL-1.0",
            "contents_license_url": "https://opendatacommons.org/licenses/dbcl/1.0/"}
           if source_id in OPEN_FACTS_SOURCES else {}),
        "source_isolated": True,
    }


def _zip_directory(directory, target):
    # Entries are already compressed JSONL or small notices. ZIP_STORED avoids a
    # second compression pass and preserves a deterministic archive layout.
    with ZipFile(target, "w", compression=ZIP_STORED, allowZip64=True) as archive:
        for path in sorted(directory.rglob("*")):
            if not path.is_file():
                continue
            info = ZipInfo(f"{BUNDLE_NAME}/{path.relative_to(directory).as_posix()}", date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = ZIP_STORED
            with path.open("rb") as source, archive.open(info, "w", force_zip64=True) as destination:
                shutil.copyfileobj(source, destination, length=1024 * 1024)


def build_catalog_bundle(factory, *, output_directory=DIST, license_directory=LICENSES):
    """Return manifest and fixed archive path after all checks pass.

    Optional directories exist for isolated tests; the CLI always uses dist/
    and the reviewed repository notices. It accepts no arbitrary export scope.
    """
    output_directory, license_directory = Path(output_directory), Path(license_directory)
    output_directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".catalog-bundle-", dir=output_directory) as temp:
        stage = Path(temp) / BUNDLE_NAME
        stage.mkdir()
        entries, states = [], {}
        for source_id in sorted(DATASET_SOURCES):
            before = _source_state(factory, source_id)
            if not before[0]:
                continue
            entry = _write_export(factory, source_id, stage / f"{source_id}.jsonl.gz")
            if entry["row_count"] != before[1] or _source_state(factory, source_id) != before:
                raise CatalogBundleError(f"{source_id}: catalog changed while exporting; retry after imports finish")
            entries.append(entry)
            states[source_id] = before
        if not entries:
            raise CatalogBundleError("Import at least one registered dataset before creating the catalog handoff")
        notices = sorted({path for entry in entries for path in entry["license_files"]})
        license_manifest = []
        for relative in notices:
            source_path = license_directory / Path(relative).name
            if not source_path.is_file() or source_path.is_symlink():
                raise CatalogBundleError(f"Missing reviewed license notice: {source_path.name}")
            target = stage / relative
            target.parent.mkdir(exist_ok=True)
            shutil.copyfile(source_path, target)
            license_manifest.append({"file": relative, "sha256": _sha256(target), "bytes": target.stat().st_size})
        manifest = {
            "format_version": 1, "name": "Mymah Finds source-separated catalog datasets",
            "record_schema": "normalized-catalog-v2", "sources": entries,
            "total_records": sum(entry["row_count"] for entry in entries), "licenses": license_manifest,
            "content_scope": "Registered local dataset sources only; no private Library, user evidence, affiliate feeds, credentials or image binaries.",
            "reuse": "Each source export retains its own license and attribution. Open Facts adaptations are separate ODbL datasets with individual contents under DbCL; product images are excluded. Source files must not be treated as one newly licensed combined dataset.",
        }
        (stage / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, allow_nan=False, sort_keys=True, indent=2) + "\n")
        archive = Path(temp) / f"{BUNDLE_NAME}.zip"
        _zip_directory(stage, archive)
        for source_id, before in states.items():
            if _source_state(factory, source_id) != before:
                raise CatalogBundleError(f"{source_id}: catalog changed before publication; retry after imports finish")
        destination, archive_destination = output_directory / BUNDLE_NAME, output_directory / f"{BUNDLE_NAME}.zip"
        if destination.is_symlink() or archive_destination.is_symlink():
            raise CatalogBundleError("Refusing to replace a symlink at a fixed catalog output path")
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(str(stage), destination)
        archive.replace(archive_destination)
        return {"manifest": manifest, "archive": archive_destination, "directory": destination}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args(argv)
    engine, factory = make_database()
    try:
        result = build_catalog_bundle(factory)
        print(json.dumps({"archive": str(result["archive"].relative_to(ROOT)),
                          "sources": len(result["manifest"]["sources"]), "records": result["manifest"]["total_records"]}))
        return 0
    except CatalogBundleError as error:
        print(f"Catalog handoff not published: {error}", file=sys.stderr)
        return 1
    finally:
        engine.dispose()


if __name__ == "__main__":
    raise SystemExit(main())
