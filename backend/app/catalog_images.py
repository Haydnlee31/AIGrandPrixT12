"""Bounded, optional photos for exact Open Products Facts catalog records.

Catalog rows stay untouched. No customer data or credentials leave the service:
only the public barcode is sent to the official product API. Images retain their
separate CC BY-SA attribution (the catalog metadata license is unchanged).
"""
from __future__ import annotations

from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor, wait
import json
import re
import threading
import time
from urllib.parse import urlsplit

import httpx

MAX_CANDIDATES = 12
MAX_WORKERS = 4
MAX_IMAGE_BYTES = 5 * 1024 * 1024
MAX_METADATA_BYTES = 64 * 1024
IMAGE_ATTRIBUTION = ("Photo: Open Products Facts contributors, CC BY-SA "
                     "(https://world.openproductsfacts.org/terms-of-use).")
_BARCODE = re.compile(r"[0-9]{8,18}\Z")
_IMAGE_PATH = re.compile(r"/images/products/([0-9/]+)/[A-Za-z0-9_.-]+\.(?:jpg|jpeg|png|webp)\Z")


def _official_image_url(value: object, barcode: str) -> str | None:
    if not isinstance(value, str) or len(value) > 1500:
        return None
    try:
        parsed = urlsplit(value)
        match = _IMAGE_PATH.fullmatch(parsed.path)
        if (parsed.scheme != "https" or parsed.hostname != "images.openproductsfacts.org"
                or parsed.port not in (None, 443) or parsed.username or parsed.password
                or parsed.query or parsed.fragment or not match
                or match.group(1).replace("/", "") != barcode):
            return None
    except ValueError:
        return None
    return value


class ProductImageEnricher:
    """Shared four-worker pool; its queue and both TTL caches are bounded too."""

    def __init__(self, *, transport: httpx.BaseTransport | None = None,
                 batch_seconds: float = 3.0, request_seconds: float = 2.0,
                 cache_size: int = 512, positive_ttl: float = 86400, negative_ttl: float = 300):
        self._transport = transport
        self._batch_seconds = min(3.0, max(0.01, batch_seconds))
        self._request_seconds = min(2.0, max(0.01, request_seconds))
        self._cache_size = max(1, min(2048, cache_size))
        self._positive_ttl, self._negative_ttl = positive_ttl, negative_ttl
        self._cache: OrderedDict[str, tuple[float, str | None]] = OrderedDict()
        self._lock = threading.Lock()
        self._slots = threading.BoundedSemaphore(MAX_CANDIDATES + MAX_WORKERS)
        self._executor = ThreadPoolExecutor(max_workers=MAX_WORKERS, thread_name_prefix="opf-photo")

    def enrich(self, items: list[dict]) -> list[dict]:
        deadline = time.monotonic() + self._batch_seconds
        result = [dict(item) for item in items]
        indices: dict[str, list[int]] = {}
        candidate_count = 0
        for index, item in enumerate(result):
            barcode = item.get("source_record_id")
            if (item.get("source_id") != "open_products_facts" or item.get("image_url")
                    or not isinstance(barcode, str) or not _BARCODE.fullmatch(barcode)):
                continue
            if candidate_count >= MAX_CANDIDATES:
                break
            candidate_count += 1
            indices.setdefault(barcode, []).append(index)

        futures = {}
        photos: dict[str, str | None] = {}
        for barcode in indices:
            cached, image = self._cached(barcode)
            if cached:
                photos[barcode] = image
            elif time.monotonic() < deadline and self._slots.acquire(blocking=False):
                try:
                    future = self._executor.submit(self._fetch, barcode, deadline)
                    future.add_done_callback(lambda _: self._slots.release())
                    futures[future] = barcode
                except RuntimeError:
                    self._slots.release()
        if futures:
            finished, pending = wait(futures, timeout=max(0, deadline - time.monotonic()))
            for future in finished:
                try:
                    photos[futures[future]] = future.result()
                except Exception:
                    pass  # Optional media must never break product retrieval.
            for future in pending:
                future.cancel()  # Running requests own the same deadline; never wait on shutdown.

        for barcode, image in photos.items():
            if not image:
                continue
            for index in indices[barcode]:
                result[index]["image_url"] = image
                original = result[index].get("attribution") or ""
                if IMAGE_ATTRIBUTION not in original:
                    result[index]["attribution"] = (original.rstrip() + " " + IMAGE_ATTRIBUTION).strip()
        return result

    def _cached(self, barcode: str) -> tuple[bool, str | None]:
        with self._lock:
            entry = self._cache.get(barcode)
            if entry is not None and entry[0] > time.monotonic():
                self._cache.move_to_end(barcode)
                return True, entry[1]
            self._cache.pop(barcode, None)
            return False, None

    def _remember(self, barcode: str, image: str | None):
        with self._lock:
            self._cache[barcode] = (time.monotonic() + (self._positive_ttl if image else self._negative_ttl), image)
            self._cache.move_to_end(barcode)
            while len(self._cache) > self._cache_size:
                self._cache.popitem(last=False)

    def _timeout(self, deadline: float) -> float:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Image enrichment deadline reached")
        return min(self._request_seconds, remaining)

    def _fetch(self, barcode: str, deadline: float) -> str | None:
        # A queued duplicate can reuse a result completed by another batch.
        cached, image = self._cached(barcode)
        if cached:
            return image
        if time.monotonic() >= deadline:
            return None
        image = None
        try:
            with httpx.Client(transport=self._transport, follow_redirects=False, trust_env=False,
                              headers={"User-Agent": "MynahFinds/1.0 (catalog product photos)",
                                       "Accept": "application/json"}) as client:
                url = f"https://world.openproductsfacts.org/api/v2/product/{barcode}.json"
                fields = "code,image_front_url,image_url,product_name"
                with client.stream("GET", url, params={"fields": fields}, timeout=self._timeout(deadline)) as response:
                    if response.status_code != 200:
                        raise ValueError("Product metadata unavailable")
                    chunks = bytearray()
                    for chunk in response.iter_bytes():
                        self._timeout(deadline)
                        chunks.extend(chunk)
                        if len(chunks) > MAX_METADATA_BYTES:
                            raise ValueError("Product metadata too large")
                value = json.loads(chunks)
                product = value.get("product") if isinstance(value, dict) else None
                if (value.get("status") != 1 or not isinstance(product, dict)
                        or product.get("code") != barcode):
                    raise ValueError("Product identity did not match")
                image = _official_image_url(product.get("image_front_url"), barcode)
                if not image:
                    image = _official_image_url(product.get("image_url"), barcode)
                if image:
                    response = client.head(image, timeout=self._timeout(deadline), headers={"Accept": "image/jpeg,image/png,image/webp"})
                    mime = response.headers.get("content-type", "").split(";", 1)[0].strip().lower()
                    length = response.headers.get("content-length", "")
                    if (response.status_code != 200 or mime not in {"image/jpeg", "image/png", "image/webp"}
                            or not length.isdigit() or not 0 < int(length) <= MAX_IMAGE_BYTES):
                        image = None
                    self._timeout(deadline)
        except Exception:
            image = None
        self._remember(barcode, image)
        return image

    def close(self):
        """Test/process lifecycle cleanup; never called on the request path."""
        self._executor.shutdown(wait=True, cancel_futures=True)


_enricher = ProductImageEnricher()


def enrich_product_images(items: list[dict]) -> list[dict]:
    return _enricher.enrich(items)
