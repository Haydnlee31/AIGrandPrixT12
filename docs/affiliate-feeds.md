# Mymah Finds affiliate feed adapters

Mymah Finds accepts authorized impact.com and CJ merchant catalogs through a bounded local-file import adapter. It also has a credential-ready CJ feed-summary client. Import parsing does not publish a catalog, grant a data license, or enable AI use. The backend catalog admission process must record the approved advertiser, catalog, permitted uses, source timestamp, freshness window, and withdrawal policy before exposing offers.

No live credentials, merchant feed records, or affiliate account registrations are included. The automated tests use invented products and mocked HTTP responses. There is no scheduled affiliate download, impact.com API client, CJ full-feed subscription, or automated advertiser approval workflow yet.

## Obtain an approved export

For impact.com, join the relevant merchant program and obtain permission for the intended use. In the partner account, open **Manage → More → My Products**, select the catalog, and choose **Download Impact Format**. Record the advertiser identity, catalog ID, and source update time from the catalog details. Downloading the advertiser's original format is also possible, but its columns need an explicit mapping. [Official download instructions](https://help.impact.com/partner/what-would-you-like-to-learn-about/platform-features/marketing-content/product-marketplace-and-catalogs/download-product-catalogs-as-a-partner)

Choose CSV or TAB in **Settings → Technical → Data Feeds → Product Feed**. Decompress `.gz` downloads locally before importing; XML and compressed archives are not accepted by this adapter. [Official file preferences](https://help.impact.com/partner/what-would-you-like-to-learn-about/platform-features/marketing-content/product-marketplace-and-catalogs/set-product-catalog-feed-preferences-as-a-partner)

For CJ, obtain a publisher account, the required merchant permissions, a Personal Access Token, your company ID, and a PID owned by that company. The official API endpoint is `https://ads.api.cj.com/query`, authenticated with `Authorization: Bearer <token>`. Keep the token on the backend. [CJ API overview and authentication](https://docs.cj.com/docs/product-feed-api)

Use CJ's `productFeeds` query to identify catalogs and their advertiser names. For an approved catalog, save a `products` query response as UTF-8 JSON, requesting `advertiserId`, `catalogId`, `id`, `title`, `description`, `price { amount currency }`, and `linkCode(pid: "YOUR_PID") { clickUrl }`. Filter to the selected advertiser and catalog; handle pagination explicitly. The adapter accepts the documented `data.products.resultList` structure and the corresponding `shoppingProducts` wrapper. A product response does not include the advertiser name in the common-field example, so supply the verified name as import context. [CJ product search and response examples](https://docs.cj.com/docs/productfeed-api-search), [query filters and pagination arguments](https://docs.cj.com/docs/productfeed-api-search-query)

CJ API visibility can include advertisers without an established relationship. It is discovery metadata, not evidence that Mymah Finds may publish or retain those feeds. Keep catalog admission separate from discovery.

## Parse an export

Run from the repository root using the project Python environment:

```python
from backend.app.catalog.affiliates import AffiliateFeedError, parse_feed

items = parse_feed(
    "impact",
    "/absolute/path/approved-catalog.tsv",
    catalog_id="CATALOG_ID_FROM_ACCOUNT",
    merchant_id="ADVERTISER_ID_FROM_ACCOUNT",
    merchant_name="Verified merchant display name",
    # Optional only when the approved catalog has one known currency:
    currency="SGD",
    max_rows=10_000,
)
```

This produces normalized dictionaries for the backend importer; it does not write to the database. `AffiliateFeedError.code` and `.row` identify failures without echoing raw feed content. Parse the entire file successfully before publishing any part of it. All text remains untrusted source data; no description is interpreted as an instruction or rendered as executable markup by the adapter.

The publishing CLI accepts one **complete approved catalog snapshot of at most 10,000 rows**. Each successful import replaces the existing snapshot for that source and catalog ID, including removing products absent from the new file. Do not import API pages or file chunks separately under the same catalog ID: each would remove products imported by the previous chunk. Obtain a complete, separately approved smaller catalog within the limit, or add a staging/bulk importer that validates all pages and publishes the complete snapshot atomically. That bulk workflow is not implemented yet.

Supported containers are `.csv`, `.tsv`, `.tab`, and `.json`. CSV uses commas and TSV/TAB use tabs. For a differently named text file, pass `delimiter=","` or `delimiter="\t"`. UTF-8 with or without a byte-order mark is accepted. JSON can be an array of records; CJ can additionally use the API wrappers above. JSON containing GraphQL errors is rejected even if partial data is present.

One call imports one explicitly identified catalog. Source catalog IDs, advertiser IDs/names, and currencies in rows must agree with supplied context. A missing merchant ID or name requires explicit approved-catalog context; product brand is never substituted for merchant identity.

## Default mappings and custom exports

The impact.com default mapping uses the standardized Impact Format field names. The CJ default mapping follows its common product response. [Impact field reference](https://help.impact.com/partner/what-would-you-like-to-learn-about/platform-features/marketing-content/product-marketplace-and-catalogs/download-product-catalogs-as-a-partner), [CJ response fields](https://docs.cj.com/docs/productfeed-api-search)

| Normalized input | impact.com default column | CJ default path |
| --- | --- | --- |
| `product_id` | `Unique Merchant SKU` | `id` |
| `variant_id` | `Unique Merchant SKU` | Explicit mapping if supplied |
| `catalog_id` | Explicit import context | `catalogId` |
| `merchant_id` | Explicit import context | `advertiserId` |
| `merchant_name` | Explicit import context | Explicit import context |
| `title` | `Product Name` | `title` |
| `description` | `Product Description` | `description` |
| `price` | `Current Price` | `price.amount` |
| `currency` | `Currency` | `price.currency` |
| `url` | `Product URL` | `linkCode.clickUrl` |
| `image_url` | `Image URL` | Explicit mapping if supplied |
| `brand` | `Manufacturer` | Explicit mapping if supplied |
| `category` | `Category` | Explicit mapping if supplied |
| `availability` | `Stock Availability` | Explicit mapping if supplied |
| `condition` | `Condition` | Explicit mapping if supplied |

Impact additionally preserves `EAN`, `UPC`, `ISBN`, `MPN`, `Parent SKU`, `Color`, `Size`, `Size Unit of Measure`, `Material`, and `Gender` as attributes. `EAN` maps to `gtin`; UPC remains separately identified as `upc`. Nothing is inferred from a title. An explicitly provided SKU remains the variant key. Product, merchant, catalog, and variant identifiers remain in provenance.

For advertiser-specific exports, provide `column_mapping={normalized_input: source_column}`. This overrides the source default. A mapping value of `None` disables an optional mapping. Paths can address nested JSON objects; a literal CSV header such as `price.amount` takes precedence over path traversal.

```python
items = parse_feed(
    "cj", "/absolute/path/approved-export.csv", catalog_id="CATALOG_ID",
    merchant_id="ADVERTISER_ID", merchant_name="Verified advertiser name",
    column_mapping={
        "product_id": "merchant_sku", "title": "product_title",
        "price": "sale_price", "currency": "currency_code",
        "url": "affiliate_click_url", "image_url": "https_image",
        "gtin": "barcode", "mpn": "manufacturer_part_number",
        "brand": "brand", "color": "color", "size": "size",
        "source_updated_at": "updated_at",
    },
)
```

Additional mapping targets are `upc`, `isbn`, `parent_sku`, `size_unit`, `material`, and `gender`. `source_updated_at` must be an ISO 8601 timestamp with a timezone, such as `2026-10-24T08:00:00Z`; a missing timestamp stays null. These custom paths are operator-specified mappings, not a claim that CJ returns all of these fields under these names.

## Normalization and bounds

- `source_record_id`, `product_key`, and `offer.id` share a deterministic hash of source, catalog, advertiser, external product, and explicit variant ID. Records from different catalogs or sources cannot silently merge. Identical normalized duplicates collapse; conflicting duplicates reject the entire parse.
- Missing prices and currencies stay null. A supplied price requires a recognized currency. Money uses exact decimal arithmetic; fractional minor units reject rather than round. Supported two-decimal currencies: USD, SGD, EUR, GBP, AUD, CAD, NZD, HKD, CNY, MYR, THB, PHP, IDR, INR, CHF, SEK, NOK, DKK, PLN, CZK, AED, SAR, ZAR, BRL, MXN, TWD. JPY/KRW use zero decimals; KWD/BHD/OMR use three. No exchange-rate conversion occurs.
- Only explicit `in stock`/`in_stock` and `out of stock`/`out_of_stock` values become known availability. Other values remain `unknown` and are preserved in `attributes.source_availability`. Missing shipping cost stays null.
- `offer.observed_at` is import observation time, not proof the merchant recently updated its price. `offer.expires_at` stays null in this adapter. The publishing layer must use an approved source timestamp and bounded freshness policy; downloading an old file again must not refresh its commercial claims.
- Product links must be public HTTP(S) URLs without credentials; image links, when supplied, must use HTTPS. Literal local/private IPs, local hostnames, ambiguous numeric hosts, control characters, and nonstandard ports are rejected. Affiliate query strings remain intact. DNS is not resolved, redirects are not followed, and no product or image URL is fetched.
- A file is limited to 32 MiB, 128 columns, 16,384 characters per field, 131,072 characters per record, and six nested levels. The standalone parser defaults to 10,000 rows and can be configured up to 50,000; the publishing CLI remains limited to 10,000. Both duplicate and unique rows count toward the limit. Larger catalogs require a future staging/bulk import workflow, not separate snapshot imports of individual chunks.
- Empty feeds, invalid UTF-8, malformed rows, duplicate headers/JSON keys, mismatched catalog/merchant/currency context, and conflicting records fail closed. No partial output is returned.

## CJ feed-summary client

```python
import os
from backend.app.catalog.affiliates import list_cj_catalogs

page = list_cj_catalogs(
    os.environ["CJ_PERSONAL_ACCESS_TOKEN"],
    os.environ["CJ_COMPANY_ID"],
    partner_ids=["APPROVED_ADVERTISER_COMPANY_ID"],
    limit=100,
    offset=1,
)
```

The helper makes one read-only `productFeeds` query to the fixed CJ HTTPS endpoint using explicit advertiser IDs. Its variable types are `companyId: ID!`, `partnerIds: [ID!]`, `limit: Int`, and `offset: Int`, as explicitly listed in CJ's [productFeeds argument table](https://docs.cj.com/docs/productfeed-api-search-query#productfeeds). It returns `totalCount`, `count`, and `resultList`; it does not follow pagination, download products, import records, or authorize an advertiser. HTTP redirects are rejected, timeouts and response bytes are bounded, environment proxy settings are ignored, and raw upstream error text is excluded from exceptions. The application must manage retries, rate budgets, pagination, and catalog approval.

For future impact.com API automation, the official partner API uses an Account SID/Auth Token pair with HTTP Basic authentication over HTTPS. The adapter does not currently call it; use the approved downloadable file route. [Official impact authentication](https://integrations.impact.com/partner-api-reference/readme/authentication), [catalog API overview](https://integrations.impact.com/partner-api-reference/reference/catalogs)

## Rights and frontend handoff

An affiliate membership or API token is not a blanket license for LLM prompts, embeddings, retrieval, model training, redistribution, or indefinite storage. Record the actual network and merchant permissions separately for display/search, retention, derived representations, and model access. Keep unapproved uses disabled and honor withdrawal/deletion requirements. Do not send product text to a model merely because normalization succeeded.

Chrome and iOS consume the same backend offer contract. Keep affiliate credentials and feed imports out of both clients. When catalog UI is added, preserve merchant attribution, currency, source freshness, unknown availability/shipping, and the approved affiliate URL. Render feed text as text and use the backend's expiry/revocation decisions. Any network- or merchant-required affiliate disclosures remain part of launch readiness.
