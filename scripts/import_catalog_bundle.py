"""Restore a reviewed, extracted catalog bundle using DATABASE_URL.

All compressed files are verified before any database writes. Each source is
then imported atomically; a later failure preserves earlier successful sources.
No archives are extracted, URLs fetched, or Library records changed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from pydantic import ValidationError
from sqlalchemy.exc import SQLAlchemyError

from backend.app.catalog.datasets import load_source
from backend.app.catalog.registry import DATASET_SOURCES
from backend.app.catalog.service import CatalogError
from backend.app.db import make_database

MAX_MANIFEST_BYTES = 256 * 1024
MAX_COMPRESSED_BYTES = 2 * 1024 * 1024 * 1024


class CatalogBundleImportError(ValueError):
    pass


def _regular_file(path):
    # O_NOFOLLOW also prevents following a symlink swapped in after validation.
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    handle = os.fdopen(descriptor, "rb")
    if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
        handle.close()
        raise CatalogBundleImportError("Bundle inputs must be regular, non-symlink files")
    return handle


def _unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CatalogBundleImportError("Manifest contains duplicate JSON keys")
        result[key] = value
    return result


def _manifest(directory):
    if not directory.is_dir() or directory.is_symlink():
        raise CatalogBundleImportError("Provide a regular extracted bundle directory")
    with _regular_file(directory / "manifest.json") as handle:
        data = handle.read(MAX_MANIFEST_BYTES + 1)
    if len(data) > MAX_MANIFEST_BYTES:
        raise CatalogBundleImportError("Bundle manifest exceeds the size limit")
    manifest = json.loads(data, object_pairs_hook=_unique_keys)
    if (not isinstance(manifest, dict) or type(manifest.get("format_version")) is not int
            or manifest["format_version"] != 1 or manifest.get("record_schema") != "normalized-catalog-v2"):
        raise CatalogBundleImportError("Unsupported catalog bundle format")
    sources = manifest.get("sources")
    if not isinstance(sources, list) or not 1 <= len(sources) <= 20:
        raise CatalogBundleImportError("Bundle must contain between one and twenty sources")
    seen = set()
    for entry in sources:
        if not isinstance(entry, dict):
            raise CatalogBundleImportError("Every bundle source must be an object")
        source_id = entry.get("source_id")
        if not isinstance(source_id, str) or source_id not in DATASET_SOURCES or source_id in seen:
            raise CatalogBundleImportError("Bundle sources must be unique registered datasets")
        seen.add(source_id)
        if entry.get("file") != f"{source_id}.jsonl.gz" or entry.get("format") != "jsonl.gz":
            raise CatalogBundleImportError("A source filename must match its registered dataset")
        if not isinstance(entry.get("sha256"), str) or not re.fullmatch(r"[a-f0-9]{64}", entry["sha256"]):
            raise CatalogBundleImportError("Each source needs a compressed SHA256 checksum")
        version = entry.get("version")
        if not isinstance(version, str) or not 1 <= len(version) <= 200 or any(ord(c) < 32 or ord(c) == 127 for c in version):
            raise CatalogBundleImportError("Each source needs a bounded version label")
        if type(entry.get("row_count")) is not int or not 1 <= entry["row_count"] <= 1000000:
            raise CatalogBundleImportError("Source row counts must be between one and one million")
        source = DATASET_SOURCES[source_id]
        if any(entry.get(key) != value for key, value in {
            "data_kind": source.kind, "license_id": source.license_id,
            "license_url": source.license_url, "attribution": source.attribution,
        }.items()):
            raise CatalogBundleImportError("Manifest rights metadata does not match the reviewed source registry")
    return sources


def import_catalog_bundle(factory, directory, *, on_result=None):
    """Validate every source first, then restore independently atomic snapshots."""
    directory = Path(directory)
    sources = _manifest(directory)
    results = []
    with tempfile.TemporaryDirectory(prefix="mymah-catalog-restore-") as temporary:
        staged = Path(temporary)
        total_size = 0
        for entry in sources:
            digest = hashlib.sha256()
            with _regular_file(directory / entry["file"]) as source, (staged / entry["file"]).open("wb") as target:
                while block := source.read(1024 * 1024):
                    total_size += len(block)
                    if total_size > MAX_COMPRESSED_BYTES:
                        raise CatalogBundleImportError("Compressed bundle exceeds the size limit")
                    digest.update(block)
                    target.write(block)
            if digest.hexdigest() != entry["sha256"]:
                raise CatalogBundleImportError("Compressed source checksum does not match the manifest")
        # Only the verified snapshots below are read during database writes.
        for entry in sources:
            result = load_source(factory, entry["source_id"], staged / entry["file"], normalized=True,
                                 version=entry["version"], expected_count=entry["row_count"])
            summary = {"source_id": entry["source_id"], "row_count": result["row_count"], "unchanged": result["unchanged"]}
            results.append(summary)
            if on_result:
                on_result(summary)
    return results


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="Extracted mymah-finds-catalogs directory containing manifest.json")
    args = parser.parse_args(argv)
    engine, factory = make_database()
    try:
        results = import_catalog_bundle(factory, args.directory, on_result=lambda result: print(json.dumps(result), flush=True))
        print(json.dumps({"restored_sources": len(results), "total_records": sum(result["row_count"] for result in results)}))
        return 0
    except (OSError, ValueError, RecursionError, CatalogError, ValidationError, SQLAlchemyError) as error:
        print(json.dumps({"error": {"code": getattr(error, "code", "catalog_bundle_restore_failed"),
                                    "message": "Restore failed. The failing source was preserved; any earlier successful sources remain imported.",
                                    "error_type": type(error).__name__}}), file=sys.stderr)
        return 1
    finally:
        engine.dispose()


if __name__ == "__main__":
    raise SystemExit(main())
