"""Read-only Rakuten Ichiba offers with server-owned credentials.

API reference: https://webservice.rakuten.co.jp/documentation/ichiba-item-search
The application must register an allowed use and display Rakuten's required
credit. This adapter does not grant redistribution, AI, or storage rights.

One shared gate limits each application ID to one in-flight request and at most
one request start per second within this process. Run one provider worker per
application ID; multiple processes/hosts need a shared external rate limiter.
There is deliberately no response cache, automatic retry, or persistent import.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import threading
import time
from collections.abc import Mapping
from urllib.parse import urlsplit

import httpx
from pydantic import ValidationError

from .schemas import CatalogRecord, public_url
from .service import CatalogError


ENDPOINT = "https://openapi.rakuten.co.jp/ichibams/api/IchibaItem/Search/20260701"
DOCUMENTATION_URL = "https://webservice.rakuten.co.jp/documentation/ichiba-item-search"
TERMS_URL = "https://webservice.rakuten.co.jp/guide/rule"
CREDIT_URL = "https://developers.rakuten.com/"
CREDIT_TEXT = "Supported by Rakuten Developers"
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_PAGE_SIZE = 30
MAX_PAGES = 100
# Official overseas delivery-area list, not a promise of delivery eligibility.
DELIVERY_COUNTRIES = frozenset(
    "US AR BR CA MX AT BE DK FR DE GR IT MA NL PL PT RU ES SE CH TR GB "
    "AU CN HK IN ID KR MY NZ PH SG TW TH VN".split()
)


class _RedactRequestLog(logging.Filter):
    """httpx normally logs the full URL, which contains the required app ID."""

    def filter(self, record):
        message = record.getMessage()
        if "openapi.rakuten.co.jp/ichibams/" in message:
            record.msg = re.sub(
                r"(?i)([?&](?:applicationId|accessKey|affiliateId)=)[^&\s\"']+",
                r"\1[redacted]", message,
            )
            record.args = ()
        return True


if not any(isinstance(f, _RedactRequestLog) for f in logging.getLogger("httpx").filters):
    logging.getLogger("httpx").addFilter(_RedactRequestLog())


class _RateGate:
    def __init__(self, *, clock=time.monotonic):
        self._clock = clock
        self._lock = threading.Lock()
        self._states = {}

    def acquire(self, application_id):
        key = hashlib.sha256(application_id.encode()).digest()
        with self._lock:
            now = self._clock()
            next_start, active = self._states.get(key, (0.0, False))
            if active or now < next_start:
                raise CatalogError("rakuten_rate_limited", "Rakuten search is busy; retry after a short delay")
            self._states[key] = (now + 1.0, True)
        return key

    def release(self, key, *, cooldown=0):
        with self._lock:
            next_start, _ = self._states[key]
            self._states[key] = (max(next_start, self._clock() + cooldown), False)


_SHARED_GATE = _RateGate()


def _credential(value, maximum=4096):
    return value.strip() if (isinstance(value, str) and value.strip()
                             and len(value) <= maximum
                             and all(33 <= ord(c) <= 126 for c in value.strip())) else ""


def _text(value, maximum, *, required=False):
    if value is None and not required:
        return None
    if not isinstance(value, str) or len(value) > maximum or "\x00" in value:
        raise ValueError("Invalid source text")
    value = value.strip()
    if not value:
        if required:
            raise ValueError("Missing required source text")
        return None
    return value


def _integer(value, *, maximum=9_000_000_000_000_000):
    # Yen has no fractional minor unit. Never multiply it by 100 or round.
    if type(value) is int:
        result = value
    elif isinstance(value, str) and re.fullmatch(r"[0-9]{1,16}", value):
        result = int(value)
    else:
        raise ValueError("Invalid source integer")
    if not 0 <= result <= maximum:
        raise ValueError("Invalid source integer range")
    return result


def _link(value, *, optional=False):
    if optional and value in (None, ""):
        return None
    value = _text(value, 4096, required=True)
    public_url(value)
    if urlsplit(value).scheme != "https":
        raise ValueError("Source links must use HTTPS")
    return value


def _image(item):
    images = item.get("mediumImageUrls") or item.get("smallImageUrls") or []
    if not isinstance(images, list):
        return None
    for candidate in images[:3]:
        if isinstance(candidate, dict):
            candidate = candidate.get("imageUrl")
        try:
            link = _link(candidate, optional=True)
        except ValueError:
            continue
        if link:
            return link
    return None


def _normalize(item, now, delivery_country):
    if not isinstance(item, dict):
        raise ValueError("Invalid source item")
    record_id = _text(item.get("itemCode"), 1024, required=True)
    shop_code = _text(item.get("shopCode"), 512, required=True)
    if ":" not in record_id or record_id.split(":", 1)[0] != shop_code:
        raise ValueError("Item and merchant identity disagree")
    price = None if item.get("itemPrice") is None else _integer(item["itemPrice"])
    availability = item.get("availability")
    stock = {0: "out_of_stock", 1: "in_stock"}.get(availability, "unknown") if type(availability) is int else "unknown"
    attributes = {"delivery_country_filter": delivery_country, "shipping_confirmed": False,
                  "variant_confirmed": False}
    for source_key, key in (("genreId", "rakuten_genre_id"), ("shipOverseasArea", "overseas_shipping_areas"),
                            ("itemPriceBaseField", "price_base_field")):
        value = item.get(source_key)
        if value is not None:
            if type(value) is int and source_key == "genreId":
                value = str(value)
            value = _text(value, 2048)
            if value is not None:
                attributes[key] = value
    for source_key, key in (("shipOverseasFlag", "overseas_shipping_flag"), ("postageFlag", "postage_flag"),
                            ("taxFlag", "tax_flag")):
        value = item.get(source_key)
        if type(value) is int and value in {0, 1}:
            attributes[key] = value
    for key in ("itemPriceMin1", "itemPriceMax1", "itemPriceMin3", "itemPriceMax3"):
        if item.get(key) is not None:
            attributes[key] = _integer(item[key])
    shop_url = _text(item.get("shopUrl"), 4096)
    if shop_url is not None:
        attributes["shop_url"] = _link(shop_url)
    affiliate_url = _text(item.get("affiliateUrl"), 4096)
    return CatalogRecord.model_validate({
        "source_id": "rakuten", "source_record_id": record_id, "data_kind": "merchant_api",
        "title": _text(item.get("itemName"), 1000, required=True),
        "description": _text(item.get("itemCaption"), 20000) if item.get("itemCaption") else None,
        "category": None, "brand": None, "attributes": attributes,
        "product_key": "rakuten:" + record_id if len(record_id) <= 1016 else None,
        "variant_key": None,
        "merchant": {"id": shop_code, "name": _text(item.get("shopName"), 512, required=True), "platform": "rakuten"},
        "offer": {
            "id": record_id, "price_minor": price, "currency": "JPY", "shipping_minor": None,
            "availability": stock, "condition": None,
            "url": _link(affiliate_url or item.get("itemUrl")), "image_url": _image(item),
            "observed_at": now, "expires_at": None, "marketplace_id": "JP", "environment": "production",
        },
        "provenance": {
            "api": "Rakuten Ichiba Item Search", "api_version": "20260701",
            "documentation_url": DOCUMENTATION_URL, "terms_url": TERMS_URL,
            "attribution": CREDIT_TEXT, "attribution_url": CREDIT_URL,
            "retrieval": "live_api", "persistence": "none", "ai_use": "disabled",
            "price_note": "Observed listing price in JPY; variant, delivery charges and checkout total are unconfirmed",
        },
    }).model_dump()


class RakutenClient:
    def __init__(self, application_id="", access_key="", *, affiliate_id="", transport=None,
                 gate=None, timeout=8.0, clock=time.time):
        self._application_id = _credential(application_id)
        self._access_key = _credential(access_key)
        self._affiliate_id = _credential(affiliate_id)
        self._gate = gate if gate is not None else _SHARED_GATE
        self._clock = clock
        self._request_budget = float(timeout)
        self._client = httpx.Client(transport=transport, timeout=timeout, follow_redirects=False,
                                    trust_env=False, headers={"User-Agent": "MymahFinds/0.4 (catalog search)",
                                                             "Accept-Encoding": "identity"})

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None, **kwargs):
        env = os.environ if env is None else env
        return cls(env.get("RAKUTEN_APPLICATION_ID", ""), env.get("RAKUTEN_ACCESS_KEY", ""),
                   affiliate_id=env.get("RAKUTEN_AFFILIATE_ID", ""), **kwargs)

    @property
    def configured(self):
        """Credential presence only; account permissions have not been tested."""
        return bool(self._application_id and self._access_key)

    def close(self):
        self._client.close()

    def status(self):
        return {
            "source_id": "rakuten", "configured": self.configured, "enabled_feeds": 0,
            "record_count": 0, "fresh_records": None, "data_kind": "merchant_api",
            "name": "Rakuten Ichiba", "license_id": None, "license_url": TERMS_URL,
            "attribution": CREDIT_TEXT, "environment": "production", "marketplace": "JP",
            "retrieval": "live_api", "allowed_uses": ["direct_display", "deterministic_search"] if self.configured else [],
            "ai_use": "disabled", "persistence": "none",
        }

    def _request(self, parameters):
        if not self.configured:
            raise CatalogError("rakuten_credentials_missing", "Configure Rakuten application ID and access key on the backend")
        parameters = {"applicationId": self._application_id, "format": "json", "formatVersion": 2,
                      "availability": 0, **parameters}
        if self._affiliate_id:
            parameters["affiliateId"] = self._affiliate_id
        gate_key = self._gate.acquire(self._application_id)
        cooldown = 0
        deadline = time.monotonic() + self._request_budget
        try:
            with self._client.stream("GET", ENDPOINT, params=parameters, headers={"accessKey": self._access_key}) as response:
                if response.status_code == 429:
                    try:
                        cooldown = max(2.0, min(60.0, float(response.headers.get("Retry-After", "2"))))
                    except ValueError:
                        cooldown = 2.0
                    raise CatalogError("rakuten_rate_limited", "Rakuten temporarily limited requests; try again later")
                if response.status_code in {401, 403}:
                    raise CatalogError("rakuten_authentication_failed", "Rakuten rejected the backend credentials or application access")
                if response.status_code == 404:
                    return {"count": 0, "Items": []}
                if response.status_code >= 500 or 300 <= response.status_code < 400:
                    raise CatalogError("rakuten_unavailable", "Rakuten search is temporarily unavailable")
                if response.status_code != 200:
                    # Upstream descriptions can echo credentials and query text.
                    raise CatalogError("rakuten_request_rejected", "Rakuten rejected the search; check application access and search parameters")
                # Ask for identity encoding, preventing decompression expansion
                # before the byte bound can be checked. Each network read has
                # the httpx timeout; additionally check elapsed time between
                # chunks rather than waiting to fill a large chunk buffer.
                if response.headers.get("Content-Encoding", "identity").lower() not in {"", "identity"}:
                    raise CatalogError("rakuten_invalid_response", "Rakuten returned an unsupported response encoding")
                body = bytearray()
                for chunk in response.iter_bytes():
                    if time.monotonic() > deadline:
                        raise CatalogError("rakuten_unavailable", "Rakuten search timed out; try again later")
                    if len(body) + len(chunk) > MAX_RESPONSE_BYTES:
                        raise CatalogError("rakuten_invalid_response", "Rakuten returned an oversized response")
                    body.extend(chunk)
                try:
                    payload = json.loads(body)
                except (ValueError, UnicodeError):
                    raise CatalogError("rakuten_invalid_response", "Rakuten returned an invalid response") from None
                if not isinstance(payload, dict) or "error" in payload:
                    raise CatalogError("rakuten_invalid_response", "Rakuten returned an invalid response")
                return payload
        except httpx.TimeoutException:
            raise CatalogError("rakuten_unavailable", "Rakuten search timed out; try again later") from None
        except httpx.HTTPError:
            raise CatalogError("rakuten_unavailable", "Rakuten search is temporarily unavailable") from None
        finally:
            self._gate.release(gate_key, cooldown=cooldown)

    def _page(self, payload, *, limit, offset, delivery_country):
        now = self._clock()
        try:
            total = _integer(payload.get("count"))
            raw_items = payload.get("Items", payload.get("items"))
            if not isinstance(raw_items, list) or len(raw_items) > limit or total < len(raw_items):
                raise ValueError("Invalid item list")
            items = [_normalize(raw.get("Item", raw.get("item", raw)) if isinstance(raw, dict) else raw, now, delivery_country)
                     for raw in raw_items]
            if len({item["source_record_id"] for item in items}) != len(items):
                raise ValueError("Repeated source identity")
            serialized = json.dumps(items, ensure_ascii=False)
            # Affiliate IDs are designed to appear in public click URLs; the
            # application ID and access key are server credentials.
            if any(secret and secret in serialized for secret in (self._application_id, self._access_key)):
                raise ValueError("Source response echoed backend credentials")
        except (ValueError, TypeError, ValidationError):
            raise CatalogError("rakuten_invalid_response", "Rakuten returned incomplete or invalid product data") from None
        next_offset = offset + limit if offset + limit < min(total, limit * MAX_PAGES) and len(raw_items) == limit else None
        return {"items": items, "source_id": "rakuten", "next_offset": next_offset, "total": total,
                "fetched_at": now, "expires_at": None, "environment": "production", "marketplace": "JP", "retrieval": "live_api"}

    def search(self, query, limit=20, offset=0, delivery_country=None):
        try:
            valid_query = (isinstance(query, str) and bool(query.strip()) and len(query.strip().encode("utf-8")) <= 128
                           and not any(ord(c) < 32 for c in query))
        except UnicodeError:
            valid_query = False
        if not valid_query:
            raise CatalogError("invalid_catalog_query", "Rakuten search needs a keyword of at most 128 UTF-8 bytes")
        if (type(limit) is not int or not 1 <= limit <= MAX_PAGE_SIZE or type(offset) is not int
                or offset < 0 or offset % limit or offset // limit >= MAX_PAGES):
            raise CatalogError("invalid_catalog_pagination", "Rakuten supports 1–30 results per page, aligned offsets, and at most 100 pages")
        parameters = {"keyword": query.strip(), "hits": limit, "page": offset // limit + 1}
        if delivery_country is not None:
            if delivery_country not in DELIVERY_COUNTRIES:
                raise CatalogError("delivery_country_unsupported", "Rakuten does not support this delivery-country filter")
            parameters.update(shipOverseasFlag=1, shipOverseasArea=delivery_country)
        return self._page(self._request(parameters), limit=limit, offset=offset, delivery_country=delivery_country)

    def get_item(self, record_id):
        if (not isinstance(record_id, str) or len(record_id) > 1024 or not re.fullmatch(r"[A-Za-z0-9_-]+:[^\s:]+", record_id)):
            raise CatalogError("invalid_catalog_query", "Use the Rakuten item code returned by search")
        result = self._page(self._request({"itemCode": record_id, "hits": 1, "page": 1}), limit=1, offset=0, delivery_country=None)
        if not result["items"]:
            raise CatalogError("catalog_record_not_found", "The Rakuten item is missing or no longer listed")
        if result["items"][0]["source_record_id"] != record_id:
            raise CatalogError("rakuten_invalid_response", "Rakuten returned a different product")
        return result["items"][0]
