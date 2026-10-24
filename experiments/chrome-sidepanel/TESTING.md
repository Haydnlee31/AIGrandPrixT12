# Chrome side-panel 0.4 verification — 2026-10-25

## Automated

`node --test experiments/chrome-sidepanel/tests/*.test.js`: **40 passed**.

Coverage includes explicit active-tab capture and navigation guards, supported images, safe source links, local intents, legacy and modern capture formats, uncertain mutation retries, no extra analysis on first share, definitive validation rejection, account boundaries, server answer reconciliation, shared-library deduplication/deletion, pagination, stale search/account cancellation, catalog image allowlisting and historical-offer presentation.

`node --check` passed for side-panel JavaScript. `git diff --check` passed. `python3 scripts/package_handoff.py --sidepanel` produced the source-only ZIP; required modules were present and no credentials, environment files or test data were included.

## Actual installed Chrome and production API

Updated the existing unpacked folder in place, kept extension ID and IndexedDB, and reloaded version 0.4.0. Original unshared finds remained visible. The user approved the production hostname permission and connection with the existing Mynah account key.

- Connected to `https://mynah-finds.vercel.app`; capabilities detected product AI and Explore.
- Empty shared account showed “Start with a find”, not a blank Explore screen.
- Image-only upload through the actual side-panel picker persisted a private image. A synthetic illustration's AI interpretation failed backend validation; the saved record and explicit retry UI remained available. Unsupported local/private page URLs were rejected by the production backend. Added recovery so a definitive validation rejection keeps a plain local save.
- A real public ABO catalog lamp photo captured through the extension's `syncSave`/SDK returned ready analysis with one product, observed colors/shapes, no invented brand or model.
- Actual side panel read that independently created shared find, loaded its private image, and displayed AI summary, attributes and evidence. Choosing “Save this as inspiration” in Chrome persisted one response; an independent API client verified it and the refreshed analysis.
- Shared Explore returned 12 personalized results citing that photo. Actual Chrome displayed product images, catalog text, empty/unavailable prices, attribution and source/license links. Explicit `desk lamp` search also worked.
- “Why this?” opened the catalog explanation, and its saved-evidence link opened the correct Library find. The close control remained visible after scrolling a long recommendation.
- Kept the working catalog lamp demo as requested. Removed both synthetic QA saves through Chrome and verified the shared upload was absent from the API, while the demo still produced 12 recommendations. Existing user saves were not part of cleanup.

## Practical limits

This is the unpacked extension, not a Chrome Web Store release. Provider outputs can fail validation; failed analysis stays visible and retryable. Product recommendations are evidence-based catalog matches, not verified current prices/stock. Public thumbnails are currently restricted to the configured ABO image host. Local/iPhone-only finds do not become shared automatically. iOS must use the same shared account and 0.4 backend contract; no iOS code or device build was changed or tested here. Native Radar/price alerts and individual user sign-in remain separate work.
