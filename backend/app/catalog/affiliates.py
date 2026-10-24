"""Bounded, offline import of approved impact.com/CJ merchant exports.

This module does not establish data-use rights or fetch product/redirect URLs.
Catalog admission, retention, freshness and AI permissions belong to the caller.
"""

from __future__ import annotations

import csv
import hashlib
import io
import ipaddress
import json
import math
import os
import re
import stat
import time
from datetime import datetime
from decimal import Decimal, InvalidOperation, localcontext
from pathlib import Path
from typing import Any, Literal, Mapping
from urllib.parse import urlsplit

import httpx


MAX_FILE_BYTES = 32 * 1024 * 1024
MAX_FIELD_LENGTH = 16_384
MAX_ROW_LENGTH = 131_072
MAX_COLUMNS = 128
MAX_ROWS = 50_000
CJ_ENDPOINT = "https://ads.api.cj.com/query"

# Deliberately bounded supported currencies, not a claim that every ISO code has
# two decimals. Add another code only after checking its current minor unit.
CURRENCY_EXPONENT = dict.fromkeys(
    "USD SGD EUR GBP AUD CAD NZD HKD CNY MYR THB PHP IDR INR CHF SEK NOK DKK PLN CZK AED SAR ZAR BRL MXN TWD KRW JPY KWD BHD OMR".split(), 2
)
CURRENCY_EXPONENT.update(JPY=0, KRW=0, KWD=3, BHD=3, OMR=3)

IMPACT_COLUMNS = {
    "product_id": "Unique Merchant SKU", "variant_id": "Unique Merchant SKU",
    "title": "Product Name", "description": "Product Description",
    "category": "Category", "brand": "Manufacturer", "price": "Current Price",
    "currency": "Currency", "url": "Product URL", "image_url": "Image URL",
    "availability": "Stock Availability", "condition": "Condition",
    "gtin": "EAN", "upc": "UPC", "isbn": "ISBN", "mpn": "MPN",
    "parent_sku": "Parent SKU", "color": "Color", "size": "Size",
    "size_unit": "Size Unit of Measure", "material": "Material", "gender": "Gender",
}

# These are the common fields documented for CJ's products query. Additional
# shopping fields or custom CSV headers require an explicit column_mapping.
CJ_COLUMNS = {
    "product_id": "id", "catalog_id": "catalogId", "merchant_id": "advertiserId",
    "title": "title", "description": "description", "price": "price.amount",
    "currency": "price.currency", "url": "linkCode.clickUrl",
}
MAPPABLE_FIELDS = frozenset(IMPACT_COLUMNS) | frozenset(CJ_COLUMNS) | {
    "merchant_name", "source_updated_at", "gtin", "mpn", "variant_id",
}
ATTRIBUTE_FIELDS = ("gtin", "upc", "isbn", "mpn", "parent_sku", "color", "size", "size_unit", "material", "gender")


class AffiliateFeedError(ValueError):
    """A sanitized, actionable import failure; raw rows and secrets are excluded."""

    def __init__(self, code: str, message: str, *, row: int | None = None):
        self.code = code
        self.row = row
        super().__init__(f"{message}" + (f" (row {row})" if row is not None else ""))


def _fail(code: str, message: str, row: int | None = None):
    raise AffiliateFeedError(code, message, row=row)


def _scalar(value: Any, name: str, row: int | None = None, *, required: bool = False, limit: int = MAX_FIELD_LENGTH) -> str | None:
    if value is None:
        value = ""
    if isinstance(value, bool) or not isinstance(value, (str, int, Decimal)):
        _fail("invalid_field", f"{name} must be text or a number", row)
    value = str(value).strip()
    if len(value) > limit or "\x00" in value:
        _fail("invalid_field", f"{name} exceeds its limit or contains NUL", row)
    if not value:
        if required:
            _fail("missing_field", f"{name} is required", row)
        return None
    return value


def _currency(value: Any, row: int | None = None) -> str | None:
    result = _scalar(value, "currency", row)
    if result is None:
        return None
    result = result.upper()
    if result not in CURRENCY_EXPONENT:
        _fail("unsupported_currency", "Currency is not in the supported minor-unit table", row)
    return result


def price_to_minor(value: Any, currency: str | None, *, row: int | None = None) -> int | None:
    """Convert an exact major-unit amount; reject fractions of a minor unit."""
    text = _scalar(value, "price", row, limit=40)
    if text is None:
        return None
    if currency is None:
        _fail("missing_currency", "A supplied price requires a currency", row)
    currency = _currency(currency, row)
    if not re.fullmatch(r"\d+(?:\.\d+)?", text):
        _fail("invalid_price", "Price must be a nonnegative decimal without grouping or symbols", row)
    try:
        with localcontext() as context:
            context.prec = len(text) + 4
            amount = Decimal(text) * (10 ** CURRENCY_EXPONENT[currency])
        if amount != amount.to_integral_value():
            _fail("price_precision", "Price has a fraction of the currency's minor unit", row)
        if amount > 10**15:
            _fail("invalid_price", "Price exceeds the supported range", row)
        return int(amount)
    except InvalidOperation:
        _fail("invalid_price", "Invalid decimal price", row)


def _public_url(value: Any, name: str, row: int, *, image: bool = False) -> str | None:
    text = _scalar(value, name, row, required=not image, limit=4096)
    if text is None:
        return None
    try:
        parsed = urlsplit(text)
        host = (parsed.hostname or "").lower().rstrip(".")
        port = parsed.port
        if (parsed.scheme not in ({"https"} if image else {"http", "https"})
                or not host or parsed.username is not None or parsed.password is not None
                or "\\" in text or any(ord(c) < 33 or ord(c) == 127 for c in text)
                or port not in {None, 80, 443}):
            raise ValueError
        if host == "localhost" or host.endswith((".localhost", ".local", ".internal", ".home", ".lan")):
            raise ValueError
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            # Reject shorthand/numeric IP representations accepted by some URL
            # consumers; DNS is deliberately not resolved by the import parser.
            if "." not in host or all(re.fullmatch(r"(?:0x[0-9a-f]+|[0-9]+)", label) for label in host.split(".")):
                raise ValueError
            ascii_host = host.encode("idna").decode("ascii")
            if any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) for label in ascii_host.split(".")):
                raise ValueError
        else:
            if not address.is_global:
                raise ValueError
    except (ValueError, UnicodeError):
        _fail("invalid_url", f"{name} must be a public {'HTTPS' if image else 'HTTP(S)'} URL without credentials", row)
    # Affiliate query parameters and signatures must remain unchanged.
    return text


def _source_timestamp(value: Any, row: int) -> float | None:
    text = _scalar(value, "source_updated_at", row)
    if text is None:
        return None
    try:
        date = datetime.fromisoformat(text.replace("Z", "+00:00"))
        if date.tzinfo is None:
            raise ValueError
        result = date.timestamp()
        if not math.isfinite(result) or result < 0:
            raise ValueError
        return result
    except ValueError:
        _fail("invalid_timestamp", "source_updated_at must be ISO 8601 with a timezone", row)


def _lookup(record: Mapping[str, Any], path: str | None) -> Any:
    if path is None:
        return None
    # Flattened CSV headers such as price.amount take precedence over nesting.
    if path in record:
        return record[path]
    value: Any = record
    for part in path.split("."):
        if not isinstance(value, dict) or part not in value:
            return None
        value = value[part]
    return value


def _validate_node(value: Any, row: int, depth: int = 0) -> int:
    if depth > 6:
        _fail("row_limit", "Nested data exceeds the maximum depth", row)
    if isinstance(value, dict):
        if len(value) > MAX_COLUMNS:
            _fail("row_limit", "Too many fields in a record", row)
        total = 0
        for key, child in value.items():
            if not isinstance(key, str) or len(key) > 256:
                _fail("invalid_field", "Invalid field name", row)
            total += len(key) + _validate_node(child, row, depth + 1)
    elif isinstance(value, list):
        if len(value) > MAX_COLUMNS:
            _fail("row_limit", "Too many nested values", row)
        total = sum(_validate_node(child, row, depth + 1) for child in value)
    elif value is None:
        return 0
    else:
        total = len(str(value))
        if total > MAX_FIELD_LENGTH:
            _fail("field_limit", "A field exceeds the maximum length", row)
    if total > MAX_ROW_LENGTH:
        _fail("row_limit", "A record exceeds the maximum length", row)
    return total


def _json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            _fail("duplicate_column", "Duplicate JSON object key")
        result[key] = value
    return result


def _json_rows(text: str, source_id: str) -> list:
    try:
        data = json.loads(text, parse_float=Decimal, object_pairs_hook=_json_object,
                          parse_constant=lambda _: _fail("invalid_json", "Nonfinite JSON value"))
    except (json.JSONDecodeError, RecursionError):
        _fail("invalid_json", "Feed is not valid bounded JSON")
    if isinstance(data, list):
        return data
    if source_id == "cj" and isinstance(data, dict):
        if data.get("errors"):
            _fail("upstream_error", "CJ returned GraphQL errors; partial results cannot be imported")
        payload = data.get("data")
        if isinstance(payload, dict):
            candidates = [payload[key] for key in ("products", "shoppingProducts") if key in payload]
            if len(candidates) == 1 and isinstance(candidates[0], dict) and isinstance(candidates[0].get("resultList"), list):
                return candidates[0]["resultList"]
    _fail("invalid_json", "Use a JSON array of records or a CJ products/shoppingProducts response")


def _read_rows(path: Path, source_id: str, delimiter: str | None):
    try:
        # No archives, FIFOs, URL downloads, or unbounded decompression.
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NONBLOCK), "rb") as handle:
            if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
                _fail("invalid_file", "Feed must be a regular local file")
            raw = handle.read(MAX_FILE_BYTES + 1)
    except OSError:
        _fail("invalid_file", "Unable to read the local feed file")
    if len(raw) > MAX_FILE_BYTES:
        _fail("file_limit", "Feed exceeds the 32 MiB import limit; select a smaller complete approved catalog or use a future staging importer")
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeError:
        _fail("invalid_encoding", "Feed must use UTF-8; decompress archives before importing")
    if path.suffix.lower() == ".json":
        yield from enumerate(_json_rows(text, source_id), start=1)
        return
    if delimiter is not None and delimiter not in {",", "\t"}:
        _fail("invalid_delimiter", "Only comma and tab separators are supported")
    if delimiter is None:
        if path.suffix.lower() in {".tsv", ".tab"}:
            delimiter = "\t"
        elif path.suffix.lower() == ".csv":
            delimiter = ","
        else:
            _fail("invalid_format", "Use .csv/.tsv/.tab/.json, or supply a comma/tab delimiter")
    try:
        reader = csv.reader(io.StringIO(text, newline=""), delimiter=delimiter, strict=True)
        headers = next(reader, None)
        if headers is None or not headers or len(headers) > MAX_COLUMNS:
            _fail("invalid_header", "Feed requires a bounded header row")
        headers = [key.strip() for key in headers]
        if any(not key or len(key) > 256 for key in headers):
            _fail("invalid_header", "Empty or overlong field name")
        if len(set(headers)) != len(headers):
            _fail("duplicate_column", "Duplicate CSV/TSV column name")
        for row in reader:
            if not row:
                continue
            if len(row) != len(headers):
                _fail("invalid_row", "Record width does not match the header", reader.line_num)
            yield reader.line_num, dict(zip(headers, row))
    except csv.Error:
        _fail("invalid_csv", "Malformed CSV/TSV or oversized field")


def parse_feed(
    source_id: Literal["impact", "cj"], path: str | Path, *, catalog_id: str,
    merchant_id: str | None = None, merchant_name: str | None = None,
    currency: str | None = None, column_mapping: Mapping[str, str | None] | None = None,
    delimiter: str | None = None, max_rows: int = 10_000, observed_at: float | None = None,
) -> list[dict]:
    """Normalize one approved catalog; return nothing on any invalid/conflicting row.

    Explicit merchant/currency context must describe the approved source catalog.
    Mappings override source defaults; None disables an optional default mapping.
    No database writes, downloads, consent decisions or cross-source merges occur.
    """
    if source_id not in {"impact", "cj"}:
        _fail("invalid_source", "Only impact and cj affiliate sources are supported")
    if isinstance(max_rows, bool) or not isinstance(max_rows, int) or not 1 <= max_rows <= MAX_ROWS:
        _fail("invalid_limit", "max_rows must be between 1 and 50000")
    catalog_id = _scalar(catalog_id, "catalog_id", required=True, limit=256)
    merchant_id = _scalar(merchant_id, "merchant_id", limit=256)
    merchant_name = _scalar(merchant_name, "merchant_name", limit=300)
    currency = _currency(currency)
    now = time.time() if observed_at is None else observed_at
    if isinstance(now, bool) or not isinstance(now, (float, int)) or not math.isfinite(now) or now < 0:
        _fail("invalid_timestamp", "observed_at must be a finite Unix timestamp")
    columns = dict(IMPACT_COLUMNS if source_id == "impact" else CJ_COLUMNS)
    for field, mapped in (column_mapping or {}).items():
        if field not in MAPPABLE_FIELDS or (mapped is not None and (not isinstance(mapped, str) or not mapped or len(mapped) > 256)):
            _fail("invalid_mapping", "Unknown target field or invalid source column path")
        columns[field] = mapped
    output: dict[str, dict] = {}
    count = 0
    for row_number, raw in _read_rows(Path(path), source_id, delimiter):
        count += 1
        if count > max_rows:
            _fail("row_limit", "Feed exceeds max_rows; select a smaller complete approved catalog or use a future staging importer", row_number)
        if not isinstance(raw, dict):
            _fail("invalid_row", "Each record must be an object", row_number)
        _validate_node(raw, row_number)
        values = {key: _lookup(raw, mapped) for key, mapped in columns.items()}
        def value(key, **kwargs):
            return _scalar(values.get(key), key, row_number, **kwargs)

        row_catalog = value("catalog_id", limit=256)
        if row_catalog is not None and row_catalog != catalog_id:
            _fail("catalog_mismatch", "Record belongs to a different catalog", row_number)
        row_merchant = value("merchant_id", limit=256)
        if merchant_id and row_merchant and merchant_id != row_merchant:
            _fail("merchant_mismatch", "Record advertiser differs from the approved merchant context", row_number)
        advertiser = row_merchant or merchant_id
        row_name = value("merchant_name", limit=300)
        if merchant_name and row_name and merchant_name != row_name:
            _fail("merchant_mismatch", "Record merchant name differs from the approved merchant context", row_number)
        name = row_name or merchant_name
        if not advertiser or not name:
            _fail("missing_merchant", "A sourced or explicit merchant ID and name are required; brand is not merchant identity", row_number)
        row_currency = _currency(values.get("currency"), row_number)
        if currency and row_currency and currency != row_currency:
            _fail("currency_mismatch", "Record currency differs from the approved catalog context", row_number)
        offer_currency = row_currency or currency
        external_id = value("product_id", required=True, limit=256)
        variant = value("variant_id", limit=256)
        namespace = json.dumps([source_id, catalog_id, advertiser, external_id, variant], ensure_ascii=False, separators=(",", ":"))
        record_id = f"{source_id}:" + hashlib.sha256(namespace.encode()).hexdigest()
        availability_raw = value("availability")
        availability = {"in stock": "in_stock", "in_stock": "in_stock", "out of stock": "out_of_stock", "out_of_stock": "out_of_stock"}.get((availability_raw or "").lower(), "unknown")
        attributes = {key: result for key in ATTRIBUTE_FIELDS if (result := value(key)) is not None}
        if availability_raw is not None:
            attributes["source_availability"] = availability_raw
        item = {
            "source_id": source_id, "source_record_id": record_id,
            "product_key": record_id, "variant_key": variant,
            "title": value("title", required=True, limit=500),
            "description": value("description"), "category": value("category", limit=1000),
            "brand": value("brand", limit=300), "attributes": attributes,
            "merchant": {"id": advertiser, "name": name, "platform": source_id},
            "offer": {
                "id": record_id, "price_minor": price_to_minor(values.get("price"), offer_currency, row=row_number),
                "currency": offer_currency, "shipping_minor": None, "availability": availability,
                "condition": value("condition", limit=100),
                "url": _public_url(values.get("url"), "url", row_number),
                "image_url": _public_url(values.get("image_url"), "image_url", row_number, image=True),
                "observed_at": float(now), "expires_at": None,
                "marketplace_id": None, "environment": "production",
            },
            "provenance": {
                "catalog_id": catalog_id, "source_record_id": external_id,
                "advertiser_id": advertiser, "external_product_id": external_id,
                "external_variant_id": variant,
                "source_updated_at": _source_timestamp(values.get("source_updated_at"), row_number),
            },
        }
        if record_id in output and output[record_id] != item:
            _fail("duplicate_conflict", "Conflicting records share the same source identity", row_number)
        output[record_id] = item
    if not count:
        _fail("empty_feed", "Empty feeds cannot be used as a replacement catalog")
    return list(output.values())


def list_cj_catalogs(
    personal_access_token: str, company_id: str, partner_ids: list[str], *,
    limit: int = 100, offset: int = 1, transport: httpx.BaseTransport | None = None,
) -> dict:
    """Fetch one feed-summary page from CJ; visibility does not establish rights.

    No product imports, subscriptions or automatic pagination. Callers must select
    merchant-approved feeds and persist rights separately before importing them.
    """
    if (not personal_access_token or "\r" in personal_access_token or "\n" in personal_access_token
            or len(personal_access_token) > 8192):
        _fail("invalid_credentials", "A valid CJ personal access token is required")
    if not isinstance(company_id, str) or not re.fullmatch(r"\d{1,30}", company_id):
        _fail("invalid_company", "company_id must be a CJ numeric company identifier")
    if (not partner_ids or len(partner_ids) > 100 or any(not isinstance(p, str) or not re.fullmatch(r"\d{1,30}", p) for p in partner_ids)):
        _fail("invalid_partner", "Supply 1–100 explicit CJ advertiser company identifiers")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 1000 or isinstance(offset, bool) or not isinstance(offset, int) or not 1 <= offset <= 1000000:
        _fail("invalid_limit", "Invalid CJ summary page limit or offset")
    # Argument types are explicitly documented in CJ's productFeeds table:
    # https://docs.cj.com/docs/productfeed-api-search-query#productfeeds
    query = """query($companyId: ID!, $partnerIds: [ID!], $limit: Int, $offset: Int) {
      productFeeds(companyId: $companyId, partnerIds: $partnerIds, limit: $limit, offset: $offset) {
        totalCount count resultList {
          adId feedName advertiserId advertiserName productCount lastUpdated currency sourceFeedType
        }
      }
    }"""
    try:
        with httpx.Client(timeout=httpx.Timeout(15.0), follow_redirects=False, trust_env=False, transport=transport) as client:
            with client.stream("POST", CJ_ENDPOINT, headers={"Authorization": f"Bearer {personal_access_token}", "Accept": "application/json"},
                               json={"query": query, "variables": {"companyId": company_id, "partnerIds": partner_ids, "limit": limit, "offset": offset}}) as response:
                if response.status_code in {401, 403}:
                    _fail("upstream_auth", "CJ rejected the credentials or account permission")
                if response.status_code == 429:
                    _fail("upstream_rate_limit", "CJ rate limit reached; retry later")
                if not 200 <= response.status_code < 300:
                    _fail("upstream_error", "CJ feed-summary request failed")
                raw = bytearray()
                for chunk in response.iter_bytes():
                    raw.extend(chunk)
                    if len(raw) > 2 * 1024 * 1024:
                        _fail("upstream_limit", "CJ feed-summary response exceeds the size limit")
        result = json.loads(raw, object_pairs_hook=_json_object)
    except httpx.HTTPError:
        _fail("upstream_unavailable", "CJ feed-summary request is unavailable")
    except (ValueError, UnicodeError, RecursionError) as error:
        if isinstance(error, AffiliateFeedError):
            raise
        _fail("upstream_schema", "CJ feed-summary response is not valid JSON")
    if not isinstance(result, dict) or result.get("errors"):
        _fail("upstream_error", "CJ returned GraphQL errors; partial results were rejected")
    data = result.get("data")
    feeds = data.get("productFeeds") if isinstance(data, dict) else None
    if not isinstance(feeds, dict) or not isinstance(feeds.get("resultList"), list) or len(feeds["resultList"]) > limit:
        _fail("upstream_schema", "CJ feed-summary response has an unexpected structure")
    for number, record in enumerate(feeds["resultList"], 1):
        if not isinstance(record, dict):
            _fail("upstream_schema", "CJ feed summary must be an object")
        _validate_node(record, number)
    return feeds
