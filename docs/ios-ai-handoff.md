# Mymah Finds — Library, Explore, Profile integration

The agreed navigation is now **Library / Explore / Profile**. The merged native app provides the existing iOS interface and storage scaffold; the teammate owns the new screens and their presentation. The shared backend and SDK provide product analysis, predictive annotations, Library search, and source-cited Explore results. Contract version: **0.4.0**.

## Connect the app to the shared backend

Configure `ASTRA_API_KEY` or `OPENAI_API_KEY` on the server, then run migrations and start the API. Provider keys never belong in the iOS app, a settings screen, the extension, or its requests. The app uses its existing Mymah API origin and authenticated account token. Local-only saves and seeded frontend cards do not run server analysis: send real captures through `CommonThreadClient` and use the returned backend IDs for Library and Explore.

An iPhone needs a reachable HTTPS API endpoint; its loopback address is not the Mac. Keep the app's durable outbox scoped to the account and API origin. A capture receipt means the content is saved, even if intelligence is still processing. Use the same payload and mutation key when recovering an uncertain upload.

`make smoke-astra` makes one explicit paid image request using the backend credentials. This checks model access and connectivity, not recommendation quality on every product. Routine unit/SDK tests do not call the live model. Dots knowledge access remains deferred; no Dots sign-in or memory-import control should be added by assuming it is available.

## Library

Send `CaptureRequest` with the selected image, title, source URL when present, selected text, and optional user note. Image-only captures are supported. The iOS picker and Share Extension must convert HEIC to JPEG/PNG, apply orientation, and resize/compress before upload. Supported images are static JPEG, PNG, or WebP, at most **4 MiB decoded**; the entire request is capped at **6 MiB**. The server strips metadata and creates a bounded private image. Video frames and speech transcription are separate work; an audio recording or video URL alone does not provide visual product analysis.

A URL-only capture analyzes the title, selected text, and note that the client supplied. The backend does not fetch the page or download an arbitrary remote image. Send the actual selected image bytes when the app expects visual recognition.

Refresh the saved item after capture. `analysis_status` distinguishes `pending`, `ready`, `unavailable`, and `failed`. Show the saved content in every state. Failed or unavailable analysis must not be presented as a failed save. Cancel polling when the view closes or the account changes. Use `analyzeSave` to request a fresh analysis explicitly, retaining its mutation key for retries.

`SavedItem.analysis` contains:

- A summary and up to four product observations for a multi-object image.
- `product_type` and `category_path`, ordered from broad category to the deepest supported subcategory.
- Nullable brand and model facts, each with its source basis and supporting evidence.
- Named attributes, such as digital display, vintage-inspired styling, case material, or colour, plus possible use cases and search terms.
- Intent context and uncertainties. These are model interpretations, not confirmation that a user wants to buy anything.

A brand is unknown when the logo or supplied text does not support it. Keep `null` values unknown instead of filling them from appearance or a nearby catalog match. `certainty: observed` means the model reports evidence in the capture; it does not establish a verified merchant identity. `inferred` attributes should be shown as interpretations, for example **Vintage-inspired style**, rather than asserted manufacturing dates. Never promise that every image resolves an exact brand, SKU, material, or narrow category.

Load `image_path` through the authenticated `savedImage(id)` method. Do not put access tokens in URLs or shared image caches. Clear rendered images when the account changes. Image-only saves have an empty original URL, so hide **Open original** for those records.

## Predictive annotations

Render the returned `suggestions` in their returned order as optional chips. Their IDs, display text, intent code, and confirmation flag are server-owned. Keep an edit, reject, and skip path; do not select the first suggestion automatically. Submit an explicit selection/edit through `respond(to:with:key:)`.

Annotation selection records intent. `execution_status: annotation_only` does not mean a reminder was scheduled, a discount monitor started, or a purchase occurred. Use **Annotation saved** as the acknowledgment. A later reminder flow needs an actual date, time zone, scheduling, and notification delivery. Revisit the saved item after confirming or editing an annotation so the refreshed analysis and context can appear.

Deletion and rejection revoke the relevant context. Refresh affected Library and Explore views instead of retaining previously generated cards indefinitely. The backend removes dependent published predictions and regenerates them when their source evidence is withdrawn.

## Search

Use the server's Library search endpoint through `searchLibrary`; it searches the account's saved content and analyzed product facets. It also accepts a category filter. Continue using `next_offset` for paging and `total` for the matching Library count. This replaces the frontend's complete-library download/filter strategy for this flow. Search results use the same `SavedItem` model as Library details, including nullable analysis and private images.

```swift
let matches = try await api.searchLibrary(query: "vintage digital watch", limit: 20)
let recommendations = try await api.explore() // Backend-configured catalog source.
let searchedProducts = try await api.explore(query: "digital watch")
let refreshKey = MutationKey() // Persist before sending and retain for retries.
let queued = try await api.analyzeSave(savedItem.id, key: refreshKey)
```

Explore search uses `explore(query:)`. It searches the configured catalog source and returns source records with explanations and citations. The backend chooses its default source; a product UI does not need an infrastructure settings screen or a provider/source picker. A client may pass a source when deliberately implementing a source-specific catalog experience.

## Explore

Explore recommends catalog candidates using the current account's saved product categories and supported attributes. Confirmed annotations enrich intent separately. Matching and explanations use retrieved catalog facts, so the explanation can point back to both the saved content and the catalog record. Catalog content is not sent wholesale to Astra.

Keep **Why this?** available on each card. Display the returned explanation, linked Library evidence, matched fields, and catalog attribution. A Library citation should reopen the owner's saved item; a catalog citation should open the returned source record or valid source link. Do not manufacture external URLs or cite a different saved item. Treat generated/synthetic sources as such and keep each response's source attribution intact.

The SDK exposes `ExploreItem.reasons`, `catalogCitation`, `action`, and `actionUrl`. Reasons include matched values, catalog field/value, and applicable saved-item ID/revision, analysis path, or confirmed evidence ID. The page exposes `status` (`ready`, `needs_saves`, `needs_analysis`, `no_matches`), `contextVersion`, candidate/profile window limits, and `nextOffset`. Its score is `heuristic_match`, not a preference probability. Keep these operational fields available to the view model without putting debugging metadata on product screens.

Historical catalog records frequently have unknown price, merchant, stock, or purchase URL. Show a product as an idea or source record when those facts are absent. Do not label a missing price as free, a missing expiry as permanently current, or an unverified source link as a working checkout. Only offer a purchase-link affordance when the backend supplies a suitable current offer; confirmation and checkout remain outside annotation selection.

An empty or pending Library may not produce personalized candidates. Design explicit empty/loading/no-match states instead of substituting unrelated cards and presenting them as inferred preferences. Explore responses are bounded retrieval results, not a claim that the entire catalog was exhaustively ranked. Refresh on foreground and after saves, annotation changes, and deletion.

## Profile and acceptance

Profile remains account and app settings. Add no AI-key fields, invented Dots connection, or model controls. Product screens use **Mymah Finds** and contain no prototype/demo wording or implementation diagnostics.

The teammate's acceptance run should cover: image-only and link-plus-image capture; a recognizable watch versus an unreadable brand; multi-object images; pending and failed analysis; editing an annotation; search by a detected style/category; a cited Explore recommendation; no matching catalog records; missing price/merchant/URL; deletion withdrawing recommendations; account switching; offline outbox recovery; and native accessibility. Run on an actual device as well as the simulator before relying on Share Extension permissions and memory limits.
