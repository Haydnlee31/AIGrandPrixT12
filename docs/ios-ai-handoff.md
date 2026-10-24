# Mynah Finds — Library, Explore, Profile integration

The native navigation is **Library / Explore / Profile**. Two connections remain separate: local finds can use the optional shopping-intelligence relay; an authenticated team account uses the shared backend and SDK contract **0.4.0**. The local relay does not create or synchronize a team account.

## Current local iPhone flow

- Links, photos, camera captures, text and files save on the phone. Optional `POST /v1/capture-preview` uses OpenAI to produce a product name, grounded observations and contextual questions. Schema version 2 distinguishes current results from older stored analysis. LinkPresentation may supply page context and a product preview image; blocked/private pages still need a screenshot or useful description. Saving remains available if analysis fails.
- Internal category, brand and style fields support search and matching. The customer sees one **New Insights** section containing grounded SF Symbol observations, selected details and optional personalization. The actual saved photo carries one compact question that opens those choices; large accessibility text moves the question below the preview. No raw taxonomy panel or canned watch example is shown.
- **What caught your eye?** keeps up to eight editable details as compact chips. A chosen detail can open one skippable, product-grounded follow-up via `POST /v1/refine-intent`; prior answers and notes remain intact. Further refinement requires a deliberate tap, and only an explicit chosen response becomes user context. Each change persists locally and refreshes Explore.
- Minimal Library cards show image, title and source; find menus provide pin/unpin and other actions. Pins persist across archive/restore. Actual website images use bounded on-device LinkPresentation caching with compact failure fallbacks. Preview titles never replace saved titles. Model-generated product names can replace generic placeholders while explicit edits stay protected; only the four original starter records are removed.
- `LocalExploreScreen` sends the current, nonarchived shopping context to authenticated `POST /v1/recommendations`. It displays retrieved catalog records based on actual saves, notes and selected details; users can search or focus on one find. Cards link their reasons to the originating Library find and expose catalog source/record attribution. A glass **Explore / Your finds** switch separates actual recommendations from actual local saves, with material fallback on older iOS. Fictional furniture examples remain removed. Recent exact-context results are cached and shown before optional additional analysis; context changes clear stale results. Empty, unavailable and no-match states do not substitute unrelated products.
- An Amazon search link is a search, not a verified purchase offer. Historical catalog records do not establish current seller, price, stock or checkout availability. The bundle contains **284,368 mixed-source records**, including **147,702 Amazon Berkeley Objects records**, not 200,000 Amazon products. The verified local index holds **263,787 real/historical records** across six sources; 20,581 synthetic/fictional records are excluded. Catalog identity checks found no index mismatches, and the index contains no private Library records or current offer prices.

Provider credentials stay on the Mac's relay service, outside Git and the app bundle. The phone and extension store only a scoped relay token and HTTPS origin in shared Keychain. The currently configured Cloudflare development tunnel is temporary: the Mac, relay and tunnel must remain running. A durable cloud deployment is separate work. Disconnecting intelligence leaves local finds available.

## Sharing and device evidence

The Share Extension saves the original, optional analysis and selected details atomically through its local secure inbox. After persistence succeeds, **Saved!** appears briefly and the extension completes back to the original sharing app; **Done** can finish sooner. The old Open Mynah launch attempt has been removed. Failures remain visible for retry and never dismiss as if saved. Foregrounding Mynah imports the find and refreshes Library/Explore. iOS owns share-sheet ordering: **Share → More → Edit → Favorites**, then drag Mynah to the preferred position. Code cannot force it first.

The first share requests suggestions without an initial debounce. Supplied photos and useful product captions avoid unnecessary metadata fetching; generic social captions and bare links still use bounded LinkPresentation enrichment. No latency or private-page access is guaranteed. Profile appearance is mirrored through `SharedAppearance` in shared Keychain so a newly opened extension follows the same system/light/dark choice.

Share notes can use **system keyboard dictation**, which is not OpenAI transcription. Direct microphone recording belongs in the host: up to 60 seconds of AAC becomes editable text through authenticated `POST /v1/dictation`. Its request is `{"audio_data_url":"data:audio/mp4;base64,..."}` (also accepts `audio/m4a` and `audio/x-m4a`); success is `{"text":"..."}`. The relay validates a sound-only AAC/M4A container, caps decoded audio at 4 MiB, uses OpenAI `gpt-4o-mini-transcribe`, and never persists/caches audio or transcripts. The host removes its temporary recording after stop/cancel; retry audio is memory-only. Silence/invalid input and provider failures remain explicit errors, not invented words. Recording cancellation and stale results do not overwrite the user's note. [OpenAI transcription reference](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create).

The current middleware integration run passed **142 tests** across dictation, capture preview, local recommendations and catalog search index. Dictation tests use mocked upstream HTTP; an Apple-encoded AAC container separately passed format validation. Prior Safari-to-Library saving was verified on the physical iPhone. Device interaction and live-audio validation of this revision remain pending the integration run. Build/install, screenshots and tap-driven acceptance are reported separately in [iOS build evidence](ios-build.md); a successful compile or install is not a successful interaction test. Phone-mirror tap control is currently unavailable, so unperformed share/photo/voice interactions remain explicitly unverified.

## Connect the app to the shared backend

Configure `ASTRA_API_KEY` or `OPENAI_API_KEY` on the server, then run migrations and start the API. Provider keys never belong in the iOS app, a settings screen, the extension, or its requests. The app uses its team API origin and authenticated account token. Local relay saves are not shared-backend records: send team-account captures through `CommonThreadClient` and use the returned backend IDs for connected Library and Explore.

An iPhone needs a reachable HTTPS API endpoint; its loopback address is not the Mac. Keep the app's durable outbox scoped to the account and API origin. A capture receipt means the content is saved, even if intelligence is still processing. Use the same payload and mutation key when recovering an uncertain upload.

`make smoke-astra` makes one explicit paid image request using the backend credentials. This checks model access and connectivity, not recommendation quality on every product. Routine unit/SDK tests do not call the live model. Dots knowledge access remains deferred; no Dots sign-in or memory-import control should be added by assuming it is available.

## Library

Send `CaptureRequest` with the selected image, title, source URL when present, selected text, and optional user note. Image-only captures are supported. The iOS picker and Share Extension must convert HEIC to JPEG/PNG, apply orientation, and resize/compress before upload. Supported images are static JPEG, PNG, or WebP, at most **4 MiB decoded**; the entire request is capped at **6 MiB**. The server strips metadata and creates a bounded private image. This shared-account capture contract does not transcribe audio; host speech uses the separate local relay route above. An audio recording or video URL alone does not provide visual product analysis, and automatic video-frame extraction remains separate work.

For the shared 0.4.0 backend, a URL-only capture analyzes the title, selected text and note supplied by the client; the backend does not fetch arbitrary pages or remote images. Send selected image bytes for visual recognition. The separate local relay flow can receive page metadata and a preview image gathered by the iOS client.

Refresh the saved item after capture. `analysis_status` distinguishes `pending`, `ready`, `unavailable`, and `failed`. Show the saved content in every state. Failed or unavailable analysis must not be presented as a failed save. Cancel polling when the view closes or the account changes. Use `analyzeSave` to request a fresh analysis explicitly, retaining its mutation key for retries.

`SavedItem.analysis` contains these internal matching fields; they are not a customer-facing tag dump:

- A summary and up to four product observations for a multi-object image.
- `product_type` and `category_path`, ordered from broad category to the deepest supported subcategory.
- Nullable brand and model facts, each with its source basis and supporting evidence.
- Named attributes, such as digital display, vintage-inspired styling, case material, or colour, plus possible use cases and search terms.
- Intent context and uncertainties. These are model interpretations, not confirmation that a user wants to buy anything.

A brand is unknown when the logo or supplied text does not support it. Keep `null` values unknown instead of filling them from appearance or a nearby catalog match. `certainty: observed` means the model reports evidence in the capture; it does not establish a verified merchant identity. If a human-readable observation uses an inferred attribute, phrase it as an interpretation rather than an asserted manufacturing date or verified specification. Never promise that every image resolves an exact brand, SKU, material, or narrow category.

Load `image_path` through the authenticated `savedImage(id)` method. Do not put access tokens in URLs or shared image caches. Clear rendered images when the account changes. Image-only saves have an empty original URL, so hide **Open original** for those records.

## Predictive annotations

For the shared-account flow, render returned `suggestions` in their order as optional, readable rows. Their IDs, display text, intent code, and confirmation flag are server-owned. Keep an edit, reject, and skip path; do not select the first suggestion automatically. Submit an explicit selection/edit through `respond(to:with:key:)`.

Annotation selection records intent. `execution_status: annotation_only` does not mean a reminder was scheduled, a discount monitor started, or a purchase occurred. Use **Annotation saved** as the acknowledgment. A later reminder flow needs an actual date, time zone, scheduling, and notification delivery. Revisit the saved item after confirming or editing an annotation so the refreshed analysis and context can appear.

Deletion and rejection revoke the relevant context. Refresh affected Library and Explore views instead of retaining previously generated cards indefinitely. The backend removes dependent published predictions and regenerates them when their source evidence is withdrawn.

## Search

For connected accounts, use the server's Library search endpoint through `searchLibrary`; it searches the account's saved content and analyzed product facets. It also accepts a category filter. Continue using `next_offset` for paging and `total` for the matching Library count. This replaces the frontend's complete-library download/filter strategy for this flow. Search results use the same `SavedItem` model as Library details, including nullable analysis and private images.

```swift
let matches = try await api.searchLibrary(query: "vintage digital watch", limit: 20)
let recommendations = try await api.explore() // Backend-configured catalog source.
let searchedProducts = try await api.explore(query: "digital watch")
let refreshKey = MutationKey() // Persist before sending and retain for retries.
let queued = try await api.analyzeSave(savedItem.id, key: refreshKey)
```

Explore search uses `explore(query:)`. It searches the configured catalog source and returns source records with explanations and citations. The backend chooses its default source; a product UI does not need an infrastructure settings screen or a provider/source picker. A client may pass a source when deliberately implementing a source-specific catalog experience.

## Shared-account Explore

Connected Explore recommends catalog candidates using the current account's saved product categories and supported attributes. Confirmed annotations enrich intent separately. Matching and explanations use retrieved catalog facts, so the explanation can point back to both the saved content and the catalog record. Catalog content is not sent wholesale to Astra.

Keep **Why this?** available on each card. Display the returned explanation, linked Library evidence, matched fields, and catalog attribution. A Library citation should reopen the owner's saved item; a catalog citation should open the returned source record or valid source link. Do not manufacture external URLs or cite a different saved item. Treat generated/synthetic sources as such and keep each response's source attribution intact.

The SDK exposes `ExploreItem.reasons`, `catalogCitation`, `action`, and `actionUrl`. Reasons include matched values, catalog field/value, and applicable saved-item ID/revision, analysis path, or confirmed evidence ID. The page exposes `status` (`ready`, `needs_saves`, `needs_analysis`, `no_matches`), `contextVersion`, candidate/profile window limits, and `nextOffset`. Its score is `heuristic_match`, not a preference probability. Keep these operational fields available to the view model without putting debugging metadata on product screens.

Historical catalog records frequently have unknown price, merchant, stock, or purchase URL. Show a product as an idea or source record when those facts are absent. Do not label a missing price as free, a missing expiry as permanently current, or an unverified source link as a working checkout. Only offer a purchase-link affordance when the backend supplies a suitable current offer; confirmation and checkout remain outside annotation selection.

An empty or pending Library may not produce personalized candidates. Design explicit empty/loading/no-match states instead of substituting unrelated cards and presenting them as inferred preferences. Explore responses are bounded retrieval results, not a claim that the entire catalog was exhaustively ranked. Refresh on foreground and after saves, annotation changes, and deletion.

## Profile and acceptance

Profile remains account and app settings. Add no AI-key fields, invented Dots connection, or model controls. Product screens use **Mynah Finds**. Keep operational metadata behind the UI while retaining honest catalog attribution and historical-data disclosures.

The teammate's acceptance run should cover: image-only and link-plus-image capture; a recognizable watch versus an unreadable brand; multi-object images; pending and failed analysis; editing an annotation; search by a detected style/category; a cited Explore recommendation; no matching catalog records; missing price/merchant/URL; deletion withdrawing recommendations; account switching; offline outbox recovery; and native accessibility. Run on an actual device before relying on Share Extension permissions and memory limits; simulator compilation alone does not prove these interactions.
