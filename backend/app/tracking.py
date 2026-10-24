"""Observe approved imported offers. This module never scrapes or fetches a shop."""
import time

from pydantic import Field
from sqlalchemy import select

from .contracts import Contract
from .catalog.schemas import SourceID
from .catalog.service import CatalogError
from .db import CatalogFeed, CatalogProduct, Notification, Observation, Watch, uid

CHECK_INTERVAL = 15 * 60


class CatalogWatchRequest(Contract):
    source_id: SourceID
    record_id: str = Field(min_length=1, max_length=1024)
    target_minor: int = Field(strict=True, gt=0, le=10000000)


def identity(record):
    return {"variant": record.get("variant_key"), "offer": record["offer"]["id"],
            "merchant": record["merchant"]["id"], "market": record["offer"].get("marketplace_id"),
            "condition": record["offer"].get("condition")}


def usable(record, now):
    offer = record["offer"]
    return (record.get("data_kind") == "merchant_feed" and bool(record.get("variant_key"))
            and offer["environment"] == "production" and str(offer.get("url") or "").startswith("https://")
            and offer.get("currency") == "SGD" and type(offer.get("price_minor")) is int
            and offer["price_minor"] >= 0 and offer.get("observed_at") is not None
            and offer.get("expires_at") is not None and offer["observed_at"] <= now < offer["expires_at"])


def create_catalog_watch(db, user_id, body, now=None):
    now = time.time() if now is None else now
    rows = db.scalars(select(CatalogProduct).join(CatalogFeed).where(
        CatalogFeed.source_id == body.source_id, CatalogFeed.enabled.is_(True),
        CatalogProduct.source_record_id == body.record_id).with_for_update()).all()
    if len(rows) != 1 or not usable(rows[0].record, now):
        raise CatalogError("untrackable_offer", "Choose one current approved SGD merchant offer with an exact variant and HTTPS link")
    row = rows[0]
    record = row.record
    watch = Watch(user_id=user_id, variant_id=record["variant_key"], currency="SGD",
        target_minor=body.target_minor, enabled=True, rule_version=1, below=False, episode=0,
        catalog_ref={"product_id": row.id, "source_id": body.source_id, "record_id": body.record_id,
            "title": record["title"], "merchant_name": record["merchant"]["name"], "identity": identity(record)},
        next_check_at=now + CHECK_INTERVAL, check_status="current")
    db.add(watch)
    db.flush()
    observe(db, watch, record, notify=False)
    return watch


def observe(db, watch, record, *, notify=True):
    offer = record["offer"]
    if watch.last_checked_at is not None and offer["observed_at"] <= watch.last_checked_at:
        return
    observation = Observation(id=uid(), user_id=watch.user_id, watch_id=watch.id,
        variant_id=watch.variant_id, currency=watch.currency, amount_minor=offer["price_minor"],
        observed_at=offer["observed_at"], data_mode="approved_feed",
        offer_snapshot={"merchant_name": record["merchant"]["name"], "url": offer["url"],
            "availability": offer["availability"], "shipping_minor": offer.get("shipping_minor"),
            "expires_at": offer["expires_at"]})
    db.add(observation)
    db.flush()
    below = offer["availability"] == "in_stock" and offer["price_minor"] <= watch.target_minor
    if notify and below and not watch.below:
        watch.episode += 1
        amount = f"{offer['price_minor'] // 100}.{offer['price_minor'] % 100:02d}"
        db.add(Notification(user_id=watch.user_id, watch_id=watch.id, observation_id=observation.id,
            dedupe_key=f"{watch.id}:{watch.rule_version}:{watch.episode}",
            message=f"{record['title']} was observed at SGD {amount} at {record['merchant']['name']}, at or below your target. Item price excludes shipping; check the merchant's current offer."))
    watch.below = below
    watch.last_price_minor = offer["price_minor"]
    watch.last_checked_at = offer["observed_at"]


def check_watch(db, watch, now=None):
    now = time.time() if now is None else now
    if not watch.catalog_ref:
        raise CatalogError("simulated_watch", "This watch only accepts explicitly simulated observations")
    if not watch.enabled:
        return
    watch.next_check_at = now + CHECK_INTERVAL
    row = db.scalar(select(CatalogProduct).join(CatalogFeed).where(
        CatalogProduct.id == watch.catalog_ref["product_id"], CatalogFeed.enabled.is_(True)).with_for_update())
    if row is None or not usable(row.record, now):
        watch.check_status = "waiting_for_current_offer"
    elif identity(row.record) != watch.catalog_ref["identity"]:
        watch.check_status = "identity_changed"
    else:
        watch.check_status = "current"
        observe(db, watch, row.record)


def watch_view(watch):
    fields = ("id", "variant_id", "currency", "target_minor", "enabled", "rule_version", "below", "episode", "last_price_minor", "last_checked_at")
    result = {key: getattr(watch, key) for key in fields}
    result.update(price_basis="item_price_excluding_shipping", data_mode="approved_feed" if watch.catalog_ref else "simulated",
                  check_status=watch.check_status, next_check_at=watch.next_check_at if watch.catalog_ref and watch.enabled else None,
                  catalog={key: watch.catalog_ref[key] for key in ("source_id", "record_id", "title", "merchant_name")} if watch.catalog_ref else None)
    return result


def check_due(factory, now=None):
    now = time.time() if now is None else now
    with factory.begin() as db:
        if db.get_bind().dialect.name == "sqlite":
            db.connection().exec_driver_sql("BEGIN IMMEDIATE")
        watches = db.scalars(select(Watch).where(Watch.enabled.is_(True), Watch.check_status.is_not(None),
            Watch.next_check_at <= now).order_by(Watch.next_check_at, Watch.id).limit(100).with_for_update(skip_locked=True)).all()
        for watch in watches:
            check_watch(db, watch, now)
        return len(watches)
