# Mymah Finds — team handoff

Mymah Finds starts with a personal library of saved content. Chrome/browser and iOS are equal product surfaces, with exactly three main destinations: **Library**, **Search**, and **Profile**. Capture should be quick, and saved links, text, and notes should remain easy to find and revisit.

The next interface feature is [predictive annotations](predictive-annotations.md): save an image or link, then offer optional annotations based on that content. Product screens must not expose prototype/demo labels, provider keys, internal mode labels, or developer diagnostics. Recommendations, shopping journeys, catalogs, and live price watches remain separate future interface work.

## Ownership and starting points

| Owner | Work area | Start here |
| --- | --- | --- |
| Haydn / backend | Capture, library persistence, contracts, identity, jobs, Astra annotations and catalog integration | `backend/`, `contracts/`, `.env.example` |
| Chrome teammate | Capture popup, Library/Search/Profile, permissions, lifecycle, store assets | `extension/`, [Chrome guide](platform-chrome.md), `clients/javascript/` |
| iOS teammate | Native Library/Search/Profile, Share Extension, account state, accessibility, signing | `clients/ios/`, [iOS guide](platform-ios.md) |
| Shared review | Contract changes, brand/copy, account isolation, cross-device acceptance | `contracts/openapi.json`, `contracts/examples/`, this checklist |

Use **Mymah Finds** in user-visible names and copy. Internal `CommonThread` SDK symbols and existing API paths may retain older identifiers for compatibility. Teammates can replace scaffold views while keeping the shared transport, retry, and persistence behavior. `frontend/` is a reference for the current scope, not a requirement to reproduce its components in SwiftUI.

## First integration session

1. Extract `dist/mymah-finds-framework.zip`, install dependencies using the root README, then run `make run`. For a shared backend, agree on one HTTPS origin and development account token instead.
2. Read `/v1/me` to establish the account. Check `/v1/capabilities` for transport/content limits without displaying development diagnostics. Both interfaces must use credentials for the same backend user to share a library.
3. Chrome: run `make extension`, load `dist/chrome-extension/` through **Load unpacked**, configure the API, and explicitly save a public page. `dist/mymah-finds-chrome-extension.zip` is the extractable development package.
4. iOS: install Xcode/XcodeGen, generate the host and Share Extension targets, set signing/App Group/Keychain identifiers, and connect the host before sharing.
5. Confirm the saved item appears in Library on the other interface after refresh. Find it through Search, open its original link, and verify account isolation.

## Current interface contract

| Flow | API or framework responsibility | Interface responsibility |
| --- | --- | --- |
| Capture | `POST /v1/saves` stores a URL, image, or both, plus title/text/note, and returns a durable receipt | Editable preview, optional note, explicit Save, retained action key, clear saved/failed state |
| Predictive annotations | Saved-item suggestions; `POST /v1/saves/{id}/responses` records an explicit selection/edit | Optional chips, edit/skip, clear confirmation; `annotation_only` never means a reminder or watch was scheduled |
| Private image | Authenticated `GET /v1/saves/{id}/image` | Fetch with the current account token, discard on account change, hide the original-link button for image-only content |
| Library | `GET /v1/collection`, `GET /v1/saves/{id}` | Saved content is the primary screen; show title, source/link, supplied text/note, useful empty state and refresh |
| Search | Search the user's fetched library content; no dedicated search endpoint exists | Find saved titles, links, text, notes and source; support clearing the query and no results |
| Profile | `GET /v1/me`; platform credential/settings storage | Account identity, connection/sign-out state and implemented account controls; keep diagnostics out of product screens |
| Delete | `DELETE /v1/saves/{id}` removes the item from the active library and invalidates related cached results | Explicit removal, clear local library/search/detail views, refresh after success |
| Retry/recovery | Idempotency and account-scoped capture state | Preserve the exact request/key across uncertain outcomes; keep unsent user intent recoverable |

The browser reference loads all library pages before filtering titles, notes, selected text, source, and URLs locally. Other clients must provide the same coverage or agree on a search API with the backend owner; a loaded-page filter must not silently claim complete results. Refresh from the first page when the library changes.

The API accepts a URL or JPEG/PNG/WebP data URL, title, selected text, and note; see the [image contract](predictive-annotations.md). Server search, folder/tag editing, saved-content metadata updates, and production profile editing remain unavailable.

Field definitions and limits are in [OpenAPI](../contracts/openapi.json). [Response examples](../contracts/examples) come from an isolated API instance; regenerate with `make fixtures`. JavaScript types are generated; Swift models are maintained and checked against these fixtures. The schema includes future APIs, so it is broader than the current interface scope.

### State and data rules

- `client` records the capture surface: `web`, `chrome_extension`, `ios_app`, or `ios_share_extension`. `source` identifies the content platform. Capture origin is the initial save's origin, or latest restoration after deletion; it is not a history of every resave/device.
- Duplicate canonical URLs return `duplicate:true` without replacing title/note/text. Show **Already saved** and open the existing item. Do not claim a new note was stored, or route the current UI into annotation/meaning APIs as a workaround.
- A successful capture receipt means the item is saved. Backend enrichment states (`pending`, `ready`, `enrichment_failed`) do not change that fact. Library must remain usable without annotations; do not present analysis as a required save step.
- Distinguish a locally queued request whose save is not yet acknowledged from a server-saved item. Only the former needs pending upload/retry treatment in this interface.
- Lists use offset/limit (maximum 100) and nullable `next_offset`. Reload offset zero on foreground or mutation and deduplicate IDs across pages. Concurrent changes can shift offsets; this is not delta sync.
- Timestamps are Unix seconds UTC, not JavaScript milliseconds. Use source metadata supplied by the user/client; do not imply another platform account is connected.
- Capabilities describe backend availability, not additional navigation. Annotation chips belong with saved content within Library/Search/Profile. Discovery and live watch interfaces need their own agreed contract.

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

Every response includes `X-Request-ID`; error bodies include `error.request_id`. Do not log tokens or full personal capture content. Development bearer tokens are not a production login system. Developer setup instructions belong in these guides, not in Library/Search/Profile copy.

## Retained backend work for later

Predictive annotation responses are now part of the interface handoff. Evidence/hypotheses, versioned discovery sessions, catalog filtering, watches, simulated price checks, and notifications remain available for backend development and regression coverage; they are not additional required screens now.

Legacy commerce modules retain fictional catalog records and simulated prices. Separately, the [catalog integration](catalog-integration.md) provides licensed local catalogs, source attribution/exports, synthetic scenarios and optional approved impact/CJ imports with JavaScript/Swift contracts. Dataset retrieval needs no provider account. Astra annotation configuration stays on the backend; checkout, live monitoring, reminder scheduling, push and Dots knowledge access remain unimplemented. Future session editing must still handle `409 stale_version` by reconciling `error.current` before a new user action with a new key/version. Monetary fields use integer minor units and currency.

## Reminders specific to each interface

| Chrome / web | iOS |
| --- | --- |
| Toolbar install/pin onboarding; a public **Add to Chrome** action ultimately links to a published store listing | Host app + Share Extension targets, signing, App Group and Keychain entitlements |
| Explicit `activeTab` capture; restricted-page and permission-denial states | Heterogeneous `NSItemProvider` URL/text, cancellation, short extension lifetime |
| Popup/worker can close; persist retry identity outside memory | Persist intent before networking; app/extension are separate processes |
| Session draft clears on restart; durable offline queue remains teammate work | Durable account-scoped outbox is included; foreground retry and pending/failed UI |
| Optional API host permission; no background browsing or page credentials | Shared Keychain, HTTPS/ATS, foreground refresh; no guaranteed background polling |
| Keyboard/focus, constrained popup, browser Library/Search/Profile layout | Safe areas, Dynamic Type, VoiceOver, keyboard handling, native navigation/sheets |
| Extension icons, store assets and privacy disclosure | App icons, store assets and privacy disclosures |

The image upload and Astra vision contract is now available in the [predictive annotation guide](predictive-annotations.md). Teammates still need to implement selected-image capture, iOS image-share activation/HEIC conversion, and authenticated display. Video, screenshot extraction, large-file/background transfer, browser notifications, APNs and notification deep links remain later work.

## Acceptance checklist for both teammates

- Show Mymah Finds with exactly Library, Search, and Profile as the main navigation. No demo/prototype labels, internal hypothesis controls, shopping flows, provider key settings, or developer diagnostics appear in product screens.
- Save a real public link with optional text/note; see that saved content in Library on both surfaces after refresh. Opening it leads to the original link.
- Save a selected image without inventing a source URL; retrieve it using the current account's authorization. Verify that another account cannot load it.
- Show optional predictive annotations after a save; select, edit, reject and skip without losing the saved item. Selection confirms an annotation and never claims reminder or watch execution.
- Search saved content, clear the query, handle no results, and verify that pagination does not silently omit the intended search scope.
- Start with an empty library that helps the person save their first item; do not seed a fictional shopping story.
- Close the popup/share sheet during a request and retry without creating duplicate actions. A server-side enrichment failure must not hide or discard a saved item.
- Resave a canonical duplicate and accurately report **Already saved** without claiming metadata was updated.
- Delete a save, remove it from library/search/detail views, then retry its old action and handle 410 without resurrection.
- Expire credentials, sign out or switch accounts/origins, deny/revoke permissions, and verify token/draft/library isolation.
- Retain only implemented account controls in Profile. Do not imply account editing, complete account erasure, push delivery, or Dots knowledge access. Image capture affordances must be backed by the actual platform picker/share implementation.

## Validation and release boundary

Validation includes the existing library/transport checks plus predictive annotations, image capture, source adapters, catalog integration, operator CLI and worker concurrency tests. Run `make test` for the current full counts and generated-contract checks. Provider tests use mocked HTTP responses; they do not establish live credentials or latency. `make smoke-swift` additionally covers image payloads, private image transport, typed annotation intents, catalog models, money/null handling, expiry, request encoding and source errors.

The Mymah Finds browser reference was checked on desktop and at a 393 px mobile viewport. Saving an actual link, finding it by its note, opening its detail view, and removing it were exercised against the running backend. These browser checks do not claim native iOS or installed-extension verification.

The Swift package has a compiled harness for real response fixtures, transport, retries, and durable outbox behavior. Its XCTest suite is supplied but could not run on this workstation's mismatched Command Line Tools toolchain; see the platform guide.

The framework's real HTTP smoke, SQLite upgrade/downgrade/reupgrade, legacy-row preservation, schema consistency, and PostgreSQL offline SQL generation passed. These checks establish the integration foundation; interface acceptance must follow the current saved-library checklist above.

The browser interface was also checked at 375 × 667: no horizontal overflow, all three navigation targets exceeded 44 px, and the visible interface contained no previous brand or prototype/demo wording. Current [mobile](mymah-finds-library-mobile.png) and [desktop](mymah-finds-library-desktop.png) previews are included in the handoff.

Chrome installation/permission prompts were not exercised. Native host/share targets are project templates: Xcode signing, iOS builds, Simulator, and physical-device integration remain to be tested. Live PostgreSQL remains untested.

Before release, the backend owner must provide production identity/session handling, deployment settings, operational limits/monitoring, and data retention/erasure. Store publishing is separate work. Live provider access, remote inference, tracking, uploads and push are later activation/integration steps, not prerequisites for designing the current library experience. For future catalog screens, preserve source separation, merchant attribution, currency/unknown fields and expiry; keep imports and private keys on the backend. Preserve source license/attribution and `data_kind`; historical or synthetic records must not appear to be current merchant offers.
