# Native framework feature coverage

The app uses **Library / Explore / Profile**. Local storage plus the configured optional intelligence relay is separate from the shared-account SDK contract `0.4.0`. Older shopping-plan tools still require that team backend. Implementation, automated checks, device installation and manually exercised interactions are separate evidence levels; see [build evidence](ios-build.md) for the current device run.

## View entry points

- `SavedIntelligenceSection(item:connection:onChanged:)`: local records show real optional relay analysis and editable intentions; connected records use their backend IDs. **New Insights** unifies customer-facing observations, selected details and optional personalization. `FindIntentOverlay` presents one compact question on the actual saved image and leads into the section, rather than covering the image with all response choices. Large accessibility text moves the question below the preview.
- `ExploreScreen(connection:libraryRevision:onLocalChange:)`: complete tab with its own NavigationStack. Key the view by account generation. Pass current saved IDs/revisions plus local intent/archive metadata to invalidate recommendations after edits, capture, annotations and deletion; refresh the host library in `onLocalChange`.
- `SharedLibrarySearchScreen(connection:onDelete:)`: optional complete server-search screen within an existing NavigationStack. The host may instead call `searchLibrary` from its Library search UI.
- `FrameworkToolsView(connection:)`: connected Explore toolbar destination. Reads actual capabilities before offering discovery/watch tools. Profile remains account and settings.

## Local capture and recommendations

`POST /v1/capture-preview` returns schema-versioned OpenAI analysis, a concise product title and content-specific questions. Generated names replace placeholder/URL/photo-filename titles; explicit user edits remain protected. Library displays large, colorful SF Symbol observations, not internal classification fields. Notes and up to eight selected/edited details persist locally and update Explore. Selected details become compact chips; `POST /v1/refine-intent` provides one optional follow-up, preserving prior answers. Stable view identity preserves open refinement/editing sheets during metadata refresh. The four original starter samples are removed by exact identity; fresh libraries start empty.

`LocalExploreScreen` uses a glass Explore / Your finds switch, with material fallback before iOS 26. Explore shows actual retrieved products; Your finds shows the user's real local collection. Canned furniture examples remain removed. It uses the user's nonarchived saves, notes, analysis and selected details with authenticated `POST /v1/recommendations`. Search and saved-find focus retrieve actual catalog records. A bounded exact-context cache reuses recent results; obsolete requests cancel and changed context clears stale cards. Catalog retrieval renders before optional additional analysis. Detail screens explain the match, reopen its source Library find, and retain catalog attribution. Empty/unavailable/no-match states show no canned fallback products. An Amazon search link is explicitly a search, not a live checkout or price guarantee.

The verified index contains **263,787 real/historical records**: Amazon Berkeley Objects 147,702; WANDS 42,994; Open Beauty Facts 40,029; Open Products Facts 25,114; Open Food Facts 2,999; UCI 4,949. The supplied 284,368-record bundle also contains 20,581 synthetic/fictional records excluded from this index. All nine source-file checksums passed; indexed record identities matched, with no private Library rows or current-offer prices. Therefore the app has access to 147,702 Amazon records, not a 200,000-product Amazon live merchant feed.

Prepare catalog data through `scripts/prepare_abo_catalog.py` or `scripts/prepare_recommendation_bundle.py /path/to/mymah-finds-catalogs.zip`; the database remains in ignored `local-data/recommendation-catalog.db`. The current relay uses a temporary Mac process and Cloudflare HTTPS tunnel, not a permanent cloud deployment. Provider credentials remain outside Git and the app; only a scoped relay connection is kept in shared Keychain.

Library cards are minimal image/title/source views, with pin/unpin in menus and persisted pinned-first ordering. Pins survive archive/restore. Actual LinkPresentation source images use a bounded, coalesced on-device cache; unavailable previews fall back compactly and never rename a saved custom title.

## Coverage

| Framework surface | Native implementation | Requires connection? | Evidence boundary |
| --- | --- | --- | --- |
| Product understanding and grounded observations | Unified New Insights section; classification retained internally | Relay or team API | Uncertain identity remains uncertain; raw taxonomy is not a product-screen feature |
| Analysis pending / failed / unavailable / ready | Saved intelligence section and bounded, cancellable polling | Yes | A failed analysis never becomes a failed save |
| Explicit reanalysis | Refresh details button, capability-gated | Yes, configured analysis | Uses SDK `analyzeSave`; no provider key entered in app |
| Predictive intent choices and questions | Compact photo question leading to New Insights, selected chips and one skippable progressive follow-up | Relay or team API for suggestions; local editing works offline | Choice records intent only; no automatic reminder, purchase or monitoring |
| Host voice note | AAC microphone recording, OpenAI transcription, editable result and explicit retry | Relay | Up to 60 seconds / 4 MiB; relay retains no audio/transcript; mocked transport and format checks are not live voice acceptance |
| Share save completion | Saved acknowledgment, then return to the original app after durable inbox write | No | No Open Mynah launch attempt; failed persistence stays visible |
| Shared appearance | Profile system/light/dark value mirrored to shared Keychain | No | Newly opened Share Extension follows the same choice; current device validation remains separate |
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
- Expanded local storage checks passed for pin persistence/archive restoration and legacy pin decoding, empty initialization, precise starter migration, legacy intention decoding, multi-intent bounds/persistence, schema-version persistence, generic-title migration without repeat writes, user-title protection, atomic share context and replay preserving later edits.
- The previous integrated signed build installed successfully on Adi’s iPhone. Screenshots verified actual website previews, Explore / Your finds and the live AI refinement sheet; all five then-current finds remained byte-equivalent at the stored JSON level after installation and view-only checks. The current revision removes Open Mynah, adds automatic return after saving, unifies New Insights and uses host OpenAI dictation. The current signed build was also installed. Screenshots verified the real website preview in light mode and New Insights in dark mode; all six current finds remained identical after installation and view-only checks. Earlier Safari share → local Library evidence does not prove the new automatic-return gesture. See [iOS build evidence](ios-build.md).
- Current middleware integration checks passed **142 tests** across dictation, capture preview, local recommendations and catalog search index. Audio transport tests mock OpenAI responses; a real Apple-encoded AAC container separately passed format validation. A separate real authenticated HTTPS transcription returned HTTP 200 and the exact synthetic spoken test phrase in 2.1 seconds. Physical microphone interaction still requires manual acceptance; the fixture does not establish that gesture.
- Phone-mirror screenshots work, but tap control is failing. Do not describe photo picking, dictation, Instagram sharing or new controls as manually verified until exercised on the device. Compilation and installation alone establish neither successful taps nor live recommendation rendering.
- Shared-account SDK/loopback tests preserve authentication, outbox idempotency and account isolation. They use isolated fixture accounts and do not prove a deployed cloud database. Connected offer controls still require a validated current production merchant observation; historical relay results have no such offer.

## Recommended acceptance checks

With a configured development service, run image-only capture, unreadable brand, multiple products, pending/failure analysis, edited/rejected annotation, category search with paging, cited Explore, unknown-price records, deletion invalidation, account switch, a stale discovery version, and interrupted/retried mutation. Confirm all sample catalog and simulated tracking labels. For local mode, verify offline saving, generated titles, multiple intent choices refreshing Explore, source-finding links, empty results and unavailable relay behavior without losing saved material.

## Local iPhone implementation and evidence (25 October 2026)

- Link, photo(s), camera, text, and file capture; bounded local attachments with Quick Look. Host microphone recordings now use OpenAI through authenticated `/v1/dictation` to produce editable notes, replacing the earlier on-device speech-recognition path. Recordings stop at 60 seconds; decoded input is limited to 4 MiB. The relay uses `gpt-4o-mini-transcribe`, bounds timeout/rate/concurrency, and logs or retains neither audio nor transcript. The host removes temporary audio at stop/cancel and holds retry audio only in memory.
- Share Extension accepts public links, text and supplied files/photos, with optional relay suggestions. First-request analysis starts promptly; useful supplied captions/photos bypass unnecessary page metadata, while bare links retain bounded enrichment. After a successful durable save, a brief **Saved!** acknowledgment automatically returns to the original app. **Done** can dismiss it sooner. The old Open Mynah button/launch attempt is removed. Save errors remain visible for retry. Share keyboard dictation is the system feature, not OpenAI; no direct microphone recording occurs in the extension.
- Shared inbox uses the development profile's shared Keychain group, then imports the original content, optional analysis and selected intentions atomically into ordinary app files before acknowledging the queue. The signed local build includes both targets without App Groups. The full shared-backend project retains App Groups.
- Existing local arrays and documents migrate in place; user notes/content survive upgrades, with only the four known starter examples removed. Favorites, archive, sorting, grid/list, search, appearance and haptics persist. `SharedAppearance` mirrors Profile's system/light/dark choice through shared Keychain for the local Share Extension.
- Signed iPhone build/install succeeded. Safari share was exercised on Adi's physical iPhone: the public Apple iPhone page and user note appeared in the app detail screen. This verifies extension-to-app local handoff. Instagram's own share payload, photo picking, and actual speech transcription still require separate device acceptance checks.
- Local disk smoke checks passed for save/reopen, duplicate note preservation, invalid input atomicity, photo/file/text bytes, edits, favorites/archive, idempotent import, removal and empty-library persistence.
- Ten SDK tests passed. Native Swift SDK also passed real HTTP checks against a temporary migrated loopback backend with isolated fixture accounts; no live AI provider or deployed cloud database was used.
- Share-sheet favorites/order are owned by iOS. Users pin Mynah under Share > More > Edit; code cannot force first position.


## Latest native follow-up (25 October 2026)

This section supersedes earlier descriptions of the microphone, Explore tab labels and appearance verification above.

- Library has persisted All, Images, Links, Voice, Files and Text format filters, combined with search, collection/source filters and pinned-first ordering. A find can match multiple formats. Voice includes audio attachments and previously recorded dictation provenance; older typed notes are never relabeled as voice.
- Explore's secondary segment is **Insights**. Floating question cards use horizontal paging and visible page dots. Catalog photos use bounded/coalesced downloading, decoding, cache and retry; missing source images are disclosed.
- Radar is a fourth native tab. It derives intentions from saves, lets the user edit the brief, shows catalog matches with saved-find evidence and explicitly creates local product/brand/category/need watches. Watches can be edited, paused, removed and checked manually. There is no connected background monitor, automatic price history, notification delivery or current-offer guarantee.
- First-opening share suggestions and return to the originating app are user-confirmed. A lifecycle gate prevents canceled/not-ready tasks from invalidating a ready request; 14 focused checks pass.
- The custom microphone is removed at the user's request after physical-device failure. Typed notes and iPhone keyboard dictation remain available. Existing audio attachments and historical voice-note metadata are preserved. The relay dictation endpoint remains available to other clients; no native microphone UI calls it.
- A shared appearance state replaces independent preference observers after device testing showed a persisted selection without a visible mode change. On the final installed build, Aditya confirmed that Dark and Light both switch the app immediately.
- Recommendation/index checks pass 57 tests. The restarted relay returned 24 actual catalog matches for the seven-save snapshot with zero incorrect landline matches for smartphone saves.


## Current Radar and product grouping update

- Radar review: editable intention, budget slider, persistent Show matches button, explicit keyboard dismissal and no autofocus. Results are a photo-led grid with product detail and Back navigation. Typed intentions no longer require source saves.
- Exact repeat saves automatically appear together. Grouped notes/preferences/analysis remain attached to the product; original records and files are retained. Source aliases, group edits, flags and explicit deletion are handled by the local store.
- Removed Explore's separate Insights list. Product cards show an insight preview; each detail combines highlights and original-source evidence/notes inline.
- Focused real-data store verification: eight device snapshot records produce six groups; every original ID resolves and the copied source JSON remains unchanged. Tests cover identical photo sets, different URL variants, repeated-share replay, clear/unpin behavior and new context added after merging.
- Live intent-only Radar examples: a silver retro watch returned 12 real catalog records with 12 photos; a small-desk reading lamp returned 12 records with nine photos. Budget does not imply verified live prices. Some catalog sources omit photos; exact-source recovery is separate from product recommendation.

- Final iPhone acceptance confirms Radar intention → budget slider → photo results, keyboard dismissal and Back navigation work. The signed build is installed; all eight original Library saves remain unchanged behind the grouped presentation.
