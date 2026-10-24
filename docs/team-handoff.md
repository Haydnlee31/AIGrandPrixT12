# Mynah Finds — team handoff

Mynah Finds starts with a personal library of saved content. Chrome/browser and iOS are equal product surfaces, with exactly three main destinations: **Library**, **Search**, and **Profile**. Capture should be quick, and saved links, text, and notes should remain easy to find and revisit.

The `chime/chrome-capture-intents` branch now adds the first shared content-understanding flow: **capture → contextual question → one-tap answer → visible in the web library**. This extends the earlier library-only brief. Basic mode and AI interpretation are labelled honestly. Catalogs, purchasing, live prices and monitoring remain outside this increment.

## Ownership and starting points

| Owner | Work area | Start here |
| --- | --- | --- |
| Haydn | Capture, library persistence, contracts, identity, jobs, later intelligence/catalog integration | `backend/`, `contracts/`, `.env.example` |
| Chime | Chrome side panel, content understanding and contextual question experiments | `experiments/chrome-sidepanel/`, [Chrome guide](platform-chrome.md), `clients/javascript/` |
| Adi | Native Library/Search/Profile, Share Extension, account state, accessibility, signing | `clients/ios/`, [iOS guide](platform-ios.md) |
| Shared review | Contract changes, brand/copy, account isolation, cross-device acceptance | `contracts/openapi.json`, `contracts/examples/`, this checklist |

Use **Mynah Finds** in user-visible names and copy. Internal `CommonThread` SDK symbols and existing API paths may retain older identifiers for compatibility. Teammates can replace scaffold views while keeping the shared transport, retry, and persistence behavior. `frontend/` is a reference for the current scope, not a requirement to reproduce its components in SwiftUI.

## First integration session

1. Extract `dist/mymah-finds-framework.zip`, install dependencies using the root README, then run `make run`. For a shared backend, agree on one HTTPS origin and development account token instead.
2. Read `/v1/me` to establish the account. Check `/v1/capabilities` for transport/content limits without displaying development diagnostics. Both interfaces must use credentials for the same backend user to share a library.
3. Chrome: run `make extension`, load `dist/chrome-extension/` through **Load unpacked**, configure the API, and explicitly save a public page. `dist/mymah-finds-chrome-extension.zip` is the extractable development package.
4. iOS: install Xcode/XcodeGen, generate the host and Share Extension targets, set signing/App Group/Keychain identifiers, and connect the host before sharing.
5. Confirm the saved item appears in Library on the other interface after refresh. Find it through Search, open its original link, and verify account isolation.

## Current interface contract

| Flow | API or framework responsibility | Interface responsibility |
| --- | --- | --- |
| Capture | `POST /v1/saves` stores URL/title/text/note and returns a durable receipt | Editable preview, optional note, explicit Save, retained action key, clear saved/failed state |
| Library | `GET /v1/collection`, `GET /v1/saves/{id}` | Saved content is the primary screen; show title, source/link, supplied text/note, useful empty state and refresh |
| Search | Search the user's fetched library content; no dedicated search endpoint exists | Find saved titles, links, text, notes and source; support clearing the query and no results |
| Profile | `GET /v1/me`; platform credential/settings storage | Account identity, connection/sign-out state and implemented account controls; keep diagnostics out of product screens |
| Delete | `DELETE /v1/saves/{id}` removes the item from the active library and invalidates related cached results | Explicit removal, clear local library/search/detail views, refresh after success |
| Retry/recovery | Idempotency and account-scoped capture state | Preserve the exact request/key across uncertain outcomes; keep unsent user intent recoverable |

The browser reference loads all library pages before filtering titles, notes, selected text, source, and URLs locally. Other clients must provide the same coverage or agree on a search API with the backend owner; a loaded-page filter must not silently claim complete results. Refresh from the first page when the library changes.

The API accepts title plus a public URL or an inline image, with optional selected text and note. It has no server search, folder/tag editing, saved-content metadata update, or production profile-edit endpoint. Do not add controls that imply these operations exist.

Field definitions and limits are in [OpenAPI](../contracts/openapi.json). [Response examples](../contracts/examples) come from an isolated API instance; regenerate with `make fixtures`. JavaScript types are generated; Swift models are maintained and checked against these fixtures. The schema includes future APIs, so it is broader than the current interface scope.

### State and data rules

- `client` records the capture surface: `web`, `chrome_extension`, `ios_app`, or `ios_share_extension`. `source` identifies the content platform. Capture origin is the initial save's origin, or latest restoration after deletion; it is not a history of every resave/device.
- Duplicate canonical URLs return `duplicate:true` without replacing title/note/text. Show **Already saved** and open the existing item. Do not claim a new note was stored, or route the current UI into annotation/meaning APIs as a workaround.
- A successful capture receipt means the item is saved. Backend enrichment states (`pending`, `ready`, `enrichment_failed`) do not change that fact. Library must remain usable without annotations; do not present analysis as a required save step.
- Distinguish a locally queued request whose save is not yet acknowledged from a server-saved item. Only the former needs pending upload/retry treatment in this interface.
- Lists use offset/limit (maximum 100) and nullable `next_offset`. Reload offset zero on foreground or mutation and deduplicate IDs across pages. Concurrent changes can shift offsets; this is not delta sync.
- Timestamps are Unix seconds UTC, not JavaScript milliseconds. Use source metadata supplied by the user/client; do not imply another platform account is connected.
- Capabilities describe backend availability, not product navigation. Even when `annotations`, `discovery`, or `watches` are true, these flows remain outside the Library/Search/Profile brief.

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

Annotation responses, evidence/hypotheses, versioned discovery sessions, catalog filtering, watches, simulated price checks, and notifications remain available for backend development and regression coverage. They are not required screens or acceptance flows now. Do not wire them into either interface until the product scope is explicitly expanded.

These modules currently use deterministic demo inference, fictional catalog records, and simulated prices. They do not provide live AI, grounded merchant data, checkout, or push delivery. Future session editing must still handle `409 stale_version` by reconciling `error.current` before a new user action with a new key/version. Monetary fields use integer minor units and currency; these contracts are preserved without introducing shopping UI now.

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

Image-only shares and screenshots now use the v0.3 contract below. Real text/image understanding requires the server-side OpenAI configuration. Full video/audio and large-file/background transfers are not supported. Browser notifications, APNs, and notification deep links also remain later work.

## Acceptance checklist for both teammates

- Show Mynah Finds with exactly Library, Search, and Profile as the main navigation. Show one optional contextual question and label AI interpretation and basic fallback honestly; do not imply live shopping or monitoring.
- Save a real public link with optional text/note; see that saved content in Library on both surfaces after refresh. Opening it leads to the original link.
- Search saved content, clear the query, handle no results, and verify that pagination does not silently omit the intended search scope.
- Start with an empty library that helps the person save their first item; do not seed a fictional shopping story.
- Close the popup/share sheet during a request and retry without creating duplicate actions. A server-side enrichment failure must not hide or discard a saved item.
- Resave a canonical duplicate and accurately report **Already saved** without claiming metadata was updated.
- Delete a save, remove it from library/search/detail views, then retry its old action and handle 410 without resurrection.
- Expire credentials, sign out or switch accounts/origins, deny/revoke permissions, and verify token/draft/library isolation.
- Retain only implemented account controls in Profile. Do not imply account editing, complete account erasure or push delivery is available. Image capture is implemented in the Chrome side panel; Adi still owns the native capture UI.

## Validation and release boundary

Validation completed: **28 backend tests** and **29 JavaScript tests** (10 shared SDK, 12 Chrome extension, 7 library/search), plus generated-contract drift checks. Coverage includes capture, ownership, pagination, error correlation/CORS, retained mutation keys, deletion invalidation, full-library search, unsafe links, and the retained future modules.

The Mynah Finds browser reference was checked on desktop and at a 393 px mobile viewport. Saving an actual link, finding it by its note, opening its detail view, and removing it were exercised against the running backend. These browser checks do not claim native iOS or installed-extension verification.

The Swift package has a compiled harness for real response fixtures, transport, retries, and durable outbox behavior. Its XCTest suite is supplied but could not run on this workstation's mismatched Command Line Tools toolchain; see the platform guide.

The framework's real HTTP smoke, SQLite upgrade/downgrade/reupgrade, legacy-row preservation, schema consistency, and PostgreSQL offline SQL generation passed. These checks establish the integration foundation; interface acceptance must follow the current saved-library checklist above.

The browser interface was also checked at 375 × 667: no horizontal overflow, all three navigation targets exceeded 44 px, and the visible interface contained no previous brand or prototype/demo wording. Current [mobile](mymah-finds-library-mobile.png) and [desktop](mymah-finds-library-desktop.png) previews are included in the handoff.

The original popup scaffold’s installation was not exercised in that earlier pass. Chime’s v0.3 side panel was tested in isolated Chrome for Testing, including local-backend host permission and screenshot sharing. Native host/share targets are project templates: Xcode signing, iOS builds, Simulator, and physical-device integration remain to be tested. Live PostgreSQL remains untested.

Before release, the backend owner must provide production identity/session handling, deployment settings, operational limits/monitoring, and data retention/erasure. Store publishing is separate work. The OpenAI adapter and image-upload contract are implemented on this branch. Live inference still needs a configured key and a real-provider evaluation; live catalogs, tracking and push remain future work.


## v0.3 integration: who does what

| Person | Next handoff |
| --- | --- |
| Chime | Try real articles, captions and screenshots; evaluate the question/choices and evidence. Chrome is in `experiments/chrome-sidepanel/`. |
| Haydn | Review/merge the additive API and migration; configure the model on the server; deploy a shared HTTPS backend when ready. |
| Adi | Use the same capture/media/answer contract in native screens. Swift transport/models are updated; native image picker, Share Extension image handling and question UI remain Adi’s work. |

| Need | Tool/API | Why |
| --- | --- | --- |
| Understand an article or screenshot | OpenAI Responses API, configurable `OPENAI_MODEL` (default `gpt-6-luna`) | One request accepts captured text and an image; no separate OCR service needed for this prototype. |
| Return a predictable MCQ | Strict JSON Schema plus Pydantic validation | One question, bounded choices/evidence, inspiration-only option added by the server. |
| Share across Chrome/web/iOS | Existing FastAPI endpoints and shared JS/Swift clients | Same durable save IDs, user ownership and mutation keys across surfaces. |
| Retain screenshots | Pillow validation + private `saved_media` table | No public image URLs, no third-party image fetching, delete with the save. Move to private object storage before scaling. |
| Process without blocking capture | Existing durable worker | The save succeeds before AI runs. Provider errors do not lose content; inference runs outside the DB transaction. |
| Verified price checks | Not connected yet | No current offers, inventory or discount claims are promised. Seller data and permissioned monitoring need separate integration. |

`POST /v1/saves`: `image_data` is an optional inline PNG/JPEG/WebP data URL. For an image-only capture, omit `url` or send `""`. Decoded image ≤4 MiB, ≤16 megapixels, one frame. The whole request is limited to 6 MiB. Chrome resizes uploads to ≤2048 pixels first. Images deduplicate by content hash per account, so different images from the same page remain separate saves.

`GET /v1/collection` and `GET /v1/saves/{id}` return `has_image`, `features.summary`, `features.question`, `features.evidence`, suggestions with stable IDs and `next_step`, and persisted `responses`. Full image bytes are excluded from collection pages. `GET /v1/saves/{id}/media` returns `{image_data}` with the same account authentication. `POST /v1/saves/{id}/responses` takes `{action:"select", suggestion_id}` (or edit/skip); the stored event includes the chosen label and next step. All mutations retain an `Idempotency-Key`.

`POST /v1/saves/{id}/retry` retries failed understanding, or upgrades a basic result after AI is enabled. It never resurrects a deleted save. `features.data_mode` distinguishes `openai`, `demo_rules` and `fallback`. Source quotes are checked against captured text. Image evidence is explicitly an unverified model reading, not merchant verification. No inference becomes a confirmed preference until the person chooses it.

For local testing, copy `.env.example` to `.env`, set CORS to the extension’s exact origin if required, then `make run`. Default `ANNOTATION_PROVIDER=demo` needs no paid API. To enable AI, set `ANNOTATION_PROVIDER=openai` and `OPENAI_API_KEY` in `.env` on the server and restart; never place the key in Chrome, iOS, Git, or a shared Page. Reconnect Chrome after changing the server mode, then use **Refresh / retry sync** to analyse earlier basic saves. The local backend binds only to `127.0.0.1:8000`.

Chrome stores its backend token in `chrome.storage.session`, so reconnect after a browser restart. New captures sync only after an explicit connection; old local captures require **Share with library**. Uncertain captures/answers retain their exact request and key in IndexedDB and retry only against the original account and backend. There is no unattended background sync promise. Delete removes both copies when connected to the owning account.

Validation for this increment is recorded in [the side-panel test notes](../experiments/chrome-sidepanel/TESTING.md). A live OpenAI call and native iOS UI have not been tested. The existing commerce fixtures must not be presented as live retail data.
