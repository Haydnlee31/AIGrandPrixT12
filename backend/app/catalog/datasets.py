"""Load reviewed local dataset files, or generate an explicitly synthetic source."""
import argparse
import hashlib
import gzip
import json
from pathlib import Path
import sys

from pydantic import ValidationError
from sqlalchemy.exc import IntegrityError

from ..db import make_database
from .registry import DATASET_SOURCES
from .service import CatalogError, import_dataset
from .synthetic import iter_synthetic


def files_digest(paths):
    digest = hashlib.sha256()
    for path in sorted(map(Path, paths), key=lambda p: p.name):
        digest.update(path.name.encode())
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    return digest.hexdigest()


def normalized_rows(path):
    opener = gzip.open if str(path).endswith(".gz") else open
    size = 0
    with opener(path, "rb") as handle:
        while line := handle.readline(2 * 1024 * 1024 + 1):
            size += len(line)
            if len(line) > 2 * 1024 * 1024 or size > 2 * 1024 * 1024 * 1024:
                raise ValueError("Normalized catalog exceeds its bounded input size")
            if line.strip():
                yield json.loads(line)


def load_source(factory, source, path=None, *, images=None, version="2026-10-25", count=20000, seed=31, normalized=False, expected_count=None):
    if normalized:
        if not path:
            raise ValueError("A normalized export path is required")
        checksum, records = files_digest([path]), normalized_rows(path)
    elif source == "synthetic":
        checksum = hashlib.sha256(json.dumps({"generator": "mymah-catalog-v1", "count": count, "seed": seed}, sort_keys=True).encode()).hexdigest()
        records = iter_synthetic(count, seed)
    else:
        if path is None:
            raise ValueError("A reviewed local dataset path is required")
        path = Path(path)
        if source == "abo":
            from .general_datasets import iter_abo
            paths = [path / f"listings_{suffix}.json.gz" for suffix in "0123456789abcdef"]
            if not all(item.is_file() for item in paths):
                raise ValueError("ABO requires all sixteen listing shards")
            if images:
                paths.append(Path(images))
            records = iter_abo(path, image_metadata=images)
        elif source == "wands":
            from .general_datasets import iter_wands
            paths, records = [path], iter_wands(path)
        elif source in DATASET_SOURCES:
            from .domain_datasets import iter_domain
            paths = [path] if path.is_file() else [path / name for name in ("product.json", "vendor.json", "productvendor.json")]
            records = iter_domain(source, path)
        else:
            raise ValueError("Choose a registered local dataset")
        checksum = files_digest(paths)
    return import_dataset(factory, source, records, version=version, checksum=checksum, expected_count=expected_count)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", choices=sorted(DATASET_SOURCES), required=True)
    parser.add_argument("--path", help="Reviewed file or ABO/AdventureWorks directory")
    parser.add_argument("--images", help="Optional ABO image-reference CSV gzip (metadata only)")
    parser.add_argument("--version", default="2026-10-25", help="Pinned dataset/version label, not a claim of current offers")
    parser.add_argument("--normalized", action="store_true", help="Read a source-isolated JSONL/gzip catalog export")
    parser.add_argument("--count", type=int, default=20000, help="Synthetic source size")
    parser.add_argument("--seed", type=int, default=31, help="Synthetic deterministic seed")
    args = parser.parse_args(argv)
    engine, factory = make_database()
    try:
        result = load_source(factory, args.source, args.path, images=args.images,
                             version=args.version, count=args.count, seed=args.seed, normalized=args.normalized)
        print(json.dumps(result))
        return 0
    except (CatalogError, ValidationError, ValueError, OSError, IntegrityError) as error:
        # Never dump provider rows, paths containing credentials, or user data.
        print(json.dumps({"error": {"code": getattr(error, "code", "dataset_import_failed"),
                                    "message": "Dataset import failed; the previous source snapshot was preserved",
                                    "error_type": type(error).__name__}}), file=sys.stderr)
        return 1
    finally:
        engine.dispose()


if __name__ == "__main__":
    sys.exit(main())
