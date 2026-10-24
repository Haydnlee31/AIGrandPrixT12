"""Offline streaming metadata adapters for reviewed public datasets.

No URLs are fetched and no source text is interpreted as an instruction.  These
adapters preserve product facts while leaving current commercial offers unknown.
The admission layer owns source licensing, atomic replacement and duplicate IDs.
"""
from __future__ import annotations

from contextlib import contextmanager
from html.parser import HTMLParser
import json
import math
import os
from pathlib import Path
import stat
import unicodedata
from urllib.parse import urlsplit


MAX_LINE_BYTES = 2 * 1024 * 1024
MAX_NORTHWIND_BYTES = 32 * 1024 * 1024
MAX_ROWS = 1_000_000
MAX_UCI_RECORDS = 50_000
_FACTS = {
    "open_beauty_facts": "openbeautyfacts.org",
    "open_products_facts": "openproductsfacts.org",
    "open_food_facts": "openfoodfacts.org",
}
_UCI_URL = "https://archive.ics.uci.edu/dataset/352/online+retail"
_UCI_DOWNLOAD = "https://archive.ics.uci.edu/static/public/352/online+retail.zip"
_NORTHWIND_URL = "https://github.com/microsoft/sql-server-samples/tree/master/samples/databases/northwind-pubs"
_NORTHWIND_DOWNLOAD = "https://raw.githubusercontent.com/microsoft/sql-server-samples/master/samples/databases/northwind-pubs/instnwnd.sql"
_ADVENTUREWORKS_URL = "https://github.com/microsoft/sql-server-samples/releases/tag/adventureworks"
_ADVENTUREWORKS_DOWNLOAD = "https://github.com/microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks-oltp-install-script.zip"


class DomainDatasetError(ValueError):
    """Safe diagnostics: never include raw record values or file contents."""

    def __init__(self, code: str, message: str, row: int | None = None):
        self.code, self.row = code, row
        super().__init__(message + (f" (row {row})" if row is not None else ""))


class _PlainText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.suppressed = 0

    def handle_starttag(self, tag, attrs):
        if tag in {"script", "style", "template"}:
            self.suppressed += 1
        elif tag in {"br", "p", "div", "li", "tr", "td", "h1", "h2", "h3"} and not self.suppressed:
            self.parts.append(" ")

    def handle_endtag(self, tag):
        if tag in {"script", "style", "template"} and self.suppressed:
            self.suppressed -= 1
        elif tag in {"p", "div", "li", "tr", "td"} and not self.suppressed:
            self.parts.append(" ")

    def handle_data(self, data):
        if not self.suppressed:
            self.parts.append(data)


def _text(value, limit):
    if value is None:
        return None
    if type(value) not in {str, int, float} or (type(value) is float and not math.isfinite(value)):
        return None
    raw = str(value)
    # Parsing remains bounded even when an unused source field is excessive.
    raw = raw[:100_000]
    parser = _PlainText()
    parser.feed(raw)
    parser.close()
    content = "".join(parser.parts)
    # Strip bidi/zero-width controls, control characters and lone surrogates.
    content = "".join(" " if char.isspace() else char for char in content if not unicodedata.category(char).startswith("C") or char.isspace())
    content = " ".join(content.split())[:limit].strip()
    return content or None


def _identifier(value, row):
    # Truncating identifiers could silently merge records; reject instead.
    if type(value) not in {str, int}:
        raise DomainDatasetError("invalid_identity", "A source product identifier is required", row)
    result = str(value).strip()
    if not result or len(result) > 1024 or any(unicodedata.category(char).startswith("C") for char in result):
        raise DomainDatasetError("invalid_identity", "Invalid source product identifier", row)
    return result


def _bounded_attributes(values):
    result = {key: value for key, value in values.items() if value is not None}
    # ensure_ascii matches the public schema's serialized metadata accounting.
    while len(json.dumps(result, allow_nan=False)) > 30000:
        candidates = [(len(value), key) for key, value in result.items() if isinstance(value, str) and value]
        if not candidates:
            arrays = [(len(value), key) for key, value in result.items() if isinstance(value, list) and value]
            if not arrays:
                raise DomainDatasetError("metadata_limit", "Source metadata exceeds its size limit")
            size, key = max(arrays)
            result[key] = result[key][:size // 2]
        else:
            size, key = max(candidates)
            result[key] = result[key][:size // 2]
        result["metadata_truncated"] = True
    return result


def _base(source_id, record_id, title, *, data_kind="open_dataset"):
    if title is None:
        raise DomainDatasetError("missing_title", "A usable product title is required")
    return {
        "source_id": source_id, "source_record_id": record_id, "data_kind": data_kind,
        "title": title, "description": None, "category": None, "brand": None,
        "attributes": {}, "product_key": None, "variant_key": None,
        "merchant": {"id": None, "name": None, "platform": source_id},
        "offer": {
            "id": record_id, "price_minor": None, "currency": None,
            "shipping_minor": None, "availability": "unknown", "condition": None,
            "url": None, "image_url": None, "observed_at": None, "expires_at": None,
            "marketplace_id": None, "environment": "local",
        },
        "provenance": {},
    }


def _facts(source_id, raw, row):
    code = _identifier(raw.get("code"), row)
    result = _base(source_id, code, _text(raw.get("product_name"), 1000))
    result["description"] = _text(raw.get("generic_name"), 20000)
    result["category"] = _text(raw.get("categories"), 2048)
    result["brand"] = _text(raw.get("brands"), 512)
    result["attributes"] = _bounded_attributes({
        "source_barcode": code,
        "source_stores": _text(raw.get("stores"), 3000),
        "source_countries": _text(raw.get("countries"), 2000),
        "quantity": _text(raw.get("quantity"), 1000),
        "ingredients_text": _text(raw.get("ingredients_text"), 3000),
    })
    domain = _FACTS[source_id]
    # Source URLs are attribution, never merchant purchase links. Only retain
    # an official domain and omit any user-supplied query/fragment/credentials.
    source_url = f"https://world.{domain}"
    candidate = raw.get("url")
    if isinstance(candidate, str) and len(candidate) <= 4096 and not any(c.isspace() or unicodedata.category(c).startswith("C") for c in candidate):
        try:
            parsed = urlsplit(candidate)
            host = (parsed.hostname or "").lower()
            if (parsed.scheme in {"http", "https"} and parsed.username is None and parsed.password is None
                    and parsed.port in {None, 80, 443} and "\\" not in candidate
                    and (host == domain or host.endswith("." + domain))):
                source_url = parsed._replace(scheme="https", query="", fragment="").geturl()
        except ValueError:
            pass
    result["provenance"] = {
        "source_record_id": code, "source_url": source_url,
        "download_url": f"https://static.{domain}/data/en.{domain}.products.csv.gz",
        "source_modified_at": _text(raw.get("last_modified_t"), 40),
        "images_excluded": True,
    }
    return result


def _uci(raw, row):
    source_id = "uci_retail"
    record_id = _identifier(raw.get("source_record_id"), row)
    result = _base(source_id, record_id, _text(raw.get("title"), 1000))
    # Original invoice/customer/date fields never cross this projection.
    result["attributes"] = _bounded_attributes({
        "historical_stock_code": record_id,
        "historical_unit_price": _text(raw.get("historical_unit_price"), 100),
        "historical_price_currency": "GBP" if raw.get("currency") == "GBP" else None,
        "historical_only": True,
    })
    source_url, download_url = _UCI_URL, _UCI_DOWNLOAD
    if raw.get("source_url") == "https://archive.ics.uci.edu/dataset/502/online+retail+ii":
        source_url = raw["source_url"]
        download_url = "https://archive.ics.uci.edu/static/public/502/online+retail+ii.zip"
    result["provenance"] = {"source_record_id": record_id, "source_url": source_url, "download_url": download_url}
    return result


def _uci_records(path):
    """Collapse whitespace SKU aliases only within this small historical source.

    UCI's extracted product file can retain both a padded and unpadded stockcode.
    Aggregate before yielding so a later alias cannot silently replace a product
    already published. All other source adapters preserve duplicates for the
    atomic importer to reject. Distinct historical prices remain observations.
    """
    groups = {}
    inspected = 0
    for row, raw in _jsonl(path):
        inspected += 1
        if inspected > MAX_UCI_RECORDS:
            raise DomainDatasetError("row_limit", "UCI product projection exceeds its 50000-record aggregation limit", row)
        if _text(raw.get("title"), 1000) is None:
            continue
        record = _uci(raw, row)
        canonical_id = record["source_record_id"]
        raw_id = str(raw["source_record_id"])
        if len(raw_id) > 1024 or any(unicodedata.category(char).startswith("C") for char in raw_id):
            raise DomainDatasetError("invalid_identity", "Invalid original UCI source identifier", row)
        price = (record["attributes"].get("historical_unit_price"), record["attributes"].get("historical_price_currency"))
        group = groups.get(canonical_id)
        if group is None:
            groups[canonical_id] = {"record": record, "raw_ids": {raw_id}, "prices": {price}, "count": 1}
            continue
        existing = group["record"]
        if record["title"] != existing["title"] or record["provenance"] != existing["provenance"]:
            raise DomainDatasetError("duplicate_conflict", "UCI aliases have conflicting titles or dataset provenance", row)
        group["raw_ids"].add(raw_id)
        group["prices"].add(price)
        group["count"] += 1
        if len(group["raw_ids"]) > 32 or len(group["prices"]) > 64:
            raise DomainDatasetError("metadata_limit", "Too many UCI alias or price observations", row)
    for canonical_id in sorted(groups):
        group = groups[canonical_id]
        record = group["record"]
        if group["count"] > 1:
            record["provenance"].update({
                "source_identifiers": sorted(group["raw_ids"]),
                "merged_source_record_count": group["count"],
                "normalization": "whitespace_stockcode_aliases",
            })
            if len(json.dumps(record["provenance"])) > 30000:
                raise DomainDatasetError("metadata_limit", "UCI alias provenance exceeds its size limit")
            if len(group["prices"]) > 1:
                # Do not choose one historical price when aliases disagree.
                record["attributes"].pop("historical_unit_price", None)
                record["attributes"].pop("historical_price_currency", None)
                record["attributes"]["historical_price_observations"] = [
                    {"unit_price": price, "currency": currency}
                    for price, currency in sorted(group["prices"], key=lambda pair: (pair[0] or "", pair[1] or ""))
                ]
        yield record


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise DomainDatasetError("duplicate_field", "Duplicate JSON object fields are not supported")
        result[key] = value
    return result


def _invalid_constant(_):
    raise DomainDatasetError("invalid_json", "Nonfinite JSON values are not supported")


def _decode(data, row=None):
    try:
        return json.loads(data, object_pairs_hook=_object, parse_constant=_invalid_constant)
    except (json.JSONDecodeError, UnicodeError, RecursionError):
        raise DomainDatasetError("invalid_json", "Input must contain bounded valid UTF-8 JSON", row) from None


@contextmanager
def _file(path):
    try:
        handle = os.fdopen(os.open(Path(path), os.O_RDONLY | os.O_NONBLOCK), "rb")
    except OSError:
        raise DomainDatasetError("invalid_file", "Unable to open the local dataset file") from None
    with handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            raise DomainDatasetError("invalid_file", "Dataset must be a regular local file")
        yield handle


def _jsonl(path):
    with _file(path) as handle:
        line_number = count = 0
        while True:
            line = handle.readline(MAX_LINE_BYTES + 1)
            if not line:
                break
            line_number += 1
            if len(line) > MAX_LINE_BYTES:
                raise DomainDatasetError("row_limit", "Dataset row exceeds its byte limit", line_number)
            if line_number == 1:
                line = line.removeprefix(b"\xef\xbb\xbf")
            if not line.strip():
                continue
            count += 1
            if count > MAX_ROWS:
                raise DomainDatasetError("row_limit", "Dataset exceeds one million records", line_number)
            record = _decode(line, line_number)
            if not isinstance(record, dict):
                raise DomainDatasetError("invalid_record", "Each JSONL row must be an object", line_number)
            yield line_number, record


def _northwind(path):
    with _file(path) as handle:
        data = handle.read(MAX_NORTHWIND_BYTES + 1)
    if len(data) > MAX_NORTHWIND_BYTES:
        raise DomainDatasetError("file_limit", "Northwind export exceeds its 32 MiB limit")
    payload = _decode(data)
    if not isinstance(payload, dict) or any(not isinstance(payload.get(key), list) for key in ("Products", "Suppliers", "Categories")):
        raise DomainDatasetError("invalid_record", "Northwind requires Products, Suppliers and Categories arrays")
    if any(len(payload[key]) > MAX_ROWS for key in ("Products", "Suppliers", "Categories")):
        raise DomainDatasetError("row_limit", "Northwind array exceeds its record limit")

    def lookup(key, identity_key):
        result = {}
        for index, raw in enumerate(payload[key], 1):
            if not isinstance(raw, dict):
                raise DomainDatasetError("invalid_record", "Northwind records must be objects", index)
            record_id = _identifier(raw.get(identity_key), index)
            if record_id in result:
                raise DomainDatasetError("duplicate_identity", "Duplicate Northwind lookup identity", index)
            result[record_id] = raw
        return result

    suppliers = lookup("Suppliers", "SupplierID")
    categories = lookup("Categories", "CategoryID")
    for index, raw in enumerate(payload["Products"], 1):
        if not isinstance(raw, dict):
            raise DomainDatasetError("invalid_record", "Northwind products must be objects", index)
        record_id = _identifier(raw.get("ProductID"), index)
        result = _base("northwind", record_id, _text(raw.get("ProductName"), 1000), data_kind="synthetic")
        supplier_id = _identifier(raw["SupplierID"], index) if raw.get("SupplierID") is not None else None
        category_id = _identifier(raw["CategoryID"], index) if raw.get("CategoryID") is not None else None
        supplier, category = suppliers.get(supplier_id, {}), categories.get(category_id, {})
        result["category"] = _text(category.get("CategoryName"), 2048)
        result["description"] = _text(category.get("Description"), 20000)
        result["attributes"] = _bounded_attributes({
            "fictional_supplier_id": supplier_id,
            "fictional_supplier_name": _text(supplier.get("CompanyName"), 512),
            "fictional_supplier_country": _text(supplier.get("Country"), 512),
            "quantity_per_unit": _text(raw.get("QuantityPerUnit"), 1000),
            "synthetic_reference_unit_price": _text(raw.get("UnitPrice"), 100),
            "synthetic_reference_units_in_stock": _text(raw.get("UnitsInStock"), 100),
            "synthetic_reference_discontinued": _text(raw.get("Discontinued"), 100),
            "reference_currency_unknown": True,
        })
        result["provenance"] = {"source_record_id": record_id, "source_url": _NORTHWIND_URL, "download_url": _NORTHWIND_DOWNLOAD}
        yield result


def _adventureworks(path):
    """Read the three reviewed SQL-sample projections; suppliers stay fictional."""
    path = Path(path)
    tables = {}
    for name in ("product", "vendor", "productvendor"):
        with _file(path / f"{name}.json") as handle:
            data = handle.read(MAX_NORTHWIND_BYTES + 1)
        if len(data) > MAX_NORTHWIND_BYTES:
            raise DomainDatasetError("file_limit", "AdventureWorks table exceeds its 32 MiB limit")
        rows = _decode(data)
        if not isinstance(rows, list) or len(rows) > MAX_ROWS or any(not isinstance(row, dict) for row in rows):
            raise DomainDatasetError("invalid_record", "AdventureWorks tables must be bounded arrays of objects")
        tables[name] = rows
    vendors = {}
    for index, raw in enumerate(tables["vendor"], 1):
        identity = _identifier(raw.get("BusinessEntityID"), index)
        if identity in vendors:
            raise DomainDatasetError("duplicate_identity", "Duplicate AdventureWorks vendor identity", index)
        vendors[identity] = raw
    relations = {}
    seen = set()
    for index, raw in enumerate(tables["productvendor"], 1):
        product_id = _identifier(raw.get("ProductID"), index)
        vendor_id = _identifier(raw.get("BusinessEntityID"), index)
        if (product_id, vendor_id) in seen:
            raise DomainDatasetError("duplicate_identity", "Duplicate AdventureWorks product/vendor relationship", index)
        seen.add((product_id, vendor_id))
        if vendor_id not in vendors:
            raise DomainDatasetError("unknown_supplier", "AdventureWorks relationship references an unknown supplier", index)
        relations.setdefault(product_id, []).append({
            "supplier_id": vendor_id, "supplier_name": _text(vendors[vendor_id].get("Name"), 512),
            "synthetic_standard_price": _text(raw.get("StandardPrice"), 100),
            "unit_measure_code": _text(raw.get("UnitMeasureCode"), 100),
        })
    for index, raw in enumerate(tables["product"], 1):
        identity = _identifier(raw.get("ProductID"), index)
        result = _base("adventureworks", identity, _text(raw.get("Name"), 1000), data_kind="synthetic")
        suppliers = relations.get(identity, [])
        result["variant_key"] = _text(raw.get("ProductNumber"), 1024)
        result["attributes"] = _bounded_attributes({
            "source_product_number": _text(raw.get("ProductNumber"), 1024),
            "color": _text(raw.get("Color"), 512), "size": _text(raw.get("Size"), 512),
            "size_unit": _text(raw.get("SizeUnitMeasureCode"), 100),
            "weight": _text(raw.get("Weight"), 100), "weight_unit": _text(raw.get("WeightUnitMeasureCode"), 100),
            "source_subcategory_id": _text(raw.get("ProductSubcategoryID"), 100),
            "source_model_id": _text(raw.get("ProductModelID"), 100),
            "fictional_suppliers": suppliers[:16], "source_supplier_relationship_count": len(suppliers),
            "supplier_relationships_truncated": len(suppliers) > 16,
            "synthetic_reference_list_price": _text(raw.get("ListPrice"), 100),
            "reference_currency_unknown": True,
            "source_finished_goods_flag": _text(raw.get("FinishedGoodsFlag"), 20),
        })
        result["provenance"] = {"source_record_id": identity, "source_url": _ADVENTUREWORKS_URL, "download_url": _ADVENTUREWORKS_DOWNLOAD}
        yield result


def iter_domain(source_id: str, path: str | Path):
    """Yield schema-shaped records; source-product duplicate checks stay upstream.

    Open Facts input is JSONL, streamed one bounded row at a time. UCI's small
    JSONL product projection aggregates only compatible whitespace SKU aliases.
    Northwind is the extracted Products/Suppliers/Categories JSON object. Other
    duplicate product identities remain visible to the atomic importer.
    """
    if source_id == "northwind":
        yield from _northwind(path)
    elif source_id == "adventureworks":
        yield from _adventureworks(path)
    elif source_id == "uci_retail":
        yield from _uci_records(path)
    elif source_id in _FACTS:
        for row, raw in _jsonl(path):
            # A raw nonempty name can contain only markup/control characters.
            # Such rows have no usable display title; never fabricate one.
            if _text(raw.get("product_name"), 1000) is None:
                continue
            yield _facts(source_id, raw, row)
    else:
        raise DomainDatasetError("unsupported_source", "Unsupported domain dataset source")
