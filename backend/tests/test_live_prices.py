import asyncio
import time
from types import SimpleNamespace

import httpx
import pytest

from backend.app.live_prices import LivePriceService, MAX_HTML_BYTES, PRICE_FAILURE_MESSAGES, PRICE_FAILURE_REASONS, _money, _parse

ASIN = "B07FCLBWD9"
URL = f"https://www.amazon.in/dp/{ASIN}"


def page(*, asin=ASIN, market="amazon.in", price="₹6,300", reference="₹16,500", label="M.R.P.:", extra="", amount_class="priceToPay", block_asin=None):
    return f'''<html><head><link rel="canonical" href="https://www.{market}/Title/dp/{asin}"></head><body>
      <input id="ASIN" value="{asin}">
      <div id="corePriceDisplay_desktop_feature_div" data-csa-c-asin="{block_asin or asin}">
        <span class="a-price {amount_class}"><span class="a-offscreen">{price}</span></span>
        <span class="basisPrice">{label}<span class="a-price a-text-price" data-a-strike="true"><span class="a-offscreen">{reference}</span></span></span>
      </div>{extra}</body></html>'''


def check(body, *, status=200, headers=None, url=URL, requests=None, timeout=1):
    def reply(request):
        if requests is not None:
            requests.append(request)
        return httpx.Response(status, text=body, headers={"content-type": "text/html", **(headers or {})})
    return asyncio.run(LivePriceService(transport=httpx.MockTransport(reply), timeout_seconds=timeout).check_price(url))


def test_exact_live_primary_price_and_same_offer_mrp_are_integer_units():
    requests = []
    before = time.time()
    result = check(page(), requests=requests)
    assert result["status"] == "available"
    assert result["price_minor"] == 630000 and result["currency"] == "INR"
    assert result["reference_price_minor"] == 1650000 and result["reference_label"] == "MRP"
    assert result["discount_percent"] == 61  # Conservative floor of 61.818%; not a past selling-price claim.
    assert result["product_url"] == URL and result["asin"] == ASIN
    assert result["basis"] == "item_excluding_shipping"
    assert result["failure_reason"] is None
    assert before <= result["checked_at"] <= time.time()
    assert len(requests) == 1
    assert "authorization" not in requests[0].headers and "cookie" not in requests[0].headers


@pytest.mark.parametrize("url", ["http://www.amazon.in/dp/" + ASIN, "https://amazon.in.evil.test/dp/" + ASIN,
    "https://127.0.0.1/dp/" + ASIN, "https://user@amazon.in/dp/" + ASIN,
    "https://amazon.in:8443/dp/" + ASIN, "https://amazon.in/s?k=watch"])
def test_invalid_urls_never_make_network_requests(url):
    requests = []
    assert check(page(), url=url, requests=requests)["status"] == "unavailable"
    assert requests == []


@pytest.mark.parametrize("body", [page(asin="B000000000"), page(market="amazon.com"),
    page().replace(f'<input id="ASIN" value="{ASIN}">', '<input id="ASIN" value="B000000000">'),
    page(block_asin="B000000000"), page().replace('rel="canonical"', 'rel="alternate"'),
    page(extra='<form action="/errors/validateCaptcha"><input id="captchacharacters"></form>')])
def test_identity_changes_or_challenges_are_unavailable(body):
    result = check(body)
    assert result["status"] == "unavailable" and result["price_minor"] is None


@pytest.mark.parametrize("status", [301, 302, 403, 404, 429, 503])
def test_redirects_and_access_failures_are_not_followed(status):
    requests = []
    result = check(page(), status=status, headers={"location": "https://example.invalid"}, requests=requests)
    assert result["status"] == "unavailable" and len(requests) == 1


def test_unavailable_main_product_never_uses_sponsored_or_recommended_prices():
    ads = '<div id="sponsored-products"><span class="priceToPay"><span class="a-offscreen">₹99</span></span></div>'
    result = check(page(price="", reference="", extra=ads))
    assert result["status"] == "unavailable"
    assert result["reference_price_minor"] is None and result["discount_percent"] is None


@pytest.mark.parametrize("kind", ["coupon-price", "installment-price", "member-price", "used-price", "subscription-price", "pricePerUnit", "emi"])
def test_conditional_or_nonretail_amounts_never_become_current_price(kind):
    result = check(page(amount_class="priceToPay " + kind))
    assert result["status"] == "unavailable"


def test_discount_requires_explicit_same_block_reference_and_label():
    result = check(page(label="Other offer:"))
    assert result["status"] == "available" and result["reference_price_minor"] is None
    outside = '<span class="basisPrice">M.R.P.:<span class="a-price a-text-price" data-a-strike="true"><span class="a-offscreen">₹99,999</span></span></span>'
    result = check(page(reference="", extra=outside))
    assert result["status"] == "available" and result["discount_percent"] is None
    result = check(page(reference="₹6,000"))
    assert result["reference_price_minor"] is None and result["discount_percent"] is None


def test_two_percent_reduction_cannot_become_ten_percent_from_coupon_copy():
    body = page(market="amazon.sg", price="S$98.00", reference="S$100.00", label="List price:",
        extra='<div id="coupon">Save up to 10% with a members-only coupon</div>')
    result = check(body, url=f"https://www.amazon.sg/dp/{ASIN}")
    assert result["status"] == "available" and result["discount_percent"] == 2
    assert result["price_minor"] == 9800  # No assumed coupon eligibility or second deduction.


def test_conflicting_primary_prices_fail_closed():
    second = '<div id="corePriceDisplay_mobile_feature_div"><span class="priceToPay"><span class="a-offscreen">₹7,300</span></span></div>'
    assert check(page(extra=second))["status"] == "unavailable"


def test_actual_amazon_split_whole_price_markup():
    body = page().replace('<span class="a-offscreen">₹6,300</span>',
        '<span class="a-offscreen"> </span><span aria-hidden="true"><span class="a-price-symbol">₹</span><span class="a-price-whole">6,300</span></span>')
    assert check(body)["price_minor"] == 630000


@pytest.mark.parametrize("market,text,expected", [("amazon.in", "₹1,23,456.00", 12345600),
    ("amazon.de", "1.299,95 €", 129995), ("amazon.com", "$19.95", 1995),
    ("amazon.co.jp", "￥12,345", 12345), ("amazon.sg", "S$99.90", 9990),
    ("amazon.in", "$99", None), ("amazon.in", "₹99/month", None),
    ("amazon.in", "Save ₹99", None), ("amazon.in", "₹1.2.34", None)])
def test_marketplace_currency_and_decimal_precision(market, text, expected):
    assert _money(text, market) == expected


def test_european_list_price_preserves_label():
    result = check(page(market="amazon.de", price="49,95 €", reference="99,95 €", label="UVP:"),
                   url=f"https://www.amazon.de/dp/{ASIN}")
    assert result["price_minor"] == 4995 and result["currency"] == "EUR"
    assert result["reference_label"] == "List price" and result["discount_percent"] == 50


def test_response_size_and_mime_are_bounded():
    assert check(page(), headers={"content-length": str(MAX_HTML_BYTES + 1)})["status"] == "unavailable"
    assert check(" " * (MAX_HTML_BYTES + 1))["status"] == "unavailable"
    assert check(page(), headers={"content-type": "application/json"})["status"] == "unavailable"


def test_timeout_is_explicit_unavailable():
    async def reply(request):
        await asyncio.sleep(0.2)
        return httpx.Response(200, text=page(), headers={"content-type": "text/html"})
    result = asyncio.run(LivePriceService(transport=httpx.MockTransport(reply), timeout_seconds=0.05).check_price(URL))
    assert result["status"] == "unavailable" and result["price_minor"] is None
    assert result["failure_reason"] == "timeout"


@pytest.mark.parametrize("status,reason", [
    (301, "redirected"), (302, "redirected"), (307, "redirected"),
    (401, "access_blocked"), (403, "access_blocked"), (404, "listing_not_found"),
    (410, "listing_not_found"), (429, "rate_limited"), (500, "response_invalid"), (503, "response_invalid"),
])
def test_upstream_failures_are_classified_without_echoing_upstream_content(status, reason):
    requests = []
    result = check('PRIVATE_UPSTREAM_TEXT api_key=do-not-return', status=status, requests=requests,
                   headers={"location": "https://secret.example.invalid/?token=private-token"})
    assert len(requests) == 1
    assert result["status"] == "unavailable" and result["price_minor"] is None
    assert result["failure_reason"] == reason
    assert result["message"] == PRICE_FAILURE_MESSAGES[reason]
    assert not any(secret in str(result) for secret in ("PRIVATE_UPSTREAM_TEXT", "do-not-return", "private-token"))


def test_invalid_url_does_not_echo_credentials_or_make_requests():
    requests = []
    result = check(page(), url="https://user:secret@amazon.in/dp/" + ASIN, requests=requests)
    assert result["failure_reason"] == "invalid_product_url" and not requests
    assert result["product_url"] is None and "secret" not in str(result)


@pytest.mark.parametrize("body,reason", [
    (page(extra='<form action="/errors/validateCaptcha"><input id="captchacharacters"></form>'), "access_blocked"),
    (page(asin="B000000000"), "identity_mismatch"),
    (page().replace('rel="canonical"', 'rel="alternate"'), "identity_mismatch"),
    (page(block_asin="B000000000"), "identity_mismatch"),
    (page().replace(f'<input id="ASIN" value="{ASIN}">', '<input id="ASIN" value="B000000000">'), "identity_mismatch"),
    (page(price="not a price"), "unverified_price"),
])
def test_html_failure_reasons_keep_identity_and_challenge_checks(body, reason):
    result = check(body)
    assert result["failure_reason"] == reason
    assert result["status"] == "unavailable" and result["price_minor"] is None


def test_real_world_empty_primary_offer_shape_is_not_reported_as_access_blocked():
    # Reduced from the observed Amazon.sg page: exact identity, empty primary
    # price block, unavailable buy box. No raw downloaded HTML is retained here.
    market = "amazon.sg"
    body = f'''<link rel="canonical" href="https://www.{market}/Title/dp/{ASIN}">
      <input id="ASIN" value="{ASIN}"><div id="corePrice_desktop" data-csa-c-asin="{ASIN}"></div>
      <div id="outOfStockBuyBox_feature_div">Currently unavailable.</div>'''
    result = check(body, url=f"https://www.{market}/dp/{ASIN}")
    assert result["failure_reason"] == "no_primary_offer"
    assert result["price_minor"] is None and result["currency"] is None


def test_real_world_changed_variant_takes_priority_over_availability_and_currency():
    # Observed .com response had a different canonical parent and selected ASIN,
    # plus SGD display prices. That amount cannot belong to the requested item.
    body = page(asin="B000000001", market="amazon.com", price="S$24.29", reference="")
    body = body.replace('id="ASIN" value="B000000001"', 'id="ASIN" value="B000000002"')
    result = check(body, url=f"https://www.amazon.com/dp/{ASIN}")
    assert result["failure_reason"] == "identity_mismatch"
    assert result["price_minor"] is None


def test_explicit_geolocated_currency_is_not_relabelled_as_marketplace_currency():
    body = page(market="amazon.com", price="S$24.29", reference="")
    result = check(body, url=f"https://www.amazon.com/dp/{ASIN}")
    assert result["failure_reason"] == "currency_mismatch"
    assert result["price_minor"] is None and result["currency"] is None
    # Supported currency still uses exact existing parsing and _parse contract.
    valid = page(market="amazon.com", price="US$24.29", reference="")
    assert _parse(valid, ASIN, "amazon.com") == (2429, None, None)
    assert check(valid, url=f"https://www.amazon.com/dp/{ASIN}")["failure_reason"] is None


@pytest.mark.parametrize("outer", ['<template>{}</template>', '<div class="coupon-price">{}</div>'])
def test_price_roots_cannot_start_inside_hidden_or_conditional_ancestor_context(outer):
    body = page()
    start, end = body.index('<div id="corePrice'), body.index('</div>') + len('</div>')
    body = body[:start] + outer.format(body[start:end]) + body[end:]
    result = check(body)
    assert result["price_minor"] is None and result["failure_reason"] == "no_primary_offer"


@pytest.mark.parametrize("hidden_price", [
    '<template><span class="priceToPay"><span class="a-offscreen">₹6,300</span></span></template>',
    '<span class="priceToPay"><template><span class="a-offscreen">₹6,300</span></template></span>',
    '<span class="priceToPay"><span class="coupon-price"><span class="a-offscreen">₹6,300</span></span></span>',
])
def test_hidden_or_conditional_prices_inside_an_existing_primary_root_stay_unavailable(hidden_price):
    body = f'''<link rel="canonical" href="{URL}"><input id="ASIN" value="{ASIN}">
      <div id="corePrice_desktop" data-csa-c-asin="{ASIN}">{hidden_price}</div>'''
    result = check(body)
    assert result["status"] == "unavailable" and result["price_minor"] is None


@pytest.mark.parametrize("headers,reason", [
    ({"content-type": "application/json"}, "response_invalid"),
    ({"content-length": "not-a-number"}, "response_invalid"),
    ({"content-length": str(MAX_HTML_BYTES + 1)}, "response_too_large"),
])
def test_response_validation_has_bounded_specific_diagnostics(headers, reason):
    result = check(page(), headers=headers)
    assert result["failure_reason"] == reason
    assert check(" " * (MAX_HTML_BYTES + 1))["failure_reason"] == "response_too_large"


@pytest.mark.parametrize("error,reason", [(httpx.ConnectError, "network_error"), (httpx.ReadTimeout, "timeout")])
def test_network_exceptions_are_sanitized(error, reason):
    def reply(request):
        raise error("PRIVATE upstream credentials must not leak", request=request)
    result = asyncio.run(LivePriceService(transport=httpx.MockTransport(reply)).check_price(URL))
    assert result["failure_reason"] == reason
    assert result["message"] == PRICE_FAILURE_MESSAGES[reason]
    assert "PRIVATE" not in str(result)


def test_checked_at_records_completion_for_early_http_failure(monkeypatch):
    clock = {"now": 10.0}
    monkeypatch.setattr("backend.app.live_prices.time", SimpleNamespace(time=lambda: clock["now"]))
    def reply(request):
        clock["now"] = 20.0
        return httpx.Response(403, text="ignored")
    result = asyncio.run(LivePriceService(transport=httpx.MockTransport(reply)).check_price(URL))
    assert result["checked_at"] == 20.0
    assert result["failure_reason"] in PRICE_FAILURE_REASONS
