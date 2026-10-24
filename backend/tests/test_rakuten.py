"""Rakuten adapter checks use invented products and a mocked transport only."""
import json
import logging
import threading

import httpx
import pytest

from backend.app.catalog.rakuten import ENDPOINT, MAX_RESPONSE_BYTES, RakutenClient, _RateGate
from backend.app.catalog.schemas import CatalogRecord, CatalogSearchPage, CatalogSourceStatus
from backend.app.catalog.service import CatalogError


APP_ID = "invented-application-credential-7395"
ACCESS_KEY = "invented-access-secret-2841"


def item(code="shop:watch-1", **changes):
    return {
        "itemCode": code, "itemName": "Invented vintage watch", "itemPrice": 12999,
        "itemCaption": "A fictional product for testing", "itemUrl": "https://item.rakuten.co.jp/shop/watch-1/",
        "shopCode": "shop", "shopName": "Invented Shop", "shopUrl": "https://www.rakuten.co.jp/shop/",
        "mediumImageUrls": [{"imageUrl": "https://image.rakuten.co.jp/shop/watch.jpg"}],
        "availability": 1, "genreId": "558929", "shipOverseasFlag": 1, "shipOverseasArea": "SG/MY",
        "postageFlag": 0, "taxFlag": 0, **changes,
    }


def response(items=None, **changes):
    items = [item()] if items is None else items
    return {"Items": items, "count": len(items), "page": 1, "pageCount": 1, **changes}


@pytest.fixture
def clients():
    opened = []

    def make(handler=None, **kwargs):
        if handler is None:
            handler = lambda request: httpx.Response(200, json=response())
        client = RakutenClient(APP_ID, ACCESS_KEY, transport=httpx.MockTransport(handler),
                               gate=kwargs.pop("gate", _RateGate()), clock=lambda: 1720000000.0, **kwargs)
        opened.append(client)
        return client

    yield make
    for client in opened:
        client.close()


def test_search_uses_current_endpoint_secret_header_and_exact_yen(clients, caplog):
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(200, json=response())

    client = clients(handler)
    caplog.set_level(logging.INFO, logger="httpx")
    result = client.search("watch")
    CatalogSearchPage.model_validate(result)
    request = requests[0]
    assert str(request.url).split("?")[0] == ENDPOINT
    assert request.headers["accessKey"] == ACCESS_KEY
    assert request.url.params["applicationId"] == APP_ID
    assert "accessKey" not in request.url.params
    assert request.url.params["formatVersion"] == "2"
    assert request.url.params["availability"] == "0"
    record = result["items"][0]
    assert record["data_kind"] == "merchant_api"
    assert record["merchant"] == {"id": "shop", "name": "Invented Shop", "platform": "rakuten"}
    assert record["offer"]["price_minor"] == 12999  # JPY, not 1,299,900.
    assert record["offer"]["currency"] == "JPY"
    assert record["offer"]["shipping_minor"] is None  # Domestic postage flag is not international free shipping.
    assert record["offer"]["observed_at"] == 1720000000.0
    assert record["offer"]["expires_at"] is None
    assert record["attributes"]["shipping_confirmed"] is False
    assert record["variant_key"] is None
    assert record["provenance"]["persistence"] == "none"
    assert APP_ID not in json.dumps(result) and ACCESS_KEY not in json.dumps(result)
    assert APP_ID not in caplog.text and ACCESS_KEY not in caplog.text


def test_status_is_configuration_only_without_network(clients):
    client = clients(lambda _: pytest.fail("Status must not call the provider"))
    status = client.status()
    CatalogSourceStatus.model_validate(status)
    assert status["configured"] and status["record_count"] == 0
    assert status["enabled_feeds"] == 0 and status["fresh_records"] is None
    assert status["retrieval"] == "live_api" and status["ai_use"] == "disabled"


@pytest.mark.parametrize("env", [{}, {"RAKUTEN_APPLICATION_ID": APP_ID}, {"RAKUTEN_ACCESS_KEY": ACCESS_KEY},
                                   {"RAKUTEN_APPLICATION_ID": APP_ID, "RAKUTEN_ACCESS_KEY": "bad\nheader"},
                                   {"RAKUTEN_APPLICATION_ID": APP_ID, "RAKUTEN_ACCESS_KEY": "鍵"}])
def test_missing_or_invalid_credentials_never_call_network(env):
    client = RakutenClient.from_env(env, transport=httpx.MockTransport(lambda _: pytest.fail("No credentials")))
    try:
        assert not client.configured
        assert client.status()["allowed_uses"] == []
        with pytest.raises(CatalogError) as caught:
            client.search("watch")
        assert caught.value.code == "rakuten_credentials_missing"
    finally:
        client.close()


def test_pagination_preserves_twenty_item_sdk_pages_and_delivery_filter(clients):
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(200, json=response([item(f"shop:watch-{i}") for i in range(20)], count=200))

    result = clients(handler).search("watch", limit=20, offset=40, delivery_country="SG")
    assert requests[0].url.params["page"] == "3"
    assert requests[0].url.params["hits"] == "20"
    assert requests[0].url.params["shipOverseasFlag"] == "1"
    assert requests[0].url.params["shipOverseasArea"] == "SG"
    assert result["next_offset"] == 60
    assert result["items"][0]["attributes"]["delivery_country_filter"] == "SG"
    assert result["items"][0]["attributes"]["shipping_confirmed"] is False


@pytest.mark.parametrize("kwargs", [{"limit": 31}, {"limit": 0}, {"limit": True}, {"offset": -1},
                                   {"offset": 1}, {"offset": 2000}])
def test_invalid_pagination_rejected_before_network(clients, kwargs):
    client = clients(lambda _: pytest.fail("Invalid pagination must not use calls"))
    with pytest.raises(CatalogError) as caught:
        client.search("watch", **kwargs)
    assert caught.value.code == "invalid_catalog_pagination"


@pytest.mark.parametrize("query", ["", " ", "a" * 129, "腕" * 43, "watch\n", "\ud800", None])
def test_invalid_query_is_bounded_before_network(clients, query):
    with pytest.raises(CatalogError) as caught:
        clients(lambda _: pytest.fail("Invalid query")).search(query)
    assert caught.value.code == "invalid_catalog_query"


def test_unsupported_country_never_silently_ignored(clients):
    with pytest.raises(CatalogError) as caught:
        clients(lambda _: pytest.fail("Invalid country")).search("watch", delivery_country="ZZ")
    assert caught.value.code == "delivery_country_unsupported"


def test_last_accessible_page_has_no_next_offset(clients):
    page = clients(lambda _: httpx.Response(200, json=response([item()], count=99999))).search("watch", limit=1, offset=99)
    assert page["next_offset"] is None


@pytest.mark.parametrize("status,code", [(401, "rakuten_authentication_failed"), (403, "rakuten_authentication_failed"),
                                       (400, "rakuten_request_rejected"), (429, "rakuten_rate_limited"),
                                       (500, "rakuten_unavailable"), (302, "rakuten_unavailable")])
def test_upstream_failures_are_sanitized_and_not_retried(clients, status, code):
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(status, json={"error_description": ACCESS_KEY + APP_ID},
                              headers={"Location": "https://example.com/steal-credentials"})

    with pytest.raises(CatalogError) as caught:
        clients(handler).search("watch")
    assert caught.value.code == code
    assert ACCESS_KEY not in str(caught.value) and APP_ID not in str(caught.value)
    assert len(requests) == 1


def test_timeout_is_sanitized(clients):
    def handler(request):
        raise httpx.ReadTimeout(ACCESS_KEY + str(request.url), request=request)

    with pytest.raises(CatalogError) as caught:
        clients(handler).search("watch")
    assert caught.value.code == "rakuten_unavailable"
    assert ACCESS_KEY not in str(caught.value) and APP_ID not in str(caught.value)
    assert caught.value.__suppress_context__


@pytest.mark.parametrize("payload", [
    {"count": 2, "Items": [item(), {"itemName": "Malformed product"}]},
    response([item(itemPrice="12.5")]), response([item(itemPrice=True)]),
    response([item(itemPrice=-1)]), response([item(shopCode="another-shop")]),
    response([item(itemUrl="http://127.0.0.1/private")]), response([item(), item()]),
    response([item(itemCaption=ACCESS_KEY)]), {"count": 1}, {"count": "invalid", "Items": []},
    {"error": ACCESS_KEY}, [],
])
def test_invalid_or_partially_malformed_response_fails_whole_page(clients, payload):
    with pytest.raises(CatalogError) as caught:
        clients(lambda _: httpx.Response(200, json=payload)).search("watch")
    assert caught.value.code == "rakuten_invalid_response"
    assert ACCESS_KEY not in str(caught.value)


def test_unknown_fields_stay_unknown_and_invalid_optional_images_are_omitted(clients):
    source = item(itemPrice=None, availability=None, mediumImageUrls=[{"imageUrl": "https://localhost/secret"}])
    record = clients(lambda _: httpx.Response(200, json=response([source]))).search("watch")["items"][0]
    assert record["offer"]["price_minor"] is None
    assert record["offer"]["availability"] == "unknown"
    assert record["offer"]["image_url"] is None
    assert record["brand"] is None and record["category"] is None


@pytest.mark.parametrize("empty", ["", "   "])
def test_domestic_listings_with_empty_optional_metadata_are_valid(clients, empty):
    source = item(shipOverseasFlag=0, shipOverseasArea=empty, itemCaption=empty,
                  genreId=empty, itemPriceBaseField=empty, shopUrl=empty, affiliateUrl=empty)
    record = clients(lambda _: httpx.Response(200, json=response([source]))).search("watch")["items"][0]
    assert record["source_record_id"] == "shop:watch-1"
    assert record["offer"]["url"] == source["itemUrl"]
    assert record["description"] is None and record["category"] is None
    assert record["attributes"]["overseas_shipping_flag"] == 0
    assert "overseas_shipping_areas" not in record["attributes"]
    assert "rakuten_genre_id" not in record["attributes"]
    assert "price_base_field" not in record["attributes"]
    assert "shop_url" not in record["attributes"]


@pytest.mark.parametrize("required", ["itemCode", "itemName", "shopCode", "shopName", "itemUrl"])
def test_empty_required_fields_still_reject_incomplete_products(clients, required):
    with pytest.raises(CatalogError) as caught:
        clients(lambda _: httpx.Response(200, json=response([item(**{required: "   "})]))).search("watch")
    assert caught.value.code == "rakuten_invalid_response"


def test_documented_lowercase_response_and_image_array_shape(clients):
    payload = {"count": 1, "items": [item(mediumImageUrls=["https://image.rakuten.co.jp/shop/watch.jpg"])]}
    record = clients(lambda _: httpx.Response(200, json=payload)).search("watch")["items"][0]
    assert record["source_record_id"] == "shop:watch-1"
    assert record["offer"]["image_url"] == "https://image.rakuten.co.jp/shop/watch.jpg"


def test_affiliate_link_preserved_without_storing_affiliate_id_as_metadata(clients):
    affiliate = "invented-public-affiliate-id"
    link = f"https://hb.afl.rakuten.co.jp/hgc/{affiliate}/?pc=https%3A%2F%2Fitem.rakuten.co.jp%2Fshop%2Fwatch-1%2F"
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(200, json=response([item(affiliateUrl=link)]))

    result = clients(handler, affiliate_id=affiliate).search("watch")
    assert requests[0].url.params["affiliateId"] == affiliate
    assert result["items"][0]["offer"]["url"] == link


def test_exact_item_lookup_checks_identity(clients):
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(200, json=response())

    record = clients(handler).get_item("shop:watch-1")
    CatalogRecord.model_validate(record)
    assert requests[0].url.params["itemCode"] == "shop:watch-1"
    assert "keyword" not in requests[0].url.params
    with pytest.raises(CatalogError) as caught:
        clients().get_item("shop:another-watch")
    assert caught.value.code == "rakuten_invalid_response"


def test_not_found_is_empty_search_or_missing_exact_item(clients):
    client = clients(lambda _: httpx.Response(404, json={"error": "not_found"}))
    assert client.search("watch")["items"] == []
    with pytest.raises(CatalogError) as caught:
        clients(lambda _: httpx.Response(404)).get_item("shop:watch-1")
    assert caught.value.code == "catalog_record_not_found"


@pytest.mark.parametrize("body", [b"not-json", b"x" * (MAX_RESPONSE_BYTES + 1)])
def test_non_json_and_oversized_payloads_fail_safely(clients, body):
    with pytest.raises(CatalogError) as caught:
        clients(lambda _: httpx.Response(200, content=body)).search("watch")
    assert caught.value.code == "rakuten_invalid_response"


def test_streaming_response_checks_elapsed_budget_between_chunks(clients, monkeypatch):
    now = [0.0]
    monkeypatch.setattr("backend.app.catalog.rakuten.time.monotonic", lambda: now[0])

    class SlowBody(httpx.SyncByteStream):
        def __iter__(self):
            yield b'{"count":'
            now[0] = 9.0
            yield b'0,"Items":[]}'

    with pytest.raises(CatalogError) as caught:
        clients(lambda _: httpx.Response(200, stream=SlowBody())).search("watch")
    assert caught.value.code == "rakuten_unavailable"


def test_rate_gate_is_shared_per_app_across_client_instances_without_waiting(clients):
    now = [100.0]
    gate = _RateGate(clock=lambda: now[0])
    first, second = clients(gate=gate), clients(gate=gate)
    first.search("watch")
    with pytest.raises(CatalogError) as caught:
        second.search("watch")
    assert caught.value.code == "rakuten_rate_limited"
    now[0] += 1
    assert second.search("watch")["items"]


def test_one_inflight_request_even_after_rate_window_elapsed(clients):
    now = [100.0]
    gate = _RateGate(clock=lambda: now[0])
    entered, finish = threading.Event(), threading.Event()
    errors = []

    def handler(request):
        entered.set()
        assert finish.wait(5)
        return httpx.Response(200, json=response())

    client = clients(handler, gate=gate)

    def run():
        try:
            client.search("watch")
        except Exception as exc:
            errors.append(exc)

    thread = threading.Thread(target=run)
    thread.start()
    try:
        assert entered.wait(5)
        now[0] += 2
        with pytest.raises(CatalogError) as caught:
            clients(gate=gate).search("watch")
        assert caught.value.code == "rakuten_rate_limited"
    finally:
        finish.set()
        thread.join(5)
    assert not errors and not thread.is_alive()


def test_upstream_retry_after_prevents_immediate_followup(clients):
    now = [100.0]
    gate = _RateGate(clock=lambda: now[0])
    client = clients(lambda _: httpx.Response(429, headers={"Retry-After": "10"}), gate=gate)
    with pytest.raises(CatalogError):
        client.search("watch")
    now[0] += 5
    with pytest.raises(CatalogError) as caught:
        clients(gate=gate).search("watch")
    assert caught.value.code == "rakuten_rate_limited"
    now[0] += 5
    assert clients(gate=gate).search("watch")["items"]
