# Catalog setup for iOS and the shared API

The native iOS app and the shared API currently use two different catalog paths.
An Amazon Creators key is not needed for either local catalog. A missing
recommendation database can leave native Explore empty even when the shared API
has a populated catalog.

| Service | Catalog | Client access |
| --- | --- | --- |
| Shared API, normally port 8000 | `DATABASE_URL`, locally `prototype.db` | `/v1/commerce/*` and `/v1/explore`, with a configured API bearer token |
| Native capture relay, normally port 8787 | `local-data/recommendation-catalog.db` | `/v1/recommendations` and `/v1/catalog/status`, with `MYNAH_PREVIEW_TOKEN` |

The databases and catalog ZIP are ignored by Git. Share the separately prepared
`dist/mymah-finds-catalogs.zip` with teammates. Pulling the branch alone does not
download that data. The bundle includes source-specific license notices and no
private Library data, credentials or live merchant API content.

## Prepare native Explore

Place the catalog ZIP in `dist/`, install the backend dependencies with
`make setup`, then run:

```sh
.venv/bin/python scripts/prepare_recommendation_bundle.py dist/mymah-finds-catalogs.zip
```

This verifies the bundle, imports six real/historical sources into the relay
database, and builds its search indexes. Those sources contain 263,787 stored
records, including 147,702 Amazon Berkeley Objects records. Current native
recommendations select **ABO only**, requiring an exact ASIN, marketplace and
licensed image from the same record before displaying a match. Other imported
sources and synthetic records do not become native Amazon recommendations.
The relay notices a newly prepared database on its next recommendation request.

If a teammate does not have the shared ZIP, the existing
`.venv/bin/python scripts/prepare_abo_catalog.py` command downloads the public
ABO metadata directly and prepares the same relay database with that source
alone. It needs network access and a download/import wait, but no Amazon API
account or key. Its expected ABO inventory count is 147,702; adding Open Facts
does not increase the native recommendation source count.

Run the relay with its existing server credentials:

```sh
.venv/bin/python scripts/run_capture_preview.py
```

Point the iOS relay configuration/tunnel at this process, rather than the shared
API. Check `GET /v1/catalog/status` with the relay bearer token. It returns:

```json
{"status":"ready","catalog_count":147702,"sources":[{"source_id":"abo","record_count":147702}]}
```

`catalog_count` reports the imported ABO source inventory, not a guarantee that
every row has the required identity/photo or qualifies for a user's request.
A missing, empty or malformed ABO catalog returns `catalog_unavailable`, zero
count and an empty source list, including when only Open Facts is imported.
`/health` still reports AI credential/token configuration independently; it does
not establish that a catalog has been loaded. The status route is authenticated
and does not return paths, secrets or private saved content.

The latest iOS branch opens exact Amazon listing links rather than a generic
search. Its separate price panel checks an exact listing's current primary
offer; missing or blocked offers remain unavailable. Optional public-listing
discovery can supplement uncovered product families after verifying the page's
ASIN, title and image. These live features are separate from the historical ABO
catalog and do not turn its records into current price or stock observations.
See [iOS live pricing](ios-live-pricing.md) for those routes and setup limits.

## Refresh Open Facts without replacing a complete catalog with a sample

The acquisition command downloads complete Open Products Facts and Open Beauty
Facts exports into ignored staging directories. It checks download lengths,
gzip integrity, TSV structure, duplicate identities, size bounds and normalized
records before publishing an acquisition directory. It does not modify either
database. A failed download leaves previous acquisitions and snapshots intact.

```sh
.venv/bin/python scripts/refresh_open_facts.py --dry-run
.venv/bin/python scripts/refresh_open_facts.py --source open_products_facts --minimum-records 25114
.venv/bin/python scripts/refresh_open_facts.py --source open_beauty_facts --minimum-records 40029
.venv/bin/python scripts/refresh_open_facts.py --verify /path/to/completed/acquisition
```

Compare the manifest's archive checksum with the previous download before
importing. The 25 October 2026 checks found the official 21 October exports
unchanged: 25,114 usable Products records and 40,029 Beauty records. They are
verified refreshes, not new products. The existing 2,999-record Food Facts
sample is retained; this command never substitutes an API sample for a full
snapshot. Images and current merchant offers remain excluded.

For a later changed export, verify its manifest, review any reduced record
count, and import its `catalog.jsonl` using the existing normalized dataset
loader with the manifest's `dataset_version`. Open Facts remains available
through the shared commerce catalog; refreshing it does not change the current
ABO-only native recommendation policy. Each source replacement is atomic and
retains licensing; it never modifies Library records. Rebuild the portable
bundle with `make catalog-bundle` after a changed shared catalog is imported.

## Optional Rakuten Ichiba merchant search

The shared API now supports `source=rakuten`. Register an application for the
intended use, then set `RAKUTEN_APPLICATION_ID` and `RAKUTEN_ACCESS_KEY` in the
backend process environment and restart that process. An optional
`RAKUTEN_AFFILIATE_ID` requests Rakuten-provided affiliate links. Credentials
belong on the server; there is no frontend key setup.

```text
GET /v1/commerce/sources
GET /v1/commerce/search?source=rakuten&q=watch&limit=20&offset=0
GET /v1/commerce/items/rakuten/{source_record_id}
```

Use the existing shared API bearer token. Swift can call
`searchProducts(source: .rakuten, query: "watch")`; JavaScript can call
`searchProducts({source: 'rakuten', query: 'watch'})`.

The adapter targets the July 2026 Ichiba API. Rakuten search supports 1–30
results per page, offsets divisible by the limit, and the first 100 pages.
Keywords are bounded to 128 UTF-8 bytes by Rakuten and 100 characters by the
shared route. `next_offset` supplies the next supported page. The HTTP route
also accepts `delivery_country=SG` as an overseas-shipping filter; existing
SDK methods do not expose this filter. Eligibility and final costs still need
confirmation with the merchant. See the [official API reference](https://webservice.rakuten.co.jp/documentation/ichiba-item-search).

The process shares a one-request-per-second gate for each application ID and
rejects excess concurrent requests with a retryable 429. **Run one backend
process per application ID** until an external shared limiter is configured
for multiple workers/hosts. Requests have bounded responses and timeouts; no
automatic retries or persistent result cache consume additional calls.

`configured=true` means both credentials are present, not that account access
has been verified. Source status reports zero stored records because live
responses are not persisted. Missing credentials and rejected access produce
non-retryable 503 errors; temporary throttling produces 429 and service failures
produce retryable 503 errors. Local catalogs remain available independently.

## Frontend handoff

- Treat `data_kind=merchant_api`, `retrieval=live_api` and `persistence=none` as
  distinct from local datasets. Rakuten products are available through the
  shared commerce API; they are not automatically added to native Explore or
  sent to AI. Dataset exports reject Rakuten.
- Display the supplied merchant name and product/affiliate URL. The current
  native detail action validates exact Amazon listings, so a Rakuten result
  needs its own merchant action before being displayed there.
- Format JPY as a zero-decimal currency: a `price_minor` of 12800 is ¥12,800.
  Do not divide every currency by 100. Unknown prices/shipping remain unknown,
  and a source timestamp does not guarantee availability or checkout price.
- Preserve `provenance.attribution` and its link. Rakuten requires visible
  credit; follow its [credit guide](https://webservice.rakuten.co.jp/guide/credit)
  and [application terms](https://webservice.rakuten.co.jp/guide/rule).
- Handle credential failures separately from rate limits. Keep licensed local
  discovery available when an optional live provider is unavailable.

Real Rakuten requests require backend credentials and account access. Mocked
provider tests validate the adapter and API contracts; they do not establish
live account eligibility or merchant availability.

The restored relay database contains 263,787 real/historical records, while the
shared catalog retains all 284,368 records including synthetic sources. The
merged relay's HTTP routes reported a ready ABO inventory of 147,702 and returned
12 digital-watch matches, each with its exact ASIN link, same-record photo and
citation. Prices remained unknown. This check used an isolated price store and
made no AI or live-price calls; it was not a physical-device acceptance run.
