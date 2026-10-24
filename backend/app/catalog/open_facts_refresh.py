"""Stage complete, bounded Open Facts exports without changing application data.

Only the two modest official bulk exports are supported. Food Facts' much larger
export and any API samples are deliberately excluded from snapshot replacement.
"""
from __future__ import annotations

import csv
from datetime import datetime, timezone
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import time
from uuid import uuid4
import zlib

import httpx

from .domain_datasets import _facts, _text
from .registry import DATASET_SOURCES
from .schemas import CatalogRecord


EXPORTS = {
    "open_products_facts": "https://static.openproductsfacts.org/data/en.openproductsfacts.org.products.csv.gz",
    "open_beauty_facts": "https://static.openbeautyfacts.org/data/en.openbeautyfacts.org.products.csv.gz",
}
MAX_COMPRESSED_BYTES = 100 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 1024 * 1024 * 1024
MAX_OUTPUT_BYTES = 512 * 1024 * 1024
MAX_ROWS = 1_000_000
MAX_FIELD_BYTES = 16 * 1024 * 1024
USER_AGENT = "MymahFinds/0.4 (https://github.com/Haydnlee31/AIGrandPrixT12)"


class RefreshError(ValueError):
    """Messages contain no downloaded record text or credentials."""

    def __init__(self, code, message):
        self.code = code
        super().__init__(message)


def _sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        while chunk := stream.read(64 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


class _BoundedReader(io.RawIOBase):
    def __init__(self, stream, limit):
        self.stream, self.limit, self.count = stream, limit, 0

    def readable(self):
        return True

    def readinto(self, target):
        chunk = self.stream.read(min(len(target), self.limit - self.count + 1))
        self.count += len(chunk)
        if self.count > self.limit:
            raise RefreshError("export_too_large", "The expanded export exceeds its byte limit")
        target[:len(chunk)] = chunk
        return len(chunk)


def _download(client, url, destination, *, max_bytes, timeout_seconds):
    started = time.monotonic()
    headers = {"Accept-Encoding": "identity", "User-Agent": USER_AGENT}
    with client.stream("GET", url, headers=headers, follow_redirects=False) as response:
        if response.status_code != 200:
            raise RefreshError("download_failed", "The official full export did not return HTTP 200")
        if response.headers.get("content-encoding", "identity").lower() != "identity":
            raise RefreshError("unexpected_encoding", "The export used an unexpected HTTP encoding")
        raw_length = response.headers.get("content-length")
        if raw_length is not None and (not raw_length.isdecimal() or int(raw_length) > max_bytes):
            raise RefreshError("export_too_large", "The declared download size is invalid or exceeds its limit")
        count = 0
        with destination.open("xb") as target:
            for chunk in response.iter_raw():
                count += len(chunk)
                if count > max_bytes:
                    raise RefreshError("export_too_large", "The download exceeds its byte limit")
                if time.monotonic() - started > timeout_seconds:
                    raise RefreshError("download_timeout", "The export exceeded its total download time limit")
                target.write(chunk)
        if count == 0 or (raw_length is not None and count != int(raw_length)):
            raise RefreshError("incomplete_download", "The full export download is incomplete")
        return {
            "download_bytes": count,
            "http_content_length": int(raw_length) if raw_length is not None else None,
            "http_last_modified": response.headers.get("last-modified"),
            "http_etag": response.headers.get("etag"),
        }


def _normalize(source_id, archive, destination, *, max_uncompressed_bytes, minimum_records):
    """Read through gzip EOF/CRC before accepting any normalized snapshot."""
    previous_field_limit = csv.field_size_limit(MAX_FIELD_BYTES)
    counts = {"raw_rows": 0, "unnamed_rows": 0, "duplicate_rows": 0, "row_count": 0}
    seen, output_bytes = {}, 0
    try:
        with gzip.open(archive, "rb") as compressed, destination.open("xb") as output:
            bounded = _BoundedReader(compressed, max_uncompressed_bytes)
            with io.TextIOWrapper(io.BufferedReader(bounded), encoding="utf-8-sig", newline="") as text:
                rows = csv.DictReader(text, delimiter="\t", strict=True)
                fields = rows.fieldnames
                if (not fields or not {"code", "product_name"}.issubset(fields)
                        or len(fields) != len(set(fields))):
                    raise RefreshError("invalid_export_schema", "The export requires unique code and product_name columns")
                for line_number, raw in enumerate(rows, 2):
                    counts["raw_rows"] += 1
                    if counts["raw_rows"] > MAX_ROWS:
                        raise RefreshError("export_too_large", "The export exceeds one million records")
                    if None in raw or any(value is None for value in raw.values()):
                        raise RefreshError("invalid_export_row", "A TSV row does not match the complete export schema")
                    if _text(raw.get("product_name"), 1000) is None:
                        counts["unnamed_rows"] += 1
                        continue
                    record = CatalogRecord.model_validate(_facts(source_id, raw, line_number)).model_dump()
                    encoded = (json.dumps(record, ensure_ascii=False, allow_nan=False, sort_keys=True) + "\n").encode()
                    fingerprint = hashlib.sha256(encoded).digest()
                    key = record["source_record_id"]
                    if key in seen:
                        if seen[key] != fingerprint:
                            raise RefreshError("conflicting_identity", "The export contains conflicting records for one product ID")
                        counts["duplicate_rows"] += 1
                        continue
                    seen[key] = fingerprint
                    output_bytes += len(encoded)
                    if output_bytes > MAX_OUTPUT_BYTES:
                        raise RefreshError("export_too_large", "The normalized export exceeds its byte limit")
                    output.write(encoded)
                    counts["row_count"] += 1
            counts["uncompressed_bytes"] = bounded.count
    except (gzip.BadGzipFile, EOFError, UnicodeError, csv.Error, zlib.error) as error:
        raise RefreshError("invalid_export", "The complete gzip/TSV export could not be validated") from error
    finally:
        csv.field_size_limit(previous_field_limit)
    if counts["row_count"] < minimum_records:
        raise RefreshError("insufficient_records", "The validated export contains fewer usable records than required")
    return {**counts, "normalized_bytes": output_bytes}


def refresh_source(source_id, output_dir, *, client=None, minimum_records=1,
                   max_compressed_bytes=MAX_COMPRESSED_BYTES,
                   max_uncompressed_bytes=MAX_UNCOMPRESSED_BYTES, timeout_seconds=240):
    """Download and atomically publish a validated snapshot directory.

    No DB connection is opened. An unsuccessful refresh removes its staging
    files and leaves every previous acquisition and catalog snapshot untouched.
    minimum_records can be set to the current source count to guard shrinkage.
    """
    if source_id not in EXPORTS:
        raise RefreshError("unsupported_source", "Choose Open Products Facts or Open Beauty Facts")
    if type(minimum_records) is not int or not 1 <= minimum_records <= MAX_ROWS:
        raise RefreshError("invalid_minimum", "The minimum record count must be between one and one million")
    if client is None:
        with httpx.Client(timeout=httpx.Timeout(30.0, connect=15.0)) as owned_client:
            return refresh_source(source_id, output_dir, client=owned_client, minimum_records=minimum_records,
                                  max_compressed_bytes=max_compressed_bytes,
                                  max_uncompressed_bytes=max_uncompressed_bytes, timeout_seconds=timeout_seconds)
    root = Path(output_dir) / source_id
    root.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".refresh-", dir=root))
    try:
        archive, normalized = stage / "source.csv.gz", stage / "catalog.jsonl"
        transport = _download(client, EXPORTS[source_id], archive,
                              max_bytes=max_compressed_bytes, timeout_seconds=timeout_seconds)
        counts = _normalize(source_id, archive, normalized,
                            max_uncompressed_bytes=max_uncompressed_bytes, minimum_records=minimum_records)
        timestamp = datetime.now(timezone.utc)
        version = "openfacts-" + timestamp.strftime("%Y%m%dT%H%M%SZ") + "-" + _sha256(archive)[:12]
        source = DATASET_SOURCES[source_id]
        manifest = {
            "format_version": 1, "source_id": source_id, "dataset_version": version,
            "download_url": EXPORTS[source_id], "retrieved_at": timestamp.isoformat(),
            "complete_export": True, "normalization": "named-metadata-v1",
            "archive_file": archive.name, "archive_sha256": _sha256(archive),
            "normalized_file": normalized.name, "normalized_sha256": _sha256(normalized),
            "license_id": source.license_id, "license_url": source.license_url,
            "contents_license": "https://opendatacommons.org/licenses/dbcl/1-0/",
            "attribution": source.attribution, "images_excluded": True,
            "current_offers": False, **transport, **counts,
        }
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        target = root / (timestamp.strftime("%Y%m%dT%H%M%SZ") + "-" + uuid4().hex[:8])
        os.replace(stage, target)
        return {**manifest, "directory": str(target.resolve())}
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def validate_acquisition(directory):
    """Recheck the manifest and both files before an operator chooses to import."""
    directory = Path(directory)
    manifest_path = directory / "manifest.json"
    if manifest_path.stat().st_size > 64 * 1024:
        raise RefreshError("invalid_manifest", "The acquisition manifest exceeds its byte limit")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if (not isinstance(manifest, dict) or manifest.get("format_version") != 1
            or manifest.get("complete_export") is not True
            or not isinstance(manifest.get("source_id"), str) or manifest.get("source_id") not in EXPORTS
            or manifest.get("archive_file") != "source.csv.gz"
            or manifest.get("normalized_file") != "catalog.jsonl"
            or manifest.get("download_url") != EXPORTS[manifest["source_id"]]
            or type(manifest.get("row_count")) is not int or not 1 <= manifest["row_count"] <= MAX_ROWS):
        raise RefreshError("invalid_manifest", "The acquisition manifest does not describe a complete supported export")
    for name, key, limit in (("source.csv.gz", "archive_sha256", MAX_COMPRESSED_BYTES),
                             ("catalog.jsonl", "normalized_sha256", MAX_OUTPUT_BYTES)):
        path = directory / name
        if path.stat().st_size > limit or _sha256(path) != manifest.get(key):
            raise RefreshError("checksum_mismatch", "A staged acquisition file has changed")
    return manifest
