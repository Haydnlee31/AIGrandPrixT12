import os
import time
import uuid

from sqlalchemy import JSON, BigInteger, Boolean, Float, ForeignKey, Index, Integer, String, UniqueConstraint, create_engine, event
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, column_property, mapped_column, sessionmaker


def uid():
    return uuid.uuid4().hex


class Base(DeclarativeBase):
    pass


Document = JSON().with_variant(JSONB, "postgresql")


class SavedItem(Base):
    __tablename__ = "saved_items"
    __table_args__ = (UniqueConstraint("user_id", "canonical_url"),)
    id: Mapped[str] = mapped_column(String, primary_key=True, default=uid)
    user_id: Mapped[str] = mapped_column(String, index=True)
    original_url: Mapped[str] = mapped_column(String)
    canonical_url: Mapped[str] = mapped_column(String)
    title: Mapped[str] = mapped_column(String)
    source: Mapped[str] = mapped_column(String)
    client: Mapped[str] = mapped_column(String, default="web", server_default="web")
    selected_text: Mapped[str] = mapped_column(String, default="")
    content_hash: Mapped[str] = mapped_column(String, default="")
    note: Mapped[str] = mapped_column(String, default="")
    image_data_url: Mapped[str | None] = mapped_column(String, nullable=True, deferred=True)
    has_image: Mapped[bool] = column_property(image_data_url.column.is_not(None))
    captured_at: Mapped[float] = mapped_column(Float, default=time.time)
    status: Mapped[str] = mapped_column(String, default="pending")
    features: Mapped[dict] = mapped_column(Document, default=dict)
    search_text: Mapped[str] = mapped_column(String, default="", server_default="")
    category_text: Mapped[str] = mapped_column(String, default="", server_default="")
    revision: Mapped[int] = mapped_column(Integer, default=1)
    deleted: Mapped[bool] = mapped_column(Boolean, default=False)


class Suggestion(Base):
    __tablename__ = "annotation_suggestions"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=uid)
    user_id: Mapped[str] = mapped_column(String, index=True)
    item_id: Mapped[str] = mapped_column(ForeignKey("saved_items.id"))
    kind: Mapped[str] = mapped_column(String)
    text: Mapped[str] = mapped_column(String)
    claim: Mapped[str] = mapped_column(String)
    model_version: Mapped[str] = mapped_column(String)


class UserEvent(Base):
    __tablename__ = "user_events"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=uid)
    user_id: Mapped[str] = mapped_column(String, index=True)
    item_id: Mapped[str | None] = mapped_column(String, nullable=True)
    event_type: Mapped[str] = mapped_column(String)
    payload: Mapped[dict] = mapped_column(Document)
    occurred_at: Mapped[float] = mapped_column(Float, default=time.time)


class Evidence(Base):
    __tablename__ = "evidence"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=uid)
    user_id: Mapped[str] = mapped_column(String, index=True)
    item_id: Mapped[str] = mapped_column(ForeignKey("saved_items.id"))
    event_id: Mapped[str] = mapped_column(ForeignKey("user_events.id"))
    claim: Mapped[str] = mapped_column(String)
    text: Mapped[str] = mapped_column(String)
    origin: Mapped[str] = mapped_column(String)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    observed_at: Mapped[float] = mapped_column(Float, default=time.time)


class UserState(Base):
    __tablename__ = "user_state"
    user_id: Mapped[str] = mapped_column(String, primary_key=True)
    version: Mapped[int] = mapped_column(Integer, default=1)
    suppressed: Mapped[bool] = mapped_column(Boolean, default=False)
    cooldown_until: Mapped[float] = mapped_column(Float, default=0)


class DiscoverySession(Base):
    __tablename__ = "discovery_sessions"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=uid)
    user_id: Mapped[str] = mapped_column(String, index=True)
    version: Mapped[int] = mapped_column(Integer, default=1)
    stage: Mapped[str] = mapped_column(String, default="exploring")
    preferences: Mapped[dict] = mapped_column(Document, default=dict)
    evidence_ids: Mapped[list] = mapped_column(Document, default=list)
    context_version: Mapped[int] = mapped_column(Integer)
    created_at: Mapped[float] = mapped_column(Float, default=time.time)


class Job(Base):
    __tablename__ = "jobs"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=uid)
    user_id: Mapped[str] = mapped_column(String, index=True)
    kind: Mapped[str] = mapped_column(String)
    payload: Mapped[dict] = mapped_column(Document)
    status: Mapped[str] = mapped_column(String, default="pending", index=True)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    due_at: Mapped[float] = mapped_column(Float, default=time.time)
    lease_until: Mapped[float] = mapped_column(Float, default=0)
    lease_token: Mapped[str | None] = mapped_column(String, nullable=True)
    error: Mapped[str | None] = mapped_column(String, nullable=True)


class Watch(Base):
    __tablename__ = "watch_rules"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=uid)
    user_id: Mapped[str] = mapped_column(String, index=True)
    variant_id: Mapped[str] = mapped_column(String)
    currency: Mapped[str] = mapped_column(String)
    target_minor: Mapped[int] = mapped_column(Integer)
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    rule_version: Mapped[int] = mapped_column(Integer, default=1)
    below: Mapped[bool] = mapped_column(Boolean, default=False)
    episode: Mapped[int] = mapped_column(Integer, default=0)
    last_price_minor: Mapped[int | None] = mapped_column(Integer, nullable=True)
    last_checked_at: Mapped[float | None] = mapped_column(Float, nullable=True)


class Observation(Base):
    __tablename__ = "price_observations"
    id: Mapped[str] = mapped_column(String, primary_key=True)
    user_id: Mapped[str] = mapped_column(String, index=True)
    watch_id: Mapped[str] = mapped_column(ForeignKey("watch_rules.id"))
    variant_id: Mapped[str] = mapped_column(String)
    currency: Mapped[str] = mapped_column(String)
    amount_minor: Mapped[int] = mapped_column(Integer)
    observed_at: Mapped[float] = mapped_column(Float)
    data_mode: Mapped[str] = mapped_column(String, default="simulated")


class Notification(Base):
    __tablename__ = "notifications"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=uid)
    user_id: Mapped[str] = mapped_column(String, index=True)
    watch_id: Mapped[str] = mapped_column(ForeignKey("watch_rules.id"))
    observation_id: Mapped[str] = mapped_column(ForeignKey("price_observations.id"))
    dedupe_key: Mapped[str] = mapped_column(String, unique=True)
    message: Mapped[str] = mapped_column(String)
    delivery_status: Mapped[str] = mapped_column(String, default="in_app")


class Mutation(Base):
    __tablename__ = "idempotency_records"
    __table_args__ = (UniqueConstraint("user_id", "key"),)
    id: Mapped[str] = mapped_column(String, primary_key=True, default=uid)
    user_id: Mapped[str] = mapped_column(String)
    key: Mapped[str] = mapped_column(String)
    fingerprint: Mapped[str] = mapped_column(String)
    response: Mapped[dict] = mapped_column(Document)


class CatalogFeed(Base):
    """An operator-approved catalog scope, independent of user libraries."""
    __tablename__ = "catalog_feeds"
    __table_args__ = (UniqueConstraint("source_id", "catalog_id"),)
    id: Mapped[str] = mapped_column(String, primary_key=True)
    source_id: Mapped[str] = mapped_column(String, index=True)
    catalog_id: Mapped[str] = mapped_column(String)
    approval_reference: Mapped[str] = mapped_column(String)
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    last_import_id: Mapped[str | None] = mapped_column(String, nullable=True)


class CatalogImport(Base):
    __tablename__ = "catalog_imports"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=uid)
    feed_id: Mapped[str] = mapped_column(ForeignKey("catalog_feeds.id"), index=True)
    digest: Mapped[str] = mapped_column(String)
    approval_reference: Mapped[str] = mapped_column(String)
    imported_at: Mapped[float] = mapped_column(Float)
    source_observed_at: Mapped[float] = mapped_column(Float)
    expires_at: Mapped[float | None] = mapped_column(Float, nullable=True)
    row_count: Mapped[int] = mapped_column(Integer)


class CatalogMerchant(Base):
    __tablename__ = "catalog_merchants"
    id: Mapped[str] = mapped_column(String, primary_key=True)
    feed_id: Mapped[str] = mapped_column(ForeignKey("catalog_feeds.id"), index=True)
    external_id: Mapped[str] = mapped_column(String)
    name: Mapped[str] = mapped_column(String)
    platform: Mapped[str] = mapped_column(String)


class CatalogProduct(Base):
    """One source record/variant; identities are never merged across merchants."""
    __tablename__ = "catalog_products"
    __table_args__ = (Index("ix_catalog_products_feed_id_id", "feed_id", "id"),
                      Index("ix_catalog_products_feed_record", "feed_id", "source_record_id"))
    id: Mapped[str] = mapped_column(String, primary_key=True)
    feed_id: Mapped[str] = mapped_column(ForeignKey("catalog_feeds.id"), index=True)
    import_id: Mapped[str] = mapped_column(ForeignKey("catalog_imports.id"))
    source_record_id: Mapped[str] = mapped_column(String)
    product_key: Mapped[str | None] = mapped_column(String, nullable=True)
    variant_key: Mapped[str | None] = mapped_column(String, nullable=True)
    title: Mapped[str] = mapped_column(String)
    search_text: Mapped[str] = mapped_column(String)
    record: Mapped[dict] = mapped_column(Document)


class CatalogOffer(Base):
    __tablename__ = "catalog_offers"
    id: Mapped[str] = mapped_column(String, primary_key=True)
    product_id: Mapped[str] = mapped_column(ForeignKey("catalog_products.id"), unique=True)
    merchant_id: Mapped[str | None] = mapped_column(ForeignKey("catalog_merchants.id"), nullable=True)
    price_minor: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    currency: Mapped[str | None] = mapped_column(String, nullable=True)
    availability: Mapped[str] = mapped_column(String)
    observed_at: Mapped[float | None] = mapped_column(Float, nullable=True)
    expires_at: Mapped[float | None] = mapped_column(Float, nullable=True, index=True)


def make_database(url=None):
    url = url or os.getenv("DATABASE_URL", "sqlite:///./prototype.db")
    engine = create_engine(url, connect_args={"check_same_thread": False, "timeout": 20} if url.startswith("sqlite") else {}, pool_pre_ping=True)
    if url.startswith("sqlite"):
        @event.listens_for(engine, "connect")
        def configure(connection, _):
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("PRAGMA journal_mode=WAL")
    return engine, sessionmaker(engine, expire_on_commit=False)
