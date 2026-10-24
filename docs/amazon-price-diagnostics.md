# Diagnosing unavailable Amazon prices

Reviewed against `codex/ios-app` at `a71580e` on 25 October 2026. The existing
checker makes an unauthenticated request to an exact Amazon listing; it does
not use an Amazon, Astra or OpenAI API key. Licensed ABO catalog records do not
include current retail prices or guarantee that an old variant is still sold.

## The reported iPhone

The supplied `https://amzn.asia/d/0aUtbZGf` returned a 301 redirect to the exact
Singapore listing [`B0BDJ7DZ5Q`](https://www.amazon.sg/dp/B0BDJ7DZ5Q), Apple
iPhone 14 Pro, 1 TB, Deep Purple. The direct page returned HTTP 200 with the
correct canonical ASIN and primary ASIN input, no detected CAPTCHA, an empty
primary-price block, and visible “Currently unavailable” copy. The backend
therefore had no current primary offer to report. This describes the page
served to the development machine; another delivery/account context may differ.

The price checker accepts direct `/dp/ASIN` or `/gp/product/ASIN` URLs on its
allowed Amazon marketplaces. It does not accept `amzn.asia` as an exact product
identity. The short link was resolved separately for this investigation;
automatic general redirect following was not added. Native Explore already
passes the exact Amazon URL in its recommendation result to the price panel.

A separate check of Amazon India `B07FCLBWD9` succeeded, returning INR 6,300
against MRP 16,500 at the time of the check. That establishes that the fetch and
price parser can work for a matching listing with a primary offer; it is not a
promise of continuing availability or a historical price drop.

Additional bounded checks found Amazon.com `B07YQFTYFM` returning a different
canonical and selected variant, with an SGD amount on the US domain, and
Amazon.in `B08F7W4TL1` returning a different ASIN. Rejecting these responses
prevents a price for another product or currency from being recorded as a drop.

## Diagnostic response changes

`POST /v1/price-check` now includes `failure_reason`. Available results use
`null`; unavailable results use one of the finite codes below. Failed watch
checks retain the same code through `/v1/price-watch` and persisted lists. The
existing native view already displays the backend's `message` field, so it
receives the clearer explanation without a new settings screen.

| Reason | Meaning |
| --- | --- |
| `invalid_product_url` | No supported exact Amazon product identity was supplied. |
| `access_blocked` | Access was denied or a recognized CAPTCHA was returned. |
| `rate_limited` | Amazon returned HTTP 429. |
| `listing_not_found` | Amazon returned HTTP 404 or 410. |
| `redirected` | The exact listing request returned a redirect; it was not followed. |
| `identity_mismatch` | Canonical, primary ASIN or price-block identity did not confirm the requested item. |
| `no_primary_offer` | The verified listing supplied no accepted current primary offer. |
| `currency_mismatch` | A displayed currency could not be safely treated as the marketplace currency. |
| `timeout`, `network_error` | The bounded request failed to complete or reach Amazon. |
| `response_invalid`, `response_too_large` | The response could not be safely processed within the existing bounds. |
| `unverified_price` | An amount was ambiguous, conditional or otherwise could not be verified. |

Messages are static, bounded application copy. Raw upstream HTML, redirects,
cookies and exception strings are never returned or stored in failed watches.
A failed check leaves current price, drop and target-hit signals empty while
preserving prior observations. A later successful check clears the failure
reason. No challenge solving, cookie reuse, proxy rotation, identity substitution
or currency relabeling was introduced.

## API options if page access is genuinely blocked

An API can provide another retrieval path, but cannot guarantee that this exact
iPhone has a current offer. Keep the ASIN, marketplace, seller/condition,
currency and observation time explicit before recording a comparable price.

- **Rainforest API** documents support for `amazon.sg` and accepts an exact
  URL or ASIN/marketplace pair. Its official trial page advertises 100 evaluation
  requests without a credit card. A Rainforest key would be needed for a small
  live evaluation; none was used here. It is a third-party data service, and
  Singapore does not support its postcode-localization API. See [domain support](https://docs.trajectdata.com/rainforestapi/product-data-api/reference/amazon-domains),
  [product request parameters](https://docs.trajectdata.com/rainforestapi/product-data-api/parameters/product),
  and [trial details](https://trajectdata.com/discover-rainforest-api/).
- **Keepa** offers history and offer data through a paid API key, but its
  documented marketplace list does not include Singapore. Historical or
  cached observations must not be labelled current primary offers. See its
  [product API](https://keepa.com/api-docs/product.html).
- **Amazon Creators API** has account eligibility requirements. Amazon.sg's
  Associates-program conditions also require Amazon's agreement for price
  tracking/alerts, so credentials alone do not establish permission for this
  feature. See [eligibility](https://affiliate-program.amazon.com/creatorsapi/docs/en-us/introduction)
  and [Singapore program policies](https://affiliate-program.amazon.sg/help/operating/policies).

For a future Rainforest evaluation, configure a trial key in the backend
environment as `RAINFOREST_API_KEY`; do not put it in chat or the iOS bundle.
This branch does not yet include a Rainforest adapter or consume that variable.
An Astra/OpenAI key cannot grant Amazon product-data access.

## Validation

The full backend suite passed 816 tests, alongside 35 JavaScript tests and
OpenAPI/TypeScript contract checks. A replay of the actual iPhone HTML through
both authenticated price routes reported `no_primary_offer`; an isolated test
watch retained that reason with no price history or drop signal. These checks
did not change existing watches or make paid API calls. Saved public-page
responses and probe summaries remain in ignored `local-data/price-diagnostics/`.
