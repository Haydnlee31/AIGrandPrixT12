"""Exact Amazon identity and photos from the same imported ABO record.

ABO is historical metadata. An ASIN link identifies a product page, but does not
establish current availability, pricing, or shipping eligibility.
"""
import re
from urllib.parse import urlsplit


AMAZON_MARKETS = frozenset({
    "amazon.com", "amazon.co.uk", "amazon.ca", "amazon.de", "amazon.fr",
    "amazon.it", "amazon.es", "amazon.co.jp", "amazon.in", "amazon.com.au",
    "amazon.com.br", "amazon.com.mx", "amazon.ae", "amazon.sa", "amazon.sg",
    "amazon.nl", "amazon.se", "amazon.pl", "amazon.com.tr", "amazon.eg",
    "amazon.com.be",
})
ABO_IMAGE_HOST = "amazon-berkeley-objects.s3.us-east-1.amazonaws.com"


def amazon_asin(value):
    """Read an explicit product path only, never a search query or redirect."""
    if not isinstance(value, str):
        return None
    try:
        url = urlsplit(value)
        host = (url.hostname or "").removeprefix("www.")
        if url.scheme != "https" or host not in AMAZON_MARKETS or url.username or url.password or url.port not in (None, 443):
            return None
    except ValueError:
        return None
    match = re.search(r"/(?:dp|gp/product)/([A-Z0-9]{10})(?:/|$)", url.path)
    return match.group(1) if match else None


def amazon_record_identity(record):
    """Return ASIN, exact marketplace URL and same-record licensed photo."""
    if record.get("source_id") != "abo" or record.get("data_kind") != "open_dataset":
        return None
    provenance = record.get("provenance") or {}
    asin = provenance.get("original_item_id")
    domain = provenance.get("domain_name")
    if not isinstance(asin, str) or not re.fullmatch(r"[A-Z0-9]{10}", asin) or domain not in AMAZON_MARKETS:
        return None
    # These fields are retained by the reviewed importer from the same row.
    # A hash, barcode or image id is never accepted in place of its ASIN.
    if provenance.get("source_record_id") != asin:
        return None
    image = (record.get("offer") or {}).get("image_url")
    if not isinstance(image, str) or not (record.get("attributes") or {}).get("main_image_id"):
        return None
    try:
        url = urlsplit(image)
        if (url.scheme != "https" or url.hostname != ABO_IMAGE_HOST or url.username or url.password
                or url.port not in (None, 443) or url.query or url.fragment
                or not re.fullmatch(r"/images/(?:small|original)/[0-9a-f]{2}/[0-9a-f]+\.(?:jpg|png)", url.path)):
            return None
    except ValueError:
        return None
    return asin, f"https://www.{domain}/dp/{asin}", image
