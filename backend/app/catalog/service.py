"""Atomic, operator-owned affiliate snapshots and deterministic read-only retrieval."""
import hashlib
import json
import math
import time
import re

from sqlalchemy import delete, func, insert, select

from ..db import CatalogFeed, CatalogImport, CatalogMerchant, CatalogOffer, CatalogProduct, uid
from .schemas import CatalogRecord
from .registry import DATASET_SOURCES, SOURCES
from .search_index import matching_product_ids


class CatalogError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


def identity(*parts):
    return hashlib.sha256(json.dumps(parts, ensure_ascii=False).encode()).hexdigest()


def _begin_write(db):
    if db.bind.dialect.name == "sqlite":
        db.connection().exec_driver_sql("BEGIN IMMEDIATE")


def import_snapshot(factory, source_id, catalog_id, records, *, approval_reference,
                    source_observed_at, freshness_seconds=86400, now=None):
    """Replace one complete feed snapshot; caller attests approved display/search.

    Validate everything before touching DB. A replay never renews freshness.
    Old rows disappear atomically; no cross-feed/merchant identity inference.
    """
    now = time.time() if now is None else now
    if source_id not in {"impact", "cj"}:
        raise CatalogError("source_not_importable", "Only approved impact or CJ feeds may be persisted")
    if not isinstance(catalog_id, str) or not catalog_id.strip() or len(catalog_id) > 512:
        raise CatalogError("invalid_catalog", "A catalog ID of 1–512 characters is required")
    if not isinstance(approval_reference, str) or not approval_reference.strip() or len(approval_reference) > 2000:
        raise CatalogError("approval_required", "Record the merchant approval or agreement reference")
    if (not isinstance(source_observed_at, (float, int)) or isinstance(source_observed_at, bool)
            or not math.isfinite(source_observed_at) or source_observed_at < 0 or source_observed_at > now
            or type(freshness_seconds) is not int or not 60 <= freshness_seconds <= 86400):
        raise CatalogError("invalid_freshness", "Use a source observation time no later than now and a 60–86400 second freshness window")
    expires_at = source_observed_at + freshness_seconds
    if expires_at <= now:
        raise CatalogError("expired_feed", "The source snapshot has expired; obtain a fresh export")
    if not isinstance(records, list) or not 1 <= len(records) <= 10000:
        raise CatalogError("invalid_feed_size", "Import a complete snapshot containing 1–10000 records")
    normalized, seen, merchants = [], set(), {}
    for raw in records:
        if not isinstance(raw, dict) or not isinstance(raw.get("offer"), dict):
            raise CatalogError("invalid_record", "Each row must contain a normalized offer")
        data = {**raw, "offer": {**raw["offer"], "observed_at": source_observed_at, "expires_at": expires_at}}
        record = CatalogRecord.model_validate(data)
        if record.data_kind != "merchant_feed" or not record.offer.url:
            raise CatalogError("invalid_feed_record", "Approved merchant feeds require a merchant link and merchant_feed data kind")
        if record.source_id != source_id or str(record.provenance.get("catalog_id")) != catalog_id:
            raise CatalogError("source_mismatch", "Every row must belong to the selected source and catalog")
        if record.offer.environment != "production" or not record.merchant.id or not record.merchant.name:
            raise CatalogError("invalid_merchant", "Affiliate rows require a sourced merchant ID and name")
        if record.source_record_id in seen:
            raise CatalogError("duplicate_record", "Duplicate source record IDs are not allowed")
        merchant = record.merchant.model_dump()
        if merchant["id"] in merchants and merchants[merchant["id"]] != merchant:
            raise CatalogError("conflicting_merchant", "A merchant ID has conflicting names within this snapshot")
        merchants[merchant["id"]] = merchant
        seen.add(record.source_record_id)
        normalized.append(record.model_dump())
    normalized.sort(key=lambda row: row["source_record_id"])
    digest = identity(normalized, approval_reference)
    feed_id = identity(source_id, catalog_id)
    with factory.begin() as db:
        _begin_write(db)
        # Stable feed row serializes replacements on PostgreSQL too.
        feed = db.scalar(select(CatalogFeed).where(CatalogFeed.id == feed_id).with_for_update())
        if feed is None:
            feed = CatalogFeed(id=feed_id, source_id=source_id, catalog_id=catalog_id,
                               approval_reference=approval_reference, enabled=True)
            db.add(feed)
            db.flush()
        previous = db.get(CatalogImport, feed.last_import_id) if feed.last_import_id else None
        if previous and source_observed_at < previous.source_observed_at:
            raise CatalogError("older_snapshot", "An older source export cannot replace the current snapshot")
        if previous and digest == previous.digest:
            if not feed.enabled:
                raise CatalogError("feed_revoked", "A revoked feed needs a new approved snapshot to reactivate")
            return {"import_id": previous.id, "row_count": previous.row_count, "unchanged": True, "expires_at": previous.expires_at}
        run = CatalogImport(id=uid(), feed_id=feed_id, digest=digest, approval_reference=approval_reference,
                            imported_at=now, source_observed_at=source_observed_at, expires_at=expires_at, row_count=len(normalized))
        db.add(run)
        db.flush()
        product_ids = select(CatalogProduct.id).where(CatalogProduct.feed_id == feed_id)
        db.execute(delete(CatalogOffer).where(CatalogOffer.product_id.in_(product_ids)))
        db.execute(delete(CatalogProduct).where(CatalogProduct.feed_id == feed_id))
        db.execute(delete(CatalogMerchant).where(CatalogMerchant.feed_id == feed_id))
        for merchant in merchants.values():
            db.add(CatalogMerchant(id=identity(feed_id, merchant["id"]), feed_id=feed_id,
                                  external_id=merchant["id"], name=merchant["name"], platform=source_id))
        db.flush()
        for record in normalized:
            product_id = identity(feed_id, record["source_record_id"])
            offer = record["offer"]
            search_text = " ".join(str(record.get(key) or "") for key in ("title", "description", "category", "brand")).casefold()
            db.add(CatalogProduct(id=product_id, feed_id=feed_id, import_id=run.id,
                                  source_record_id=record["source_record_id"], product_key=record["product_key"], variant_key=record["variant_key"],
                                  title=record["title"], search_text=search_text, record=record))
        db.flush()
        for record in normalized:
            product_id = identity(feed_id, record["source_record_id"])
            offer = record["offer"]
            db.add(CatalogOffer(id=identity(product_id, offer["id"]), product_id=product_id,
                                merchant_id=identity(feed_id, record["merchant"]["id"]), price_minor=offer["price_minor"],
                                currency=offer["currency"], availability=offer["availability"],
                                observed_at=source_observed_at, expires_at=expires_at))
        feed.approval_reference, feed.enabled, feed.last_import_id = approval_reference, True, run.id
        return {"import_id": run.id, "row_count": len(normalized), "unchanged": False, "expires_at": expires_at}


def revoke_feed(factory, source_id, catalog_id):
    """Immediately remove a feed from retrieval and purge stored product content."""
    with factory.begin() as db:
        _begin_write(db)
        feed = db.scalar(select(CatalogFeed).where(CatalogFeed.id == identity(source_id, catalog_id)).with_for_update())
        if feed is None:
            raise CatalogError("feed_not_found", "This source/catalog has not been imported")
        feed.enabled = False
        products = select(CatalogProduct.id).where(CatalogProduct.feed_id == feed.id)
        db.execute(delete(CatalogOffer).where(CatalogOffer.product_id.in_(products)))
        db.execute(delete(CatalogProduct).where(CatalogProduct.feed_id == feed.id))
        db.execute(delete(CatalogMerchant).where(CatalogMerchant.feed_id == feed.id))


def search_feed(db, source_id, query, limit=20, offset=0, now=None):
    now = time.time() if now is None else now
    source = SOURCES.get(source_id)
    if source is None:
        raise CatalogError("unknown_catalog_source", "Choose a source returned by /v1/commerce/sources")
    enabled = db.scalar(select(func.count()).select_from(CatalogFeed).where(CatalogFeed.source_id == source_id, CatalogFeed.enabled.is_(True)))
    if not enabled:
        raise CatalogError("catalog_not_configured", "No catalog has been imported for this source")
    query_terms = query.casefold().split()
    selection = visible_records(source_id, now)
    # SQLite uses a local token-prefix index for supported queries; punctuation
    # and other backends preserve the escaped substring fallback.
    indexed_ids = matching_product_ids(db, query)
    if indexed_ids is not None:
        selection = selection.where(CatalogProduct.id.in_(indexed_ids))
    else:
        for term in query_terms:
            selection = selection.where(CatalogProduct.search_text.contains(term, autoescape=True))
    total = db.scalar(select(func.count()).select_from(selection.subquery()))
    rows = db.scalars(selection.order_by(CatalogProduct.id).offset(offset).limit(limit)).all()
    items = [row.record for row in rows]
    return {"items": items, "source_id": source_id, "total": total,
            "next_offset": offset + limit if offset + limit < min(total, 1000000) else None,
            "fetched_at": now, "expires_at": min((row["offer"]["expires_at"] for row in items if row["offer"]["expires_at"] is not None), default=None),
            "environment": "production" if source.kind == "merchant_feed" else "local", "marketplace": None,
            "retrieval": "approved_feed" if source.kind == "merchant_feed" else "local_dataset"}


def source_status(db, now=None):
    now = time.time() if now is None else now
    items = []
    for source_id, source in SOURCES.items():
        feeds = db.scalar(select(func.count()).select_from(CatalogFeed).where(CatalogFeed.source_id == source_id, CatalogFeed.enabled.is_(True)))
        count = db.scalar(select(func.count()).select_from(visible_records(source_id, now).subquery()))
        items.append({"source_id": source_id, "configured": feeds > 0, "enabled_feeds": feeds,
                      "record_count": count, "fresh_records": count if source.kind == "merchant_feed" else None,
                      "data_kind": source.kind, "name": source.name, "license_id": source.license_id,
                      "license_url": source.license_url, "attribution": source.attribution,
                      "environment": "production" if source.kind == "merchant_feed" else "local", "marketplace": None,
                      "retrieval": "approved_feed" if source.kind == "merchant_feed" else "local_dataset",
                      "allowed_uses": ["direct_display", "deterministic_search"] if feeds else [],
                      "ai_use": "disabled", "persistence": "approved_snapshot" if source.kind == "merchant_feed" else "synthetic" if source.kind == "synthetic" else "licensed_dataset"})
    return {"items": items}


def visible_records(source_id, now=None):
    now = time.time() if now is None else now
    source = SOURCES.get(source_id)
    if source is None:
        raise CatalogError("unknown_catalog_source", "Choose a registered source")
    query = select(CatalogProduct).join(CatalogFeed).where(
        CatalogFeed.source_id == source_id, CatalogFeed.enabled.is_(True))
    if source.kind == "merchant_feed":
        query = query.join(CatalogOffer).where(CatalogOffer.expires_at > now)
    return query


def get_record(db, source_id, record_id):
    row = db.scalar(visible_records(source_id).where(CatalogProduct.source_record_id == record_id))
    if row is None:
        raise CatalogError("catalog_record_not_found", "Record is missing, expired or withdrawn")
    return row.record


def import_dataset(factory, source_id, records, *, version, checksum, now=None, expected_count=None):
    """Stream a complete reviewed dataset into an atomic source-scoped snapshot.

    Historical source metadata never becomes a current offer. Unknown merchants
    remain NULL. Import identity includes source bytes and normalization version.
    """
    source = DATASET_SOURCES.get(source_id)
    if source is None:
        raise CatalogError("source_not_importable", "This is not a registered local dataset source")
    if not isinstance(version, str) or not 1 <= len(version) <= 200 or not re.fullmatch(r"[a-f0-9]{64}", checksum or ""):
        raise CatalogError("invalid_dataset_version", "Provide a bounded version and SHA256 source checksum")
    if expected_count is not None and (type(expected_count) is not int or not 1 <= expected_count <= 1000000):
        raise CatalogError("invalid_dataset_count", "Expected record count must be between one and one million")
    now = time.time() if now is None else now
    catalog_id, feed_id = "local-dataset", identity(source_id, "local-dataset")
    digest = identity(source_id, version, checksum, "normalized-catalog-v2", source.license_id, source.license_url, source.attribution)
    with factory.begin() as db:
        _begin_write(db)
        feed = db.scalar(select(CatalogFeed).where(CatalogFeed.id == feed_id).with_for_update())
        if feed is None:
            feed = CatalogFeed(id=feed_id, source_id=source_id, catalog_id=catalog_id,
                               approval_reference=source.license_id, enabled=True)
            db.add(feed)
            db.flush()
        previous = db.get(CatalogImport, feed.last_import_id) if feed.last_import_id else None
        if previous and previous.digest == digest:
            if expected_count is not None and previous.row_count != expected_count:
                raise CatalogError("dataset_count_mismatch", "The source does not match the bundle's expected count")
            if not feed.enabled:
                raise CatalogError("feed_revoked", "Use a new reviewed dataset version to reactivate a revoked source")
            return {"import_id": previous.id, "row_count": previous.row_count, "unchanged": True, "source_id": source_id}
        run = CatalogImport(id=uid(), feed_id=feed_id, digest=digest, approval_reference=source.license_id,
                            imported_at=now, source_observed_at=now, expires_at=None, row_count=0)
        db.add(run)
        db.flush()
        old = select(CatalogProduct.id).where(CatalogProduct.feed_id == feed_id)
        db.execute(delete(CatalogOffer).where(CatalogOffer.product_id.in_(old)))
        db.execute(delete(CatalogProduct).where(CatalogProduct.feed_id == feed_id))
        db.execute(delete(CatalogMerchant).where(CatalogMerchant.feed_id == feed_id))
        products, offers, merchants, seen = [], [], {}, set()
        def flush():
            if products:
                db.execute(insert(CatalogProduct), products)
                db.execute(insert(CatalogOffer), offers)
                products.clear()
                offers.clear()
        for raw in records:
            record = CatalogRecord.model_validate(raw)
            if record.source_id != source_id or record.data_kind != source.kind:
                raise CatalogError("source_mismatch", "Dataset rows must match the registered source and data kind")
            if record.source_record_id in seen:
                raise CatalogError("duplicate_record", "Dataset contains duplicate source record identities")
            seen.add(record.source_record_id)
            if len(seen) > 1000000:
                raise CatalogError("dataset_too_large", "This importer supports at most one million products per source")
            if record.offer.environment != "local" or record.offer.expires_at is not None or record.offer.observed_at is not None:
                raise CatalogError("invalid_dataset_offer", "Local dataset rows cannot assert live offer observation/freshness")
            if source.kind == "open_dataset" and (record.offer.price_minor is not None or record.offer.shipping_minor is not None
                    or record.offer.availability != "unknown" or record.merchant.id is not None or record.merchant.name is not None or record.offer.url is not None):
                raise CatalogError("invented_offer", "Historical dataset products must not imply a current merchant, price, stock or purchase link")
            data = record.model_dump()
            data["provenance"].update(license_id=source.license_id, license_url=source.license_url,
                                      attribution=source.attribution, dataset_version=version, source_checksum=checksum,
                                      catalog_id=catalog_id, normalized_by="Mynah Finds", is_current_offer=False)
            # Admission must validate the final wire record, including added
            # license metadata, so later API reads cannot fail their contract.
            data = CatalogRecord.model_validate(data).model_dump()
            product_id = identity(feed_id, record.source_record_id)
            merchant_id = None
            if record.merchant.id is not None:
                merchant_id = identity(feed_id, record.merchant.id)
                merchant = record.merchant.model_dump()
                if record.merchant.name is None:
                    raise CatalogError("invalid_merchant", "Synthetic merchant IDs require a name")
                if merchant_id in merchants and merchants[merchant_id] != merchant:
                    raise CatalogError("conflicting_merchant", "A synthetic merchant ID has conflicting names")
                if merchant_id not in merchants:
                    db.execute(insert(CatalogMerchant), [{"id": merchant_id, "feed_id": feed_id,
                               "external_id": record.merchant.id, "name": record.merchant.name, "platform": source_id}])
                    merchants[merchant_id] = merchant
            products.append({"id": product_id, "feed_id": feed_id, "import_id": run.id,
                             "source_record_id": record.source_record_id, "product_key": record.product_key,
                             "variant_key": record.variant_key, "title": record.title,
                             "search_text": " ".join(str(data.get(k) or "") for k in ("title", "description", "category", "brand")).casefold()[:6000],
                             "record": data})
            offers.append({"id": identity(product_id, record.offer.id), "product_id": product_id, "merchant_id": merchant_id,
                           "price_minor": record.offer.price_minor, "currency": record.offer.currency,
                           "availability": record.offer.availability, "observed_at": None, "expires_at": None})
            if len(products) >= 1000:
                flush()
        flush()
        if not seen:
            raise CatalogError("empty_dataset", "Empty datasets cannot replace an existing snapshot")
        if expected_count is not None and len(seen) != expected_count:
            raise CatalogError("dataset_count_mismatch", "The source does not match the bundle's expected count")
        run.row_count = len(seen)
        feed.enabled, feed.last_import_id = True, run.id
        return {"import_id": run.id, "row_count": len(seen), "unchanged": False, "source_id": source_id}


def export_dataset(factory, source_id):
    """Distribute source-isolated adaptations with per-record license attribution."""
    cursor = ""
    while True:
        with factory() as db:
            rows = db.execute(visible_records(source_id).where(CatalogProduct.id > cursor)
                              .order_by(CatalogProduct.id).limit(1000)).scalars().all()
            payload = [(row.id, row.record) for row in rows]
        if not payload:
            return
        for cursor, record in payload:
            yield json.dumps(record, ensure_ascii=False, allow_nan=False) + "\n"
