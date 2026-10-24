# Native framework feature coverage

The app uses **Library / Explore / Profile**. Local storage plus the configured optional intelligence relay is separate from the shared-account SDK contract `0.4.0`. Older shopping-plan tools still require that team backend. Implementation, automated checks, device installation and manually exercised interactions are separate evidence levels; see [build evidence](ios-build.md) for the current device run.

## View entry points

- `SavedIntelligenceSection(item:connection:onChanged:)`: local records show real optional relay analysis and editable intentions; connected records use their backend IDs. Customer-facing observations replace raw category/brand/style fields. `FindIntentOverlay` puts returned questions and selectable responses on the actual saved image.
- `ExploreScreen(connection:libraryRevision:onLocalChange:)`: complete tab with its own NavigationStack. Key the view by account generation. Pass current saved IDs/revisions plus local intent/archive metadata to invalidate recommendations after edits, capture, annotations and deletion; refresh the host library in `onLocalChange`.
- `SharedLibrarySearchScreen(connection:onDelete:)`: optional complete server-search screen within an existing NavigationStack. The host may instead call `searchLibrary` from its Library search UI.
- `FrameworkToolsView(connection:)`: connected Explore toolbar destination. Reads actual capabilities before offering discovery/watch tools. Profile remains account and settings.

## Local capture and recommendations

`POST /v1/capture-preview` returns schema-versioned OpenAI analysis, a concise product title and content-specific questions. Generated names replace placeholder/URL/photo-filename titles; explicit user edits remain protected. Library displays large, colorful SF Symbol observations, not internal classification fields. Notes and up to eight independently selected/edited intentions persist locally and update the revision used by Explore. The four original starter samples are removed by exact identity; fresh libraries start empty.

`LocalExploreScreen` replaces the former example/furniture and “Your finds” segments. It uses the user's nonarchived saves, notes, analysis and selected details with authenticated `POST /v1/recommendations`. Search and saved-find focus retrieve actual catalog records. Detail screens explain the match, reopen its source Library find, and retain catalog attribution. Empty/unavailable/no-match states show no canned fallback products. An Amazon search link is explicitly a search, not a live checkout or price guarantee.

The verified index contains **263,787 real/historical records**: Amazon Berkeley Objects 147,702; WANDS 42,994; Open Beauty Facts 40,029; Open Products Facts 25,114; Open Food Facts 2,999; UCI 4,949. The supplied 284,368-record bundle also contains 20,581 synthetic/fictional records excluded from this index. All nine source-file checksums passed; indexed record identities matched, with no private Library rows or current-offer prices. Therefore the app has access to 147,702 Amazon records, not a 200,000-product Amazon live merchant feed.

Prepare catalog data through `scripts/prepare_abo_catalog.py` or `scripts/prepare_recommendation_bundle.py /path/to/mymah-finds-catalogs.zip`; the database remains in ignored `local-data/recommendation-catalog.db`. The current relay uses a temporary Mac process and Cloudflare HTTPS tunnel, not a permanent cloud deployment. Provider credentials remain outside Git and the app; only a scoped relay connection is kept in shared Keychain.

## Coverage

| Framework surface | Native implementation | Requires connection? | Evidence boundary |
| --- | --- | --- | --- |
| Product understanding and grounded observations | Human-readable saved-find bullets; classification retained internally | Relay or team API | Uncertain identity remains uncertain; raw taxonomy is not a product-screen feature |
| Analysis pending / failed / unavailable / ready | Saved intelligence section and bounded, cancellable polling | Yes | A failed analysis never becomes a failed save |
| Explicit reanalysis | Refresh details button, capability-gated | Yes, configured analysis | Uses SDK `analyzeSave`; no provider key entered in app |
| Predictive intent choices and questions | Larger colorful rows, image overlays, multiple selections and editable details | Relay or team API for suggestions; local editing works offline | Choice records intent only; no automatic reminder, purchase or monitoring |
| Library search | Local saved content, selected intentions and analyzed facets; server search for connected accounts | Optional | Local metadata and account-scoped server search remain distinct |
| Personalized Explore and catalog query | Local relay retrieval; connected SDK search/paging retained | Relay or team API | Actual saves drive retrieval; no unrelated example fallback |
| Recommendation explanation and evidence | Larger evidence rows, exact saved-find routes and source attribution | Relay or team API | Heuristic scores never displayed as preference probabilities |
| Catalog attribution / license / source link | Source section in Explore detail | Relay or team API | Historical source record remains separate from any current merchant offer |
| Current offer link | Conditional View offer | Yes | Requires backend view-offer action and bounded current observation; otherwise View source record |
| Hypotheses and feedback | Shopping plans: confirm, keep collecting, misunderstood, dismiss; evidence routes | Yes | User decides whether a suggested direction fits |
| Discovery sessions | List/create/open, direction, clutter, budget, width, retrieve, compare, choose, already-own, too-expensive, pause/resume/dismiss | Yes | Current backend is sample desk-lighting data; clearly disclosed |
| Session version conflicts | Latest server snapshot shown, deliberate resubmission required | Yes | No blind replay over another device's changes |
| Legacy catalog | Browse catalog | Yes | Sample records labeled; no fake checkout links |
| Watches | Create target from plan product; list, edit target, pause/resume | Yes | Simulated mode disclosed; no live-price promise |
| Notifications | Paged in-app activity | Yes | No push-delivery claim when capability is false |
| Capture outbox/account/image attachment/auth | Host and shared modules, outside these new view files | Optional | Existing contracts preserved |
| Jobs | Bounded saved-item refresh follows enrichment | Yes | No generic infrastructure job inspector in product UI |
| Price simulation, trace, demo reset | Intentionally no ordinary product UI | Yes | Developer test endpoints are not customer actions |
| Checkout, live price polling, push, reminder scheduling, Dots memory | Unavailable in current backend | — | No inert or misleading working controls |

## Mutation recovery

`IntelligenceMutationKeys` writes the exact payload and idempotency key before a connected write. Origin, account, operation and payload determine its private hashed filename. Successful acknowledgments remove that entry. An interrupted retry with the same action uses the same key across app restarts; different payloads do not reuse keys. Files contain no credentials. There is no automatic replay of purchase/monitor/other actions.

## Verification boundaries

- The current catalog index contains 263,787 matching record identities. Representative watch and phone retrieval returned appropriate source records; recommendation/index suites passed 34 checks. These checks do not establish live inventory, stock, prices or a completed purchase.
- Expanded local storage checks passed for empty initialization, precise starter migration, legacy intention decoding, multi-intent bounds/persistence, schema-version persistence, generic-title migration without repeat writes, user-title protection, atomic share context and replay preserving later edits.
- Earlier signed physical-device builds and installation succeeded. Safari share → local Library was manually exercised on Adi's iPhone; a prior live capture flow returned OpenAI suggestions. Those earlier runs do not prove every interaction in the latest revision. Root records the final signed build/install and screenshots in [iOS build evidence](ios-build.md).
- Phone-mirror screenshots work, but tap control is failing. Do not describe photo picking, dictation, Instagram sharing or new controls as manually verified until exercised on the device. Compilation and installation alone establish neither successful taps nor live recommendation rendering.
- Shared-account SDK/loopback tests preserve authentication, outbox idempotency and account isolation. They use isolated fixture accounts and do not prove a deployed cloud database. Connected offer controls still require a validated current production merchant observation; historical relay results have no such offer.

## Recommended acceptance checks

With a configured development service, run image-only capture, unreadable brand, multiple products, pending/failure analysis, edited/rejected annotation, category search with paging, cited Explore, unknown-price records, deletion invalidation, account switch, a stale discovery version, and interrupted/retried mutation. Confirm all sample catalog and simulated tracking labels. For local mode, verify offline saving, generated titles, multiple intent choices refreshing Explore, source-finding links, empty results and unavailable relay behavior without losing saved material.

## Local iPhone implementation and verified run (25 October 2026)

- Link, photo(s), camera, text, and file capture; bounded local attachments with Quick Look; editable on-device voice-to-text notes.
- Share Extension accepts public links, text and supplied files/photos, with optional relay suggestions. Its save acknowledgment uses Done and asks the user to switch to Mynah. A supported Share Extension cannot reliably launch its host; the ineffective Open in Mynah control is removed. Keyboard dictation is available when enabled; direct microphone transcription is an app feature.
- Shared inbox uses the development profile's shared Keychain group, then imports the original content, optional analysis and selected intentions atomically into ordinary app files before acknowledging the queue. The signed local build includes both targets without App Groups. The full shared-backend project retains App Groups.
- Existing local arrays and documents migrate in place; user notes/content survive upgrades, with only the four known starter examples removed. Favorites, archive, sorting, grid/list, search, appearance and haptics persist.
- Signed iPhone build/install succeeded. Safari share was exercised on Adi's physical iPhone: the public Apple iPhone page and user note appeared in the app detail screen. This verifies extension-to-app local handoff. Instagram's own share payload, photo picking, and actual speech transcription still require separate device acceptance checks.
- Local disk smoke checks passed for save/reopen, duplicate note preservation, invalid input atomicity, photo/file/text bytes, edits, favorites/archive, idempotent import, removal and empty-library persistence.
- Ten SDK tests passed. Native Swift SDK also passed real HTTP checks against a temporary migrated loopback backend with isolated fixture accounts; no live AI provider or deployed cloud database was used.
- Share-sheet favorites/order are owned by iOS. Users pin Mynah under Share > More > Edit; code cannot force first position.
