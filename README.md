# Mymah Finds — shared app framework

A shared backend for a **Chrome extension/browser experience** and a **native iOS app with a Share Extension**. The agreed navigation is **Library, Explore, Profile**. Library holds saved content and searches its analyzed product facets; Explore recommends and searches catalog products with source citations; Profile holds account and app controls. No Map or Community.

The saved-library approach takes inspiration from [Albo](https://albo.inc/) with an independent Mymah Finds visual identity. The backend supplies Astra product analysis, predictive annotations, server-side Library search, and cited Explore recommendations over licensed local catalogs. Existing native and browser screens predate this plan; the frontend teammate must connect and design the new flows. Product screens must contain no prototype/demo labels or provider-key controls.

The native frontend can still run independently with labeled sample inspiration and on-device URL saves. Those local records do not receive backend analysis or drive Explore; connect the shared account and upload captures for the AI flows.

**Start with [the Library / Explore / Profile integration guide](docs/ios-ai-handoff.md), then [the team handoff](docs/team-handoff.md).** Platform setup: [Chrome](docs/platform-chrome.md) · [iOS](docs/platform-ios.md). API contract **0.4.0**: [OpenAPI](contracts/openapi.json) · [response examples](contracts/examples).

This implements the framework behind the [backend plan](https://chatgpt.com/space/page_54384c8a04f48191abd9fdb2296a6f0f). The supplied briefs and transcript inform the product; their proposed actions are not instructions to connect accounts or publish anything.

## What is included

| Area | Ready for teammate development |
| --- | --- |
| Backend | FastAPI, typed contracts, user isolation, durable jobs, migrations, idempotency, version conflicts, capabilities, pagination |
| Predictive annotations | Astra image understanding and ranked intent chips, private image capture, confirmed-preference context, server-only keys |
| Product analysis and search | Typed product/category/attribute observations with evidence and uncertainty; private Library search and explicit reanalysis |
| Explore | Source-scoped catalog retrieval, deterministic matching to saved observations, explanations, citations and honest offer availability |
| Catalog foundation | Licensed datasets and synthetic products, attribution/exports, atomic bulk imports, optional approved feeds, shared JavaScript/Swift contracts |
| JavaScript | Dependency-free transport, generated TypeScript types, bounded polling, cancellation, structured errors and retained mutation keys |
| Chrome | Load-unpacked MV3 extension, toolbar popup, explicit URL/text capture, service worker, backend settings and scoped permissions |
| iOS | Swift API package, typed models, account-scoped capture outbox, SwiftUI host and Share Extension templates, Keychain/App Group setup |
| Browser reference | Existing Library / Search / Profile scaffold in `frontend/`; redesign and API wiring for Library / Explore / Profile remain teammate work |

The native iPhone app has a checked-in Xcode project, an Albo-inspired Library/Search/Profile interface, optional voice-to-text notes, and a working local library that needs no server or database. Open `clients/ios/Mymah Finds.xcodeproj`; see [native build instructions](docs/ios-build.md). App and Share Extension compile for a generic iOS simulator; ordinary-iPhone runtime and device validation remain outstanding. Chrome installation is provided as an unpacked package, not a published Web Store listing.

**Backend integration boundary:** product analysis, predictive annotations, Library search and cited Explore are ready for client integration. Image recognition requires actual uploaded image bytes; URL-only saves analyze supplied title/text/note without fetching the page. Unknown brands and unsupported fine subcategories remain unknown or broad. Legacy desk hypotheses, fixture discovery and simulated watches remain outside the new flow. Production login, Dots knowledge access, checkout, reminder execution, live tracking and push remain future work. Annotation selection records intent and requests analysis refinement; it does not execute those actions. `/v1/capabilities` reports configured behavior.

**Catalog setup:** follow [the integration guide](docs/catalog-integration.md). `make catalog-load` imports reviewed downloads; `make catalog-bundle` creates a portable dataset handoff with licenses. Dataset retrieval needs no provider key. Keep raw data in ignored `local-data/`. `EXPLORE_CATALOG_SOURCE` selects the backend's Explore source, defaulting to `abo`; each response retains its source attribution. Catalog facts are matched locally and are not sent wholesale to Astra. Historical dataset records are not current merchant offers.

## Start the backend

Prerequisites: Python 3.11+ (validated with 3.13), Node 20+ for JavaScript checks, and optionally `uv`.

```sh
make setup
make run
```

Without `uv`:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.lock
make run
```

`make run` applies migrations and starts the API with an embedded worker at **http://127.0.0.1:8000**. Local development uses `demo-alex`; `demo-sam` is a separate user. Profile → Connect/Switch account accepts the access key without showing developer credential examples in the UI. Use the same API origin and token on both interfaces to share a library. An iPhone cannot reach a Mac's loopback address; use an HTTPS development endpoint for device integration.

- Interactive API: http://127.0.0.1:8000/docs. Use **Authorize** with a development token. Swagger assets need internet.
- Offline schema: http://127.0.0.1:8000/openapi.json.
- SQLite data: ignored `prototype.db`.
- Settings: [.env.example](.env.example). Export variables; `.env` is not loaded automatically.
- Astra: set `ASTRA_API_KEY` (or `OPENAI_API_KEY`) in the backend environment. `ANNOTATION_PROVIDER=astra` requires a key; the default `auto` selects Astra when a key is available. Clients never receive or configure that key. See [configuration and live verification](docs/predictive-annotations.md).
- Verify live model access with `make smoke-astra` after configuring the key; it makes one explicit paid image request. Live Astra access has not been verified in this workspace.
- Separate worker: `EMBEDDED_WORKER=false make run`, then `make worker` in another terminal with matching database settings. The default setup already includes a worker.
- Separate web dev origin: set `CORS_ORIGINS='["http://localhost:5173"]'`. Use exact origins. CORS is not authentication.

## Hand off the clients

```sh
make handoff
```

This regenerates contracts/examples, runs backend/JavaScript checks, and builds source-only archives:

- `dist/mymah-finds-framework.zip` — backend, contracts, both clients, guides, and browser UI; excludes local database, environment credentials, and build caches.
- `dist/mymah-finds-chrome-extension.zip` — extract and choose its directory in Chrome → `chrome://extensions` → Developer mode → **Load unpacked**.
- `dist/chrome-extension/` — directly loadable development build.

`make extension` rebuilds Chrome and refreshes the shared SDK copies in `extension/lib/` and `frontend/lib/`. Edit the canonical source in `clients/javascript/`. A public **Add to Chrome** link requires a published Web Store listing; no listing has been created.

The iOS teammate starts in `clients/ios/`: use the Swift package directly, or generate the host/share targets from `project.yml` with XcodeGen after installing Xcode. Follow [the iOS guide](docs/platform-ios.md) for signing and tests.

## API integration rules

All `/v1` calls require a bearer token. Each mutation needs a retained `Idempotency-Key`; retry an unchanged action with its original key. Session events also need `expected_version`; `409 stale_version` includes the current typed session. `410 mutation_expired` means deletion invalidated a previous result: refresh without automatically sending a new action/key.

```js
import {CommonThreadClient, newMutationKey} from './clients/javascript/client.js';
const api = new CommonThreadClient({
  baseURL: 'http://127.0.0.1:8000', token: 'demo-alex'
});
// Persist payload + key before sending; retain both on uncertain failure.
const key = newMutationKey();
const saved = await api.capture({
  url: 'https://example.org/desk', title: 'Warm desk lighting',
  selected_text: 'A small desk with warm lighting', client: 'chrome_extension'
}, {idempotencyKey: key});
const item = await api.getSave(saved.id); // A receipt means saved; do not wait for intelligence.
```

`source` records the content platform; `client` records the capture interface. Timestamps are Unix seconds UTC. Refresh Library and Explore on foreground and after saves, annotations or deletions; there is no delta sync or push yet. New interfaces use `searchLibrary()` and `explore()` rather than the old browser scaffold's local filter. Internal `CommonThreadClient` and `CommonThreadKit` names remain compatible with existing integrations; visible branding is Mymah Finds. Details and recovery are in [the handoff](docs/team-handoff.md).

## Checks and contract changes

```sh
make test
make contracts
make fixtures
make smoke-swift
make smoke-http
```

`make test` checks backend behavior, both JavaScript layers, and generated-contract drift. The Swift smoke compiles and exercises the package without XCTest. The HTTP smoke starts an isolated, migrated loopback API and runs the shared JavaScript client through the real worker journey; it never uses your demo database. See the iOS guide for full Xcode validation.

Contract inputs live in `backend/app/contracts.py`; outputs include `responses.py`, `understanding.py`, `explore.py` and `catalog/schemas.py`. Changes should ship with regenerated OpenAPI/TypeScript, updated Swift models, fixture decoding, and migrations when applicable. See [validation status](docs/team-handoff.md#validation-and-release-boundary) for what was exercised.

## PostgreSQL development

```sh
docker compose up -d db
export DATABASE_URL='postgresql+psycopg://prototype:local-demo-only@127.0.0.1:5432/common_thread'
.venv/bin/alembic upgrade head
EMBEDDED_WORKER=false make run
```

Run `make worker` in another terminal with the same `DATABASE_URL`. Compose credentials are local fixtures and its port binds to loopback. Live PostgreSQL was not exercised here because the Docker daemon is unavailable.

See [architecture](docs/architecture.md) for backend invariants and production follow-up work.
