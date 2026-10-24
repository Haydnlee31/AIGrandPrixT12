"""Source-aware contract for approved feeds, licensed datasets and synthetic data."""
import ipaddress
import json
import re
from typing import Annotated, Any, Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

SourceID = Annotated[str, Field(pattern=r"^[a-z][a-z0-9_]{0,63}$")]
DataKind = Literal["merchant_feed", "merchant_api", "open_dataset", "synthetic"]


def public_url(value: str) -> str:
    parsed = urlsplit(value)
    host = (parsed.hostname or "").lower().rstrip(".")
    if parsed.scheme not in {"https", "http"} or not host or parsed.username or parsed.password or "\\" in value or any(c.isspace() or ord(c) < 32 for c in value):
        raise ValueError("Use a public HTTP(S) URL without credentials")
    if host in {"localhost", "localhost.localdomain"} or host.endswith((".localhost", ".local", ".internal", ".test", ".invalid")) or "." not in host:
        raise ValueError("Local or reserved URLs are not merchant links")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
        # Browsers accept shortened, decimal and hexadecimal IPv4 forms that
        # ipaddress intentionally rejects. Require a conventional DNS hostname.
        if not re.fullmatch(r"(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}", host):
            raise ValueError("Use a public address or conventional DNS hostname")
    if address and not address.is_global:
        raise ValueError("Private addresses are not merchant links")
    return value


class CatalogModel(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


class MerchantFact(CatalogModel):
    id: str | None = Field(default=None, max_length=512)
    name: str | None = Field(default=None, max_length=512)
    platform: SourceID


class OfferFact(CatalogModel):
    id: str = Field(min_length=1, max_length=1024)
    price_minor: int | None = Field(default=None, strict=True, ge=0, le=9_000_000_000_000_000)
    currency: str | None = Field(default=None, pattern=r"^[A-Z]{3}$")
    shipping_minor: int | None = Field(default=None, strict=True, ge=0, le=9_000_000_000_000_000)
    availability: Literal["unknown", "in_stock", "out_of_stock"] = "unknown"
    condition: str | None = Field(default=None, max_length=512)
    url: str | None = Field(default=None, max_length=4096)
    image_url: str | None = Field(default=None, max_length=4096)
    observed_at: float | None = Field(default=None, ge=0)
    expires_at: float | None = Field(default=None, ge=0)
    marketplace_id: str | None = Field(default=None, max_length=100)
    environment: Literal["production", "local"]

    @field_validator("url", "image_url")
    @classmethod
    def validate_url(cls, value):
        return public_url(value) if value is not None else None

    @model_validator(mode="after")
    def coherent(self):
        if (self.price_minor is not None or self.shipping_minor is not None) and self.currency is None:
            raise ValueError("Money requires an explicit currency")
        return self


class CatalogRecord(CatalogModel):
    source_id: SourceID
    source_record_id: str = Field(min_length=1, max_length=1024)
    data_kind: DataKind = "merchant_feed"
    title: str = Field(min_length=1, max_length=1000)
    description: str | None = Field(default=None, max_length=20000)
    category: str | None = Field(default=None, max_length=2048)
    brand: str | None = Field(default=None, max_length=512)
    attributes: dict[str, Any] = Field(default_factory=dict)
    product_key: str | None = Field(default=None, max_length=1024)
    variant_key: str | None = Field(default=None, max_length=1024)
    merchant: MerchantFact
    offer: OfferFact
    provenance: dict[str, Any] = Field(default_factory=dict)

    @field_validator("attributes", "provenance")
    @classmethod
    def bounded_document(cls, value):
        if len(json.dumps(value, allow_nan=False)) > 32000:
            raise ValueError("Source metadata exceeds its size limit")
        return value

    @model_validator(mode="after")
    def coherent_source(self):
        if self.merchant.platform != self.source_id:
            raise ValueError("Merchant platform must match source")
        return self


class CatalogSearchPage(CatalogModel):
    items: list[CatalogRecord]
    source_id: SourceID
    next_offset: int | None
    total: int
    fetched_at: float
    expires_at: float | None
    environment: Literal["production", "local"]
    marketplace: str | None = None
    retrieval: Literal["approved_feed", "live_api", "local_dataset"]


class CatalogSourceStatus(CatalogModel):
    source_id: SourceID
    configured: bool
    enabled_feeds: int
    fresh_records: int | None
    record_count: int
    data_kind: DataKind
    name: str
    license_id: str | None = None
    license_url: str | None = None
    attribution: str | None = None
    environment: Literal["production", "local"]
    marketplace: str | None = None
    retrieval: Literal["approved_feed", "live_api", "local_dataset"]
    allowed_uses: list[Literal["direct_display", "deterministic_search"]]
    ai_use: Literal["disabled"] = "disabled"
    persistence: Literal["approved_snapshot", "licensed_dataset", "synthetic", "none"]


class CatalogSources(CatalogModel):
    items: list[CatalogSourceStatus]
