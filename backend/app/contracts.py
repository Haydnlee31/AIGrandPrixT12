from typing import Literal
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode
import ipaddress

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from .content import MAX_IMAGE_DATA_LENGTH, decode_image


class Contract(BaseModel):
    model_config = ConfigDict(extra="forbid")


def canonical_url(value: str):
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("Use a public http or https link without credentials")
    host = parsed.hostname.lower()
    if host == "localhost" or host.endswith((".local", ".localhost", ".internal")) or "." not in host:
        raise ValueError("Private addresses are not supported")
    try:
        if not ipaddress.ip_address(host).is_global:
            raise ValueError("Private addresses are not supported")
    except ValueError as error:
        if "Private" in str(error):
            raise
    # We only store the link. No network fetching or redirect following occurs.
    query = [(k, v) for k, v in parse_qsl(parsed.query, keep_blank_values=True) if not k.lower().startswith("utm_") and k not in {"fbclid", "gclid"}]
    return urlunsplit((parsed.scheme.lower(), parsed.netloc.lower(), parsed.path.rstrip("/") or "/", urlencode(sorted(query)), ""))


class Capture(Contract):
    url: str = Field(default="", max_length=2048)
    title: str = Field(min_length=1, max_length=300)
    source: Literal["web", "pinterest", "instagram", "article", "product"] = "web"
    client: Literal["web", "chrome_extension", "ios_app", "ios_share_extension"] = "web"
    selected_text: str = Field(default="", max_length=12000)
    note: str = Field(default="", max_length=2000)
    image_data: str | None = Field(default=None, max_length=MAX_IMAGE_DATA_LENGTH,
                                  description="Optional inline PNG/JPEG/WebP data URL. Maximum decoded size 4 MiB. Never a remote image URL.")

    @field_validator("url")
    @classmethod
    def valid_url(cls, value):
        if value:
            canonical_url(value)
        return value

    @field_validator("image_data")
    @classmethod
    def valid_image(cls, value):
        if value is not None:
            decode_image(value)
        return value

    @model_validator(mode="after")
    def content_required(self):
        if not self.url and not self.image_data:
            raise ValueError("A public URL or an image is required")
        return self


class AnnotationResponse(Contract):
    action: Literal["select", "edit", "reject", "skip"]
    suggestion_id: str | None = None
    text: str = Field(default="", max_length=2000)


class HypothesisFeedback(Contract):
    action: Literal["confirm", "dismiss", "keep_collecting", "misunderstood"]


class StartDiscovery(Contract):
    explicit: bool = False


class DiscoveryEvent(Contract):
    expected_version: int = Field(ge=1)
    action: Literal["direction", "less_clutter", "budget", "max_width", "retrieve", "choose", "pause", "dismiss", "resume", "already_own", "too_expensive", "handoff"]
    value: str | int | None = None


class CreateWatch(Contract):
    variant_id: str
    currency: Literal["SGD"] = "SGD"
    target_minor: int = Field(strict=True, gt=0, le=10000000)


class UpdateWatch(Contract):
    enabled: bool | None = None
    target_minor: int | None = Field(default=None, strict=True, gt=0, le=10000000)


class SimulatedPrice(Contract):
    amount_minor: int = Field(strict=True, gt=0, le=10000000)
    variant_id: str
    currency: str = Field(min_length=3, max_length=3)
