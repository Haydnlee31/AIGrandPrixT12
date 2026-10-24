"""Stream licensed historical ABO/WANDS records without inventing live offers."""
from __future__ import annotations

import csv
import gzip
import hashlib
from html.parser import HTMLParser
import json
import math
from pathlib import Path
import re
import stat
import unicodedata


ABO_BASE = "https://amazon-berkeley-objects.s3.us-east-1.amazonaws.com/"
WANDS_PRODUCTS = "https://raw.githubusercontent.com/wayfair/WANDS/main/dataset/product.csv"
MAX_LINE_BYTES = 2 * 1024 * 1024
MAX_FILE_BYTES = 256 * 1024 * 1024
MAX_ATTRIBUTES = 24_000


class DatasetFormatError(ValueError):
    """Sanitized input failure: never includes source text or a raw record."""
    def __init__(self, code, message):
        self.code = code
        super().__init__(message)


class _PlainText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.blocked = []

    def handle_starttag(self, tag, attrs):
        if tag in {"script", "style", "iframe", "object", "noscript"}:
            self.blocked.append(tag)
        elif not self.blocked:
            self.parts.append(" ")

    def handle_endtag(self, tag):
        if self.blocked:
            if tag == self.blocked[-1]:
                self.blocked.pop()
        else:
            self.parts.append(" ")

    def handle_data(self, data):
        if not self.blocked:
            self.parts.append(data)


def _text(value, limit=1000):
    if not isinstance(value, str):
        return None
    # Source files are bounded separately. Avoid parsing needless megabytes when
    # a field can only contribute a few thousand characters to the contract.
    parser = _PlainText()
    parser.feed(value[:max(limit * 4, 4096)])
    parser.close()
    plain = "".join(parser.parts)
    plain = "".join(" " if unicodedata.category(c) in {"Cc", "Cf", "Cs"} else c for c in plain)
    return " ".join(plain.split())[:limit].strip() or None


def _localized(value, limit=1000, preferred=None):
    if isinstance(value, str):
        return _text(value, limit), None
    if not isinstance(value, list):
        return None, None
    candidates = []
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            continue
        text = _text(item.get("value"), limit)
        if text is None:
            continue
        language = item.get("language_tag") if isinstance(item.get("language_tag"), str) else None
        priority = 0 if preferred and language == preferred else 1 if language == "en_US" else 2 if language and language.startswith("en_") else 3 if language is None else 4
        candidates.append((priority, index, text, language))
    if not candidates:
        return None, None
    _, _, text, language = min(candidates)
    return text, language


def _bounded_value(value, depth=0):
    if depth > 5:
        return None
    if value is None or type(value) is bool:
        return value
    if type(value) is int:
        return value if abs(value) <= 2**53 - 1 else str(value)[:100]
    if type(value) is float:
        return value if math.isfinite(value) else None
    if isinstance(value, str):
        return _text(value, 512)
    if isinstance(value, list):
        return [_bounded_value(child, depth + 1) for child in value[:32]]
    if isinstance(value, dict):
        return {str(key)[:100]: _bounded_value(child, depth + 1) for key, child in list(value.items())[:64]}
    return None


def _attributes(raw, fields, initial=None):
    result = dict(initial or {})
    omitted = []
    for field in fields:
        if field not in raw or raw[field] in (None, "", []):
            continue
        value = _text(raw[field], 12000) if field == "product_features" else _bounded_value(raw[field])
        candidate = {**result, field: value}
        if len(json.dumps(candidate, allow_nan=False)) <= MAX_ATTRIBUTES:
            result = candidate
        else:
            omitted.append(field)
    if omitted:
        result["omitted_large_fields"] = omitted
    return result


def _file(path):
    path = Path(path)
    if not path.is_file() or not stat.S_ISREG(path.stat().st_mode) or path.stat().st_size > MAX_FILE_BYTES:
        raise DatasetFormatError("invalid_dataset_file", "Use a regular dataset file within the 256 MiB per-file limit")
    return path


def _offer(record_id, image_url=None):
    return {"id": record_id, "price_minor": None, "currency": None, "shipping_minor": None,
            "availability": "unknown", "condition": None, "url": None, "image_url": image_url,
            "observed_at": None, "expires_at": None, "marketplace_id": None, "environment": "local"}


def _image_paths(path):
    if path is None:
        return {}
    result = {}
    try:
        with gzip.open(_file(path), "rt", encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle)
            if not reader.fieldnames or not {"image_id", "path"}.issubset(reader.fieldnames):
                raise DatasetFormatError("invalid_image_metadata", "ABO image metadata requires image_id and path")
            for count, row in enumerate(reader, 1):
                image_id, image_path = row.get("image_id"), row.get("path")
                if count > 500000 or not image_id or len(image_id) > 128 or not isinstance(image_path, str) or not re.fullmatch(r"[0-9a-f]{2}/[0-9a-f]+\.(?:jpg|png)", image_path):
                    raise DatasetFormatError("invalid_image_metadata", "ABO image metadata contains an invalid or oversized mapping")
                if image_id in result and result[image_id] != image_path:
                    raise DatasetFormatError("conflicting_image_metadata", "ABO image metadata repeats an ID with a different path")
                result[image_id] = image_path
    except (OSError, EOFError, UnicodeError, csv.Error) as error:
        raise DatasetFormatError("invalid_image_metadata", "ABO image metadata could not be decoded") from error
    return result


def _abo_record(raw, images, source_file):
    if not isinstance(raw, dict):
        raise DatasetFormatError("invalid_abo_record", "Each ABO line must be a product object")
    item_id, domain = raw.get("item_id"), raw.get("domain_name")
    if not isinstance(item_id, str) or not 1 <= len(item_id) <= 256 or not isinstance(domain, str) or not 1 <= len(domain) <= 256:
        raise DatasetFormatError("invalid_abo_identity", "ABO requires an explicit item ID and source domain")
    title, language = _localized(raw.get("item_name"))
    if title is None:
        raise DatasetFormatError("missing_product_title", "An ABO record has no usable title in any language")
    description, _ = _localized(raw.get("product_description"), 20000, language)
    if description is None and isinstance(raw.get("bullet_point"), list):
        _, bullet_language = _localized(raw["bullet_point"], 1000, language)
        bullets = [_text(item.get("value"), 2000) for item in raw["bullet_point"] if isinstance(item, dict) and item.get("language_tag") == bullet_language]
        description = " ".join(text for text in bullets if text)[:20000] or None
    brand, _ = _localized(raw.get("brand"), 512, language)
    category, _ = _localized(raw.get("product_type"), 2048, language)
    identity = json.dumps([item_id, domain], ensure_ascii=False, separators=(",", ":"))
    record_id = "abo:" + hashlib.sha256(identity.encode()).hexdigest()
    image_path = images.get(raw.get("main_image_id")) if isinstance(raw.get("main_image_id"), str) else None
    attributes = _attributes(raw, ["country", "marketplace", "domain_name", "product_type", "brand", "color", "material", "item_dimensions", "item_weight", "fabric_type", "finish_type", "model_name", "model_number", "model_year", "style", "pattern", "item_shape", "node", "item_keywords", "main_image_id"], {"title_language": language})
    return {"source_id": "abo", "source_record_id": record_id, "data_kind": "open_dataset",
            "title": title, "description": description, "category": category, "brand": brand,
            "attributes": attributes, "product_key": record_id, "variant_key": None,
            "merchant": {"id": None, "name": None, "platform": "abo"},
            "offer": _offer(record_id, ABO_BASE + "images/small/" + image_path if image_path else None),
            "provenance": {"original_item_id": item_id, "domain_name": domain, "source_record_id": item_id,
                           "title_language": language, "source_url": ABO_BASE + "listings/metadata/" + source_file,
                           "release_reference": "https://registry.opendata.aws/amazon-berkeley-objects/",
                           "normalization": "Historical metadata; text normalized; no seller, price or stock inferred"}}


def iter_abo(directory, image_metadata=None):
    """Yield one historical record per (ASIN, source domain), without DB/network IO."""
    directory = Path(directory)
    nested = directory / "listings" / "metadata"
    if nested.is_dir():
        directory = nested
    files = sorted(directory.glob("listings_[0-9a-f].json.gz"))
    if not files:
        raise DatasetFormatError("missing_abo_shards", "No ABO listing shards were found")
    images = _image_paths(image_metadata)
    for path in files:
        decoded = 0
        try:
            with gzip.open(_file(path), "rb") as handle:
                while line := handle.readline(MAX_LINE_BYTES + 1):
                    decoded += len(line)
                    if len(line) > MAX_LINE_BYTES or decoded > MAX_FILE_BYTES:
                        raise DatasetFormatError("dataset_size_limit", "ABO decompressed line or shard exceeds its limit")
                    if not line.strip():
                        continue
                    raw = json.loads(line.decode("utf-8"), parse_constant=lambda _: None)
                    yield _abo_record(raw, images, path.name)
        except (OSError, EOFError, UnicodeError, json.JSONDecodeError, RecursionError) as error:
            raise DatasetFormatError("invalid_abo_file", "An ABO shard could not be decoded") from error


def iter_wands(path):
    """Read the complete WANDS TSV, including quoted and oversized text fields."""
    previous_limit = csv.field_size_limit()
    csv.field_size_limit(MAX_LINE_BYTES)
    try:
        with _file(path).open(encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle, delimiter="\t", strict=True)
            if not reader.fieldnames or len(reader.fieldnames) > 64 or len(reader.fieldnames) != len(set(reader.fieldnames)) or not {"product_id", "product_name"}.issubset(reader.fieldnames):
                raise DatasetFormatError("invalid_wands_header", "WANDS requires distinct product_id and product_name TSV columns")
            for raw in reader:
                if None in raw or any(value is None for value in raw.values()):
                    raise DatasetFormatError("invalid_wands_row", "A WANDS row does not match its header")
                item_id = raw["product_id"].strip()
                title = _text(raw["product_name"])
                if not item_id or len(item_id) > 256 or title is None:
                    raise DatasetFormatError("invalid_wands_identity", "A WANDS record requires an explicit ID and usable title")
                record_id = "wands:" + item_id
                attributes = _attributes(raw, ["product_class", "category hierarchy", "product_features", "rating_count", "average_rating", "review_count"])
                yield {"source_id": "wands", "source_record_id": record_id, "data_kind": "open_dataset",
                       "title": title, "description": _text(raw.get("product_description"), 20000),
                       "category": _text(raw.get("category hierarchy") or raw.get("category_hierarchy") or raw.get("product_class"), 2048),
                       "brand": None, "attributes": attributes, "product_key": record_id, "variant_key": None,
                       "merchant": {"id": None, "name": None, "platform": "wands"}, "offer": _offer(record_id),
                       "provenance": {"original_product_id": item_id, "source_record_id": item_id,
                                      "source_url": WANDS_PRODUCTS, "dataset_version": "ECIR-2022",
                                      "normalization": "Historical metadata; text normalized; no seller, price or stock inferred"}}
    except (OSError, UnicodeError, csv.Error) as error:
        raise DatasetFormatError("invalid_wands_file", "WANDS could not be decoded as a bounded TSV file") from error
    finally:
        csv.field_size_limit(previous_limit)
