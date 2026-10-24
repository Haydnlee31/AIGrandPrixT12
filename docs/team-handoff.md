# Mynah Finds — team handoff

Mynah Finds has three agreed main destinations: **Library**, **Explore**, and **Profile**. Library holds saved content with product analysis and search; Explore recommends and searches products with citations; Profile holds account and app controls. Chrome/browser and iOS share the backend and SDK contracts.

**Start with the [Library / Explore / Profile integration guide](ios-ai-handoff.md).** Contract **0.4.0** provides structured product understanding, [predictive annotations](predictive-annotations.md), private Library search and cited Explore recommendations. Existing native and browser screens predate the new plan and still need teammate design and wiring. Provider keys and developer diagnostics remain outside product screens. Preserve Chrome’s honest distinction between basic suggestions and AI interpretation. Live watches, reminder execution and checkout remain separate work.

## Ownership and starting points

| Owner | Work area | Start here |
| --- | --- | --- |
| Haydn / backend | Capture, product analysis, Library search, cited Explore, contracts, identity, jobs and catalog integration | `backend/`, `contracts/`, `.env.example` |
| Chime | Chrome side panel, content-understanding and contextual questions, permissions and lifecycle | `experiments/chrome-sidepanel/`, [Chrome guide](platform-chrome.md), `clients/javascript/` |
| Adi | Native Library/Explore/Profile, Share Extension, analysis/citation presentation, account state and accessibility | [AI integration guide](ios-ai-handoff.md), `clients/ios/`, [iOS guide](platform-ios.md) |
| Shared review | Contract changes, brand/copy, account isolation, cross-device acceptance | `contracts/openapi.json`, `contracts/examples/`, this checklist |

Use **Mynah Finds** in user-visible names and copy. Internal `CommonThread` SDK symbols and existing API paths may retain older identifiers for compatibility. Teammates can replace scaffold views while keeping the shared transport, retry, and persistence behavior. The older `frontend/` navigation is not the new product specification or a requirement to reproduce its components in SwiftUI.

## First integration session

1. Extract `dist/mymah-finds-framework.zip`, install dependencies using the root README, then run `make run`. For a shared backend, agree on one HTTPS origin and development account token instead.
2. Read `/v1/me` to establish the account. Check `/v1/capabilities` for transport/content limits without displaying development diagnostics. Both interfaces must use credentials for the same backend user to share a library.
3. Chrome: run `make extension`, load `dist/chrome-extension/` through **Load unpacked**, configure the API, and explicitly save a public page. `dist/mymah-finds-chrome-extension.zip` is the extractable development package.
4. iOS: install Xcode/XcodeGen, generate the host and Share Extension targets, set signing/App Group/Keychain identifiers, and connect the host before sharing.
5. Confirm the saved item appears in Library on the other interface after refresh. Find it through server Library search, inspect available product analysis, and verify account isolation. With a configured source and supported saved categories, fetch Explore and open its evidence citations.

## Current interface contract

| Flow | API or framework responsibility | Interface responsibility |
| --- | --- | --- |
| Capture | `POST /v1/saves` stores a URL, image, or both, plus title/text/note, and returns a durable receipt | Editable preview, optional note, explicit Save, retained action key, clear saved/failed state |
| Predictive annotations | Saved-item suggestions; `POST /v1/saves/{id}/responses` records an explicit selection/edit | Optional chips, edit/skip, clear confirmation; `annotation_only` never means a reminder or watch was scheduled |
| Product understanding | Typed `analysis` and `analysis_status` on saved items; `POST /v1/saves/{id}/analyze` requests a fresh analysis | Show observed/inferred facts, unknown brand/model and uncertainties; keep capture usable during analysis |
| Private image | Authenticated `GET /v1/saves/{id}/image` | Fetch with the current account token, discard on account change, hide the original-link button for image-only content |
| Library | `GET /v1/collection`, `GET /v1/saves/{id}` | Saved content is the primary screen; show title, source/link, supplied text/note, useful empty state and refresh |
| Library search | `GET /v1/library/search?q=...&category=...` searches owned captures, confirmed notes and analyzed product facets | Query/clear/no-result states, category filters and server pagination |
| Explore | `GET /v1/explore?q=...` returns source-scoped catalog matches, reasons and citations | Recommendation/search cards, **Why this?**, linked saved evidence and catalog attribution, empty/no-match states |
| Profile | `GET /v1/me`; platform credential/settings storage | Account identity, connection/sign-out state and implemented account controls; keep diagnostics out of product screens |
| Delete | `DELETE /v1/saves/{id}` removes the item from the active library and invalidates related cached results | Explicit removal, clear local library/search/detail views, refresh after success |
| Retry/recovery | Idempotency and account-scoped capture state | Preserve the exact request/key across uncertain outcomes; keep unsent user intent recoverable |

Use `searchLibrary()` for complete server-side matching of the current account's Library. The old browser reference still performs a local filter and should be updated by its teammate. Use `explore()` for personalized candidates and `explore(query:)` for catalog search. Refresh from the first page when the Library changes; do not substitute a loaded-page filter and label it complete search.

The API accepts a URL or JPEG/PNG/WebP data URL, title, selected text, and note; see the [image contract](predictive-annotations.md). URL-only saves analyze supplied text without fetching the page. Upload actual image bytes for vision. Folder/tag editing, general saved-content metadata updates, and production profile editing remain unavailable.

Field definitions and limits are in [OpenAPI](../contracts/openapi.json). [Response examples](../contracts/examples) come from an isolated API instance; regenerate with `make fixtures`. JavaScript types are generated; Swift models are maintained and checked against these fixtures. The schema includes future APIs, so it is broader than the current interface scope.

### State and data rules

- `client` records the capture surface: `web`, `chrome_extension`, `ios_app`, or `ios_share_extension`. `source` identifies the content platform. Capture origin is the initial save's origin, or latest restoration after deletion; it is not a history of every resave/device.
- Duplicate canonical URLs return `duplicate:true` without replacing title/note/text. Show **Already saved** and open the existing item. Do not claim a new note was stored, or route the current UI into annotation/meaning APIs as a workaround.
- A successful capture receipt means the item is saved. Backend enrichment states (`pending`, `ready`, `enrichment_failed`) do not change that fact. Library must remain usable without annotations; do not present analysis as a required save step.
- Distinguish a locally queued request whose save is not yet acknowledged from a server-saved item. Only the former needs pending upload/retry treatment in this interface.
- Lists use offset/limit (maximum 100) and nullable `next_offset`. Reload offset zero on foreground or mutation and deduplicate IDs across pages. Concurrent changes can shift offsets; this is not delta sync.
- Timestamps are Unix seconds UTC, not JavaScript milliseconds. Use source metadata supplied by the user/client; do not imply another platform account is connected.
- Capabilities describe backend availability. Annotation chips belong with saved content within Library/Explore/Profile. Selecting or editing a chip can queue refined analysis; refresh the saved item and dependent Explore results. Legacy discovery and live watch interfaces need their own agreed contract.

### Error and retry rules

| Result | Client behavior |
| --- | --- |
| Network / timeout / unreadable response | Outcome may be unknown. Retain body and key; retry the exact request. Do not automatically create a new key. |
| `401 unauthorized` | Reconnect; never replay account-scoped drafts into a different account. |
| `409 idempotency_conflict` | A key was reused for different content. Resolve local intent bookkeeping. |
| `409 concurrent_mutation` | Retry unchanged with the same key. |
| `410 mutation_expired` | Deletion invalidated an earlier result. Refresh; only explicit new intent can create a new action/key. |
| `422` | Show validation feedback; an edited submission gets a new key. |
| `500` / `503` | Keep mutation identity and request ID; offer deliberate retry, not an infinite loop. |

Every response includes `X-Request-ID`; error bodies include `error.request_id`. Do not log tokens or full personal capture content. Development bearer tokens are not a production login system. Developer setup instructions belong in these guides, not in Library/Explore/Profile copy.

## Retained backend work for later

Product analysis, predictive annotations, Library search and cited catalog recommendations are in the current interface handoff. Legacy desk hypotheses, versioned discovery sessions, watches, simulated price checks and notifications remain available for backend regression coverage; they are not additional required screens now.

Explore uses the [catalog integration](catalog-integration.md), which provides licensed local catalogs, source attribution/exports, separate synthetic scenarios and optional approved impact/CJ imports. `EXPLORE_CATALOG_SOURCE` selects its source on the backend, defaulting to `abo`. It matches saved observations to retrieved catalog facts locally and cites both sides; it does not send the whole catalog to Astra. Historical records do not establish live price, merchant, stock or checkout availability. Legacy commerce retains separate fictional records and simulated prices. Checkout, live monitoring, reminder scheduling, push and Dots knowledge access remain unimplemented. Monetary fields use integer minor units and currency.

## Reminders specific to each interface

| Chrome / web | iOS |
| --- | --- |
| Toolbar install/pin onboarding; a public **Add to Chrome** action ultimately links to a published store listing | Host app + Share Extension targets, signing, App Group and Keychain entitlements |
| Explicit `activeTab` capture; restricted-page and permission-denial states | Heterogeneous `NSItemProvider` URL/text, cancellation, short extension lifetime |
| Popup/worker can close; persist retry identity outside memory | Persist intent before networking; app/extension are separate processes |
| Session draft clears on restart; durable offline queue remains teammate work | Durable account-scoped outbox is included; foreground retry and pending/failed UI |
| Optional API host permission; no background browsing or page credentials | Shared Keychain, HTTPS/ATS, foreground refresh; no guaranteed background polling |
| Keyboard/focus, constrained popup, browser Library/Explore/Profile layout | Safe areas, Dynamic Type, VoiceOver, keyboard handling, native navigation/sheets |
| Extension icons, store assets and privacy disclosure | App icons, store assets and privacy disclosures |

The image upload and Astra vision contract is now available in the [predictive annotation guide](predictive-annotations.md). Chrome already supports selected-image capture, screenshots and image uploads. Native image-share activation/HEIC conversion and native presentation remain Adi’s work. Video understanding, large-file/background transfer, browser notifications, APNs and notification deep links remain later work.

## Acceptance checklist for both teammates

- Build Mynah Finds with Library, Explore, and Profile as the main navigation. Keep provider key settings and developer diagnostics outside product screens; preserve the current Chrome capture/question experience while connecting later Explore screens. Explore cards must not claim checkout or live monitoring that the backend does not supply.
- Save a real public link with optional text/note; see that saved content in Library on both surfaces after refresh. Opening it leads to the original link.
- Save a selected image without inventing a source URL; retrieve it using the current account's authorization. Verify that another account cannot load it.
- Show optional predictive annotations after a save; select, edit, reject and skip without losing the saved item. Selection confirms an annotation and never claims reminder or watch execution.
- Search saved content, clear the query, handle no results, and verify that pagination does not silently omit the intended search scope.
- Find a saved watch using a detected category/style; distinguish a supported brand from an unreadable one. Inspect **Why this?** on a relevant Explore card and reopen its actual Library/catalog citations. Preserve no-match and missing-offer states.
- Start with an empty library that helps the person save their first item; do not seed a fictional shopping story.
- Close the popup/share sheet during a request and retry without creating duplicate actions. A server-side enrichment failure must not hide or discard a saved item.
- Resave a canonical duplicate and accurately report **Already saved** without claiming metadata was updated.
- Delete a save, remove it from library/search/detail views, then retry its old action and handle 410 without resurrection.
- Expire credentials, sign out or switch accounts/origins, deny/revoke permissions, and verify token/draft/library isolation.
- Retain only implemented account controls in Profile. Do not imply account editing, complete account erasure, push delivery, or Dots knowledge access. Image capture affordances must be backed by the actual platform picker/share implementation.

## Validation and release boundary

Validation includes the existing library/transport checks plus predictive annotations, image capture, source adapters, catalog integration, operator CLI and worker concurrency tests. Run `make test` for the current full counts and generated-contract checks. Provider tests use mocked HTTP responses; they do not establish live credentials or latency. `make smoke-swift` additionally covers image payloads, private image transport, typed annotation intents, catalog models, money/null handling, expiry, request encoding and source errors.

The Mynah Finds browser reference was checked on desktop and at a 393 px mobile viewport. Saving an actual link, finding it by its note, opening its detail view, and removing it were exercised against the running backend. These browser checks do not claim native iOS or installed-extension verification.

The Swift package has a compiled harness for real response fixtures, transport, retries, and durable outbox behavior. Its XCTest suite is supplied but could not run on this workstation's mismatched Command Line Tools toolchain; see the platform guide.

The framework includes real HTTP smoke, SQLite migration/row-preservation checks, schema consistency and PostgreSQL offline SQL checks. Current backend/SDK tests cover rich product analysis, Library search, cited Explore and annotation refinement. These establish API behavior; they do not establish live Astra accuracy or completed screen/device integration. Follow the [new interface acceptance guide](ios-ai-handoff.md).

The browser interface was also checked at 375 × 667: no horizontal overflow, all three navigation targets exceeded 44 px, and the visible interface contained no previous brand or prototype/demo wording. Current [mobile](mymah-finds-library-mobile.png) and [desktop](mymah-finds-library-desktop.png) previews are included in the handoff.

The original popup scaffold’s installation was not exercised in that earlier pass. Chime’s v0.3 side panel was tested in isolated Chrome for Testing, including local-backend host permission and screenshot sharing. Native host/share targets are project templates: Xcode signing, iOS builds, Simulator, and physical-device integration remain to be tested. Live PostgreSQL remains untested.

Before release, the backend owner must provide production identity/session handling, deployment settings, operational limits/monitoring, and data retention/erasure. Store publishing is separate work. No Astra key or full Xcode app was available for live-model/device verification in this workspace. Run `make smoke-astra` after backend key configuration, then test representative images and the real iOS flow. Preserve source attribution, currency/unknown fields, expiry and `data_kind` in Explore; historical or synthetic records must not appear to be current merchant offers.


## Chrome and backend merge

The combined branch preserves Haydn’s v0.4 product analysis, Library search, cited Explore, provider lifecycle and worker concurrency safeguards. Chrome’s current design, local saves, optional connection, one-click saving, contextual questions and branding live in `experiments/chrome-sidepanel/`. `extension/` remains the original popup scaffold. This merge does not replace the installed extension, clear IndexedDB, upload earlier local-only saves, or change the running local server.

| Person | Owns the next step |
| --- | --- |
| Chime | Chrome experience, content understanding and contextual questions; try real saves and review the choices. |
| Haydn | Shared backend/web app, provider configuration, catalogs and deployment. |
| Adi | Native iPhone screens and Share Extension using the shared contracts. |

| Need | Tool/API | Why |
| --- | --- | --- |
| Product understanding and uncertainty | Existing Astra adapter in `predictive.py` | Retains Haydn’s validated product observations and source-backed analysis. |
| Contextual shopping question experiments | Existing OpenAI Responses adapter in `content.py` | Preserves Chime’s question/evidence output as an optional server-selected adapter. |
| Basic mode without a paid key | `ANNOTATION_PROVIDER=demo` or `fallback` | Saves and text-based choices remain usable; no visual understanding is claimed. |
| Shared content and answers | FastAPI plus shared JS/Swift SDKs | One account, save ID and durable mutation history across clients. |
| Private images | Pillow plus `saved_items.image_data_url` | Normalized private bytes; authenticated JSON and binary reads; excluded from collection metadata. |
| Library search and recommendations | Haydn’s Library/Explore APIs and licensed catalogs | Keep evidence, source citations and uncertainty. Historical catalogs do not establish live offers. |

**Capture compatibility:** new Chrome connections use `image_data_url` and omit an absent URL. The API also accepts legacy `image_data` and `url:""` so pending captures retain their original body and idempotency key. Do not send both image fields. Limits remain 4 MiB decoded / 6 MiB request, with server normalization. Different images from one page remain separate; modern captures also retain distinct source-page context. Legacy image dedupe keys are recognized.

**Migration:** `b82fa3563197` joins the two published Alembic histories and transfers legacy `saved_media` images into the shared image column. It preserves save IDs, canonical keys, answers and idempotency records. Back up a development database before `alembic upgrade head`; do not stamp over or downgrade an existing database to resolve the fork. The old attachment table remains empty for migration history. Existing deployed PostgreSQL data still needs an environment-specific migration rehearsal.

**Media and recovery:** `GET /v1/saves/{id}/image` returns private bytes; `/media` remains the compatible JSON `{image_data}` endpoint. Both require the owner’s bearer token and use no-store responses. `/retry` remains for Chrome’s failed/basic-result recovery; `/analyze` remains Haydn’s explicit reanalysis API. Capability flags advertise image formats, retry and multiple intents, rather than inferring compatibility from the old ambiguous `0.3.0` version alone.

**Questions and confirmation:** suggestions include `next_step`, and response events include their chosen `label`. Astra results are identified as AI interpretation; basic/failed interpretation remains distinct. `execution_status:"annotation_only"` means a chosen action records interest: it does not purchase, schedule a reminder or start price monitoring. Full video/audio understanding and live merchant monitoring remain outside this merge.

**Provider setup:** `auto` / `astra` preserve Haydn’s configuration; `demo` / `fallback` explicitly keep basic mode; `openai` selects the legacy contextual-question adapter with `OPENAI_API_KEY` and optional `OPENAI_MODEL`. Select one provider for the API and worker, then restart both after changing it. No key is added by this merge. Keep credentials out of clients, commits and shared Pages. A live provider request, real iOS device build, shared HTTPS deployment and store publishing remain separate verification steps.

**Local preservation:** Chrome persists capture payloads before networking and replays an uncertain request unchanged after reconnecting. Earlier local-only saves still require “Share with library.” Account/origin boundaries, pending answers and existing image previews remain intact; no storage reset or automatic migration of the installed extension is required by the source merge.


**Confirmed product decisions:** understand why the person saved an item before offering shopping actions. Chrome keeps its contextual question first; once that context is recorded, Astra’s optional action suggestions can follow. Several intents may remain active together. `responses[].active` identifies current annotations; event history is retained. Selecting another intent or skipping does not erase earlier choices. Use `{action:"reject", retract_event_id:"…"}` to remove one annotation, including a custom answer. This retraction also invalidates predictions derived from the removed evidence. Swift exposes `UserEvent.active` and `AnnotationRequest(retractEventId:)`. Native/web teammates should preserve the why-first order in their final screens.
