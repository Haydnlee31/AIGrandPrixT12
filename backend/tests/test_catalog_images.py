from copy import deepcopy
import threading
import time

import httpx
import pytest

from backend.app.catalog_images import ProductImageEnricher, IMAGE_ATTRIBUTION, MAX_IMAGE_BYTES

CODE = "350427319820040"
PHOTO = "https://images.openproductsfacts.org/images/products/350/427/319/820040/front_en.4.400.jpg"


def row(code=CODE, **changes):
    value = {"id": "record-" + code, "source_id": "open_products_facts", "source_record_id": code,
             "title": "Apple watch", "image_url": None, "attribution": "Original catalog attribution.",
             "license_url": "https://opendatacommons.org/licenses/odbl/1-0/", "reasons": [{"text": "A saved preference"}],
             "price_minor": None}
    value.update(changes)
    return value


def transport_for(*, code=CODE, photo=PHOTO, mime="image/jpeg", size="13229", status=200, calls=None):
    def handle(request):
        if calls is not None:
            calls.append(request)
        if request.method == "GET":
            return httpx.Response(200, json={"status": 1, "product": {"code": code, "image_front_url": photo}})
        return httpx.Response(status, headers={"content-type": mime, "content-length": size})
    return httpx.MockTransport(handle)


@pytest.fixture
def make_enricher():
    instances = []
    def make(**kwargs):
        instance = ProductImageEnricher(**kwargs)
        instances.append(instance)
        return instance
    yield make
    for instance in instances:
        instance.close()


def test_exact_photo_is_additive_without_mutating_catalog_or_credentials(make_enricher):
    calls = []
    instance = make_enricher(transport=transport_for(calls=calls))
    items = [row()]; original = deepcopy(items)
    result = instance.enrich(items)
    assert items == original
    assert result[0]["image_url"] == PHOTO
    assert IMAGE_ATTRIBUTION in result[0]["attribution"]
    assert result[0]["attribution"].startswith(original[0]["attribution"])
    for key in original[0].keys() - {"image_url", "attribution"}:
        assert result[0][key] == original[0][key]
    assert [request.method for request in calls] == ["GET", "HEAD"]
    assert calls[0].url.host == "world.openproductsfacts.org"
    assert calls[0].url.path.endswith(f"/{CODE}.json")
    assert all("authorization" not in request.headers and "cookie" not in request.headers for request in calls)
    assert instance.enrich(items) == result
    assert len(calls) == 2  # Positive cache.


def test_missing_photo_is_negatively_cached(make_enricher):
    calls = []
    instance = make_enricher(transport=transport_for(photo=None, calls=calls))
    assert instance.enrich([row()]) == [row()]
    assert instance.enrich([row()]) == [row()]
    assert len(calls) == 1


@pytest.mark.parametrize("photo", [
    "http://images.openproductsfacts.org/images/products/350/427/319/820040/front_en.4.400.jpg",
    "https://127.0.0.1/images/products/350/427/319/820040/front.jpg",
    "https://images.openproductsfacts.org.evil.test/images/products/350/427/319/820040/front.jpg",
    "https://user:secret@images.openproductsfacts.org/images/products/350/427/319/820040/front.jpg",
    "https://images.openproductsfacts.org:8443/images/products/350/427/319/820040/front.jpg",
    "https://images.openproductsfacts.org/images/products/123/456/789/front.jpg",
    PHOTO + "?redirect=https://127.0.0.1", PHOTO + "#fragment",
])
def test_unsafe_or_different_product_image_never_fetched(make_enricher, photo):
    calls = []
    instance = make_enricher(transport=transport_for(photo=photo, calls=calls))
    assert instance.enrich([row()]) == [row()]
    assert len(calls) == 1


def test_incorrect_barcode_never_fetches_photo(make_enricher):
    calls = []
    instance = make_enricher(transport=transport_for(code="0000000000000", calls=calls))
    assert instance.enrich([row()]) == [row()]
    assert len(calls) == 1


@pytest.mark.parametrize("options", [
    {"mime": "text/html"}, {"size": str(MAX_IMAGE_BYTES + 1)}, {"size": ""},
    {"size": "0"}, {"status": 302}, {"status": 404},
])
def test_unverified_images_stay_empty(make_enricher, options):
    instance = make_enricher(transport=transport_for(**options))
    assert instance.enrich([row()]) == [row()]


def test_only_missing_opf_photos_with_numeric_identity_are_candidates(make_enricher):
    calls = []
    instance = make_enricher(transport=transport_for(calls=calls))
    items = [row(source_id="abo"), row(image_url="https://existing.test/image.jpg"), row(code="../private"), row(code="123")]
    assert instance.enrich(items) == items
    assert calls == []


def test_worker_and_candidate_bounds_and_order(make_enricher):
    calls = []; lock = threading.Lock(); active = 0; maximum = 0
    def handle(request):
        nonlocal active, maximum
        with lock:
            active += 1; maximum = max(maximum, active); calls.append(request)
        try:
            time.sleep(0.01)
            code = request.url.path.rsplit("/", 1)[-1].replace(".json", "")
            return httpx.Response(200, json={"status": 1, "product": {"code": code}})
        finally:
            with lock:
                active -= 1
    instance = make_enricher(transport=httpx.MockTransport(handle))
    items = [row(code=str(1000000000000 + index)) for index in range(30)]
    assert instance.enrich(items) == items
    assert len(calls) == 12
    assert 1 <= maximum <= 4


def test_batch_deadline_does_not_wait_for_slow_transport(make_enricher):
    def slow(request):
        time.sleep(0.15)  # Simulates a transport which ignores its per-request timeout.
        return httpx.Response(200, json={"status": 1, "product": {"code": CODE, "image_front_url": PHOTO}})
    instance = make_enricher(transport=httpx.MockTransport(slow), batch_seconds=0.03)
    start = time.monotonic()
    assert instance.enrich([row()]) == [row()]
    assert time.monotonic() - start < 0.12


def test_network_failure_and_oversized_metadata_are_optional(make_enricher):
    for handler in (lambda request: (_ for _ in ()).throw(httpx.ReadTimeout("slow")),
                    lambda request: httpx.Response(200, content=b" " * 65537)):
        instance = make_enricher(transport=httpx.MockTransport(handler))
        assert instance.enrich([row()]) == [row()]


def test_cache_capacity_is_bounded(make_enricher):
    def handle(request):
        code = request.url.path.rsplit("/", 1)[-1].replace(".json", "")
        return httpx.Response(200, json={"status": 1, "product": {"code": code}})
    instance = make_enricher(transport=httpx.MockTransport(handle), cache_size=2)
    instance.enrich([row(code=str(1000000000000 + index)) for index in range(5)])
    assert len(instance._cache) == 2
