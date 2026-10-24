# Mynah Finds web app

The web interface mirrors the shared-library experience in iOS commit `3586e2a` on `codex/ios-app` (25 October 2026). Work lives on `codex/mynah-web-app`; no iOS source or backend contracts were changed.

## Run locally

From this checkout:

```sh
make setup
.venv/bin/python scripts/run_web.py
```

Open <http://127.0.0.1:8001>. The launcher reads the existing `.env`, applies migrations and starts the matching API and frontend together. Use `--port 8003` to choose another port. Keep separate databases when running branches with different backend schemas. The original `make run` remains available on port 8000.

For this workspace’s first preview, port 8001 uses an isolated copy of the old Chrome preview’s saved finds and images. Port 8000 and its database were not changed. This copy does not continuously sync with that server. The preview configuration is in ignored `.env` and `prototype.db` files.

## Screens and behavior

- **Library:** private server search across finds, notes and analyzed categories; source filters; grid/list layouts; sorting; authenticated saved images; link or photo capture; notes, analysis, intent selection and removal in detail sheets.
- **Explore:** the shared `/v1/explore` API, paged recommendations and search, explanations linked to saved evidence, catalog citations and source licenses. Historical or unknown prices are not presented as current offers.
- **Profile:** System/Light/Dark appearance, layout and sort preferences, connected account, collection counts, privacy information, saving guide and introduction.

The visual reference is iOS’s system type, white/neutral-dark surfaces, rounded cards, black/white primary actions and blue accents. Desktop uses a sidebar; phones use three bottom tabs. Approved Mynah assets are copied from branding commit `838cab2`. The existing misspelled session-storage keys are retained for compatibility with previously connected browser sessions.

iPhone-only local favorites, archives, haptics and voice permissions are not offered for a shared web library. Local-only iPhone finds are not automatically uploaded. Both apps must use the same shared account and server to see the same saves.

## Service requirements

Explore requires an imported catalog on the API server; see [catalog integration](catalog-integration.md). This local preview has no catalog imported and shows that state explicitly. Its configured fallback provider does not supply product analysis. A configured analysis provider and catalog are needed for personalized recommendations; the web interface uses the API’s capability flags and never creates sample recommendations for a user’s account. Paid provider calls were not used for validation.

Photos are JPEG, PNG or WebP up to 4 MiB, matching the API. Private image requests use bearer authentication, then display the data locally under the existing content security policy. No authentication tokens appear in image URLs. Appearance/layout/sort persist on this browser; access keys remain session-scoped.

## Validation

```sh
node --check frontend/app.js
node --test frontend/test/*.test.mjs clients/javascript/test/*.test.js
.venv/bin/python -m pytest -q backend/tests/test_explore.py backend/tests/test_library_intelligence.py backend/tests/test_media.py
```

Validated desktop, tablet and phone widths (1440, 768, 390), light/dark appearance, real saved images and Library search. An isolated disposable catalog database was used to check Explore results, citations, saved evidence, link/photo capture and account isolation without adding fixtures to the preview library. Frontend tests cover stale request cancellation, paging retries, account isolation, price exponents, offer expiry/link validation and photo limits. Physical mobile Safari and live provider analysis were not exercised.
