"""On-demand public Amazon listing prices, with exact product identity checks.

Only the primary product's explicitly marked price-to-pay is considered. Ads,
recommendations, coupons, membership offers and installment amounts are never
substituted for an unavailable price. No login, cookies or challenge bypass.
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation
from html.parser import HTMLParser
import re
import time
from urllib.parse import urlsplit

import httpx

from .amazon_catalog_identity import AMAZON_MARKETS, amazon_asin

MAX_HTML_BYTES = 3 * 1024 * 1024
PRICE_FAILURE_MESSAGES = {
    "invalid_product_url": "Use an exact Amazon product link.",
    "access_blocked": "Amazon restricted this automated price check. Open the product on Amazon.",
    "rate_limited": "Amazon temporarily limited price requests. Wait before trying again.",
    "listing_not_found": "Amazon did not return this product listing. Open Amazon to check whether it is still available.",
    "redirected": "Amazon redirected this listing. Open Amazon to confirm the exact product before tracking it.",
    "response_invalid": "Amazon returned a page this price checker could not safely read. Open Amazon to check.",
    "response_too_large": "The Amazon page exceeded this price check's size limit. Open Amazon to check.",
    "timeout": "The Amazon price check timed out. Try again later.",
    "network_error": "The price checker could not reach Amazon. Try again later.",
    "identity_mismatch": "The page did not confirm this exact Amazon product. Open Amazon to check the listing and variant.",
    "no_primary_offer": "Amazon did not show a current primary offer for this exact listing. Availability may depend on location.",
    "currency_mismatch": "The displayed currency could not be matched safely to this price check. Open Amazon to confirm the price and currency.",
    "unverified_price": "A current price could not be verified. Open Amazon to check.",
}
PRICE_FAILURE_REASONS = frozenset(PRICE_FAILURE_MESSAGES)
_ROOT_IDS = {"corePriceDisplay_desktop_feature_div", "corePriceDisplay_mobile_feature_div",
             "corePrice_feature_div", "corePrice_desktop", "corePrice_mobile",
             "priceblock_ourprice", "priceblock_dealprice", "priceblock_saleprice"}
_LEGACY_IDS = {"priceblock_ourprice", "priceblock_dealprice", "priceblock_saleprice"}
_VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}
_IGNORED = {"script", "style", "iframe", "noscript", "template"}
_BLOCKED = re.compile(r"coupon|installment|subscription|subscribe|prime.?exclusive|member.?price|used.?price|renewed|priceperunit|\bppu\b|\bemi\b", re.I)
_CURRENCY = {
    "amazon.com": ("USD", ("US$", "$")), "amazon.co.uk": ("GBP", ("£",)),
    "amazon.ca": ("CAD", ("CDN$", "CA$", "C$", "$")),
    "amazon.de": ("EUR", ("€",)), "amazon.fr": ("EUR", ("€",)),
    "amazon.it": ("EUR", ("€",)), "amazon.es": ("EUR", ("€",)),
    "amazon.nl": ("EUR", ("€",)), "amazon.com.be": ("EUR", ("€",)),
    "amazon.co.jp": ("JPY", ("￥", "¥", "円")), "amazon.in": ("INR", ("₹",)),
    "amazon.com.au": ("AUD", ("AU$", "A$", "$")), "amazon.sg": ("SGD", ("S$", "$")),
    "amazon.com.br": ("BRL", ("R$",)), "amazon.com.mx": ("MXN", ("MX$", "$")),
    "amazon.ae": ("AED", ("AED", "د.إ")), "amazon.sa": ("SAR", ("SAR", "ر.س")),
    "amazon.se": ("SEK", ("kr",)), "amazon.pl": ("PLN", ("zł",)),
    "amazon.com.tr": ("TRY", ("TL", "₺")), "amazon.eg": ("EGP", ("EGP", "جنيه")),
}


def _identity(value: object) -> tuple[str, str, str] | None:
    if not isinstance(value, str) or len(value) > 4000:
        return None
    try:
        url = urlsplit(value)
        host = (url.hostname or "").lower().removeprefix("www.")
        if (url.scheme != "https" or host not in AMAZON_MARKETS or host not in _CURRENCY
                or url.username or url.password or url.port not in (None, 443)):
            return None
        asin = amazon_asin(value)
        if not asin:
            return None
        return asin, host, f"https://www.{host}/dp/{asin}"
    except ValueError:
        return None


@dataclass
class _Node:
    tag: str
    attrs: dict[str, str]
    parent: "_Node | None" = None
    children: list = field(default_factory=list)

    @property
    def classes(self):
        return set(self.attrs.get("class", "").split())

    def descendants(self):
        yield self
        for child in self.children:
            if isinstance(child, _Node):
                yield from child.descendants()

    def text(self):
        if self.tag in _IGNORED:
            return ""
        return "".join(child.text() if isinstance(child, _Node) else child for child in self.children).strip()

    def restricted(self):
        current = self
        while current:
            if current.tag in _IGNORED or _BLOCKED.search(current.attrs.get("id", "") + " " + current.attrs.get("class", "")):
                return True
            current = current.parent
        return False


class _Page(HTMLParser):
    """Keep only bounded primary price blocks; scripts/ads cannot supply prices."""
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.roots: list[_Node] = []
        self.stack: list[tuple[str, _Node | None, bool]] = []
        self.canonical: list[str] = []
        self.asins: set[str] = set()
        self.blocked = False
        self.nodes = 0

    def handle_starttag(self, tag, attrs):
        if len(self.stack) > 200:
            raise ValueError("Product page nesting too deep")
        data = {key: value or "" for key, value in attrs}
        if tag == "link" and "canonical" in data.get("rel", "").split():
            self.canonical.append(data.get("href", ""))
        if tag == "input" and (data.get("id") == "ASIN" or data.get("name") == "ASIN"):
            self.asins.add(data.get("value", ""))
        if data.get("id", "").lower() in {"captchacharacters", "auth-captcha-image"}:
            self.blocked = True
        if tag == "form" and "validatecaptcha" in data.get("action", "").lower():
            self.blocked = True
        parent = self.stack[-1][1] if self.stack else None
        excluded = ((self.stack[-1][2] if self.stack else False) or tag in _IGNORED
                    or bool(_BLOCKED.search(data.get("id", "") + " " + data.get("class", ""))))
        node = None
        if not excluded and data.get("id") in _ROOT_IDS and parent is None:
            node = _Node(tag, data)
            self.roots.append(node)
        elif parent is not None:
            node = _Node(tag, data, parent)
            parent.children.append(node)
        if node is not None:
            self.nodes += 1
            if self.nodes > 8000 or len(self.stack) > 200:
                raise ValueError("Price block too large")
        if tag not in _VOID:
            self.stack.append((tag, node, excluded))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in _VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                break

    def handle_data(self, value):
        if self.stack and self.stack[-1][1] is not None and self.stack[-1][0] not in _IGNORED:
            self.stack[-1][1].children.append(value)


def _money(text: str, marketplace: str) -> int | None:
    currency, symbols = _CURRENCY[marketplace]
    text = text.replace("\xa0", " ").replace("\u202f", " ").strip()
    # Require the marketplace's displayed symbol/code; reject other currencies,
    # explanatory copy, installment suffixes and multiple amounts.
    matched = False
    for symbol in sorted((*symbols, currency), key=len, reverse=True):
        if symbol in text:
            text = text.replace(symbol, "")
            matched = True
            break
    text = text.strip().replace(" ", "")
    if not matched or not re.fullmatch(r"\d[\d,.]*", text):
        return None
    decimals = 0 if currency == "JPY" else 2
    if decimals and re.search(r"[.,]\d{2}$", text):
        point = max(text.rfind("."), text.rfind(","))
        whole, fraction = text[:point], text[point + 1:]
        if not re.fullmatch(r"(?:\d+|\d{1,3}(?:[,.]\d{3})+|\d{1,2}(?:,\d{2})*,\d{3})", whole):
            return None
        normalized = whole.replace(",", "").replace(".", "") + "." + fraction
    else:
        # Fractions of unsupported precision must not turn into huge prices.
        if not re.fullmatch(r"(?:\d+|\d{1,3}(?:[,.]\d{3})+|\d{1,2}(?:,\d{2})*,\d{3})", text):
            return None
        normalized = text.replace(",", "").replace(".", "")
    try:
        amount = Decimal(normalized) * (10 ** decimals)
        if amount != amount.to_integral_value() or not 0 < amount <= 1_000_000_000_000:
            return None
        return int(amount)
    except InvalidOperation:
        return None


def _amount(node: _Node, marketplace: str) -> int | None:
    # Do not let a hidden/conditional descendant supply an amount through an
    # otherwise visible price container. Ambiguous containers fail closed.
    if any(child.restricted() for child in node.descendants()):
        return None
    values = {_money(child.text(), marketplace) for child in node.descendants() if "a-offscreen" in child.classes}
    values.discard(None)
    if len(values) == 1:
        return values.pop()
    if values:
        return None
    symbols = [child.text() for child in node.descendants() if "a-price-symbol" in child.classes]
    whole = [child.text() for child in node.descendants() if "a-price-whole" in child.classes]
    fractions = [child.text() for child in node.descendants() if "a-price-fraction" in child.classes]
    if len(symbols) == len(whole) == 1 and len(fractions) <= 1:
        number = whole[0].rstrip(".,")
        if fractions:
            number += "." + fractions[0]
        return _money(symbols[0] + number, marketplace)
    return _money(node.text(), marketplace)


def _reference_label(text: str) -> str | None:
    if re.search(r"M\.?R\.?P\.?", text, re.I):
        return "MRP"
    if re.search(r"list price|RRP|UVP|prix conseill|precio recomendado|prezzo consigliato", text, re.I):
        return "List price"
    if re.search(r"\bwas:", text, re.I):
        return "Was"
    return None


def _different_currency(text: str, marketplace: str) -> bool:
    """Recognize an explicit foreign currency without converting its amount.

    Longest-symbol matching distinguishes S$/US$/AU$ from a bare dollar sign.
    Shared symbols are not enough to assert a mismatch for a matching market.
    """
    expected = _CURRENCY[marketplace][0]
    symbols = {}
    for currency, tokens in _CURRENCY.values():
        for token in (currency, *tokens):
            symbols.setdefault(token, set()).add(currency)
    pattern = "|".join(re.escape(token) for token in sorted(symbols, key=len, reverse=True))
    return any(expected not in symbols[match.group()] for match in re.finditer(pattern, text))


def _parse_with_reason(html: str, asin: str, marketplace: str):
    page = _Page()
    page.feed(html)
    if page.blocked:
        return None, "access_blocked"
    if not page.canonical:
        return None, "identity_mismatch"
    identities = [_identity(url) for url in page.canonical]
    if any(not identity or identity[:2] != (asin, marketplace) for identity in identities):
        return None, "identity_mismatch"
    if page.asins and page.asins != {asin}:
        return None, "identity_mismatch"
    offers: list[tuple[int, tuple[int, str] | None]] = []
    attempted_amount, foreign_currency, wrong_block_identity = False, False, False
    for root in page.roots:
        if root.attrs.get("data-csa-c-asin") not in (None, "", asin):
            wrong_block_identity = True
            continue
        if root.restricted():
            continue
        if re.search(r"prime (?:exclusive )?price|members?[- ]only price|subscribe.{0,4}save|price with coupon|\bused\b|pre-owned|refurbished|renewed", root.text(), re.I):
            continue
        prices, references = set(), set()
        for node in root.descendants():
            if node.restricted():
                continue
            if node.attrs.get("id") in _LEGACY_IDS or node.classes & {"priceToPay", "apexPriceToPay", "apex-pricetopay-value"}:
                attempted_amount = True
                amount = _amount(node, marketplace)
                if amount is not None:
                    prices.add(amount)
                elif _different_currency(node.text(), marketplace):
                    foreign_currency = True
            if "a-text-price" in node.classes and node.attrs.get("data-a-strike") == "true":
                context = node.parent.text() if node.parent else root.text()
                label = _reference_label(context)
                if label:
                    amount = _amount(node, marketplace)
                    if amount is not None:
                        references.add((amount, label))
        if len(prices) == 1:
            price = prices.pop()
            reference = references.pop() if len(references) == 1 else None
            offers.append((price, reference if reference and reference[0] > price else None))
    if not offers:
        reason = ("identity_mismatch" if wrong_block_identity else "currency_mismatch" if foreign_currency
                  else "unverified_price" if attempted_amount else "no_primary_offer")
        return None, reason
    if len({offer[0] for offer in offers}) != 1:
        return None, "unverified_price"
    references = {offer[1] for offer in offers if offer[1] is not None}
    reference = references.pop() if len(references) == 1 else None
    return (offers[0][0], reference[0] if reference else None, reference[1] if reference else None), None


def _parse(html: str, asin: str, marketplace: str) -> tuple[int, int | None, str | None] | None:
    """Compatibility wrapper; callers needing diagnostics use the same parse."""
    return _parse_with_reason(html, asin, marketplace)[0]


class LivePriceService:
    def __init__(self, *, transport: httpx.AsyncBaseTransport | None = None, timeout_seconds: float = 10):
        self.transport = transport
        self.timeout = max(0.05, min(timeout_seconds, 12))
        self.slots = asyncio.Semaphore(4)

    async def check_price(self, url: str) -> dict:
        identity = _identity(url)
        result = {"status": "unavailable", "product_url": identity[2] if identity else None,
                  "asin": identity[0] if identity else None, "marketplace": identity[1] if identity else None,
                  "price_minor": None, "currency": None, "reference_price_minor": None,
                  "reference_label": None,
                  "discount_percent": None, "checked_at": time.time(), "basis": "item_excluding_shipping",
                  "failure_reason": "unverified_price", "message": PRICE_FAILURE_MESSAGES["unverified_price"]}

        def failure(reason):
            result.update(failure_reason=reason, message=PRICE_FAILURE_MESSAGES[reason], checked_at=time.time())
            return result

        if not identity:
            return failure("invalid_product_url")
        asin, marketplace, target = identity
        try:
            async with asyncio.timeout(self.timeout):
                async with self.slots:
                    async with httpx.AsyncClient(transport=self.transport, trust_env=False, follow_redirects=False,
                            timeout=httpx.Timeout(self.timeout, connect=min(4, self.timeout)),
                            headers={"User-Agent": "MynahFinds/1.0 (public product price check)", "Accept": "text/html"}) as client:
                        async with client.stream("GET", target) as response:
                            content_type = response.headers.get("content-type", "").split(";", 1)[0].lower()
                            if response.status_code in {401, 403}:
                                return failure("access_blocked")
                            if response.status_code == 429:
                                return failure("rate_limited")
                            if response.status_code in {404, 410}:
                                return failure("listing_not_found")
                            if 300 <= response.status_code < 400:
                                return failure("redirected")
                            if response.status_code != 200 or content_type not in {"text/html", "application/xhtml+xml"}:
                                return failure("response_invalid")
                            length = response.headers.get("content-length")
                            if length and not length.isdigit():
                                return failure("response_invalid")
                            if length and int(length) > MAX_HTML_BYTES:
                                return failure("response_too_large")
                            data = bytearray()
                            async for chunk in response.aiter_bytes(chunk_size=64 * 1024):
                                if len(data) + len(chunk) > MAX_HTML_BYTES:
                                    return failure("response_too_large")
                                data.extend(chunk)
                            parsed, reason = _parse_with_reason(data.decode("utf-8", errors="replace"), asin, marketplace)
            if parsed:
                price, reference, label = parsed
                # Round down so our claim never exceeds the observed reduction.
                discount = (reference - price) * 100 // reference if reference else None
                result.update(status="available", price_minor=price, currency=_CURRENCY[marketplace][0],
                              reference_price_minor=reference, reference_label=label, discount_percent=discount,
                              failure_reason=None,
                              message="Amazon item price; shipping and eligibility may vary.")
            else:
                failure(reason)
        except (TimeoutError, httpx.TimeoutException):
            failure("timeout")
        except httpx.HTTPError:
            failure("network_error")
        except (ValueError, RecursionError):
            failure("response_invalid")
        finally:
            result["checked_at"] = time.time()
        return result


_service = LivePriceService()


async def check_price(url: str) -> dict:
    return await _service.check_price(url)
