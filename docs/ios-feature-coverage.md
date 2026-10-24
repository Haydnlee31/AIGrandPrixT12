# Native framework feature coverage

This records implementation coverage, not a claim that a deployed account or AI provider was exercised. The SDK contract is `0.4.0`. The current integration guide prioritizes Library / Explore / Profile; older shopping-plan flows are optional connected tools and retain their source-mode disclosures.

## View entry points

- `SavedIntelligenceSection(item:connection:onChanged:)`: place beneath saved original/note. Local and sample records show `LocalIntelligencePreview`, including real local intention editing and clearly authored example analysis. The SDK only receives backend-returned item IDs.
- `ExploreScreen(connection:libraryRevision:onLocalChange:)`: complete tab with its own NavigationStack. Key the view by account generation. Pass the current saved IDs/revisions plus local intent/archive metadata to invalidate ideas after edits, capture, annotations and deletion; refresh the host library in `onLocalChange`.
- `SharedLibrarySearchScreen(connection:onDelete:)`: optional complete server-search screen within an existing NavigationStack. The host may instead call `searchLibrary` from its Library search UI.
- `FrameworkToolsView(connection:)`: connected Explore toolbar destination. Reads actual capabilities before offering discovery/watch tools. Profile remains account and settings.

## Local frontend preview

**Follow-up:** product-aware capture and local saved-item analysis now have a real optional OpenAI connection via the private capture-preview relay. See [live setup and evidence](ios-build.md#live-capture-intelligence-25-october-follow-up). This supersedes the no-provider-call status below for this small capture flow; full catalog Explore and the older shared-account tools still need their team backend.

Without an intelligence connection, local detail shows product/category/brand/style fields as **Not analyzed yet**, with a separate **Example preview** watch breakdown. With the optional relay connected, actual product analysis and model-written contextual note choices appear. Chosen intentions can be edited by typing or local speech-to-text, removed or skipped; explicit choices persist through `LocalLibrary.setIntent` and become searchable local metadata. Generic preset chips have been removed.

Local Explore includes five labeled illustrative ideas, bundled photos, category/style search and filters, detail screens, example explanations and example source records. These are authored examples, not inferred personal recommendations. A separate **Your finds** segment searches actual saved titles, text, notes and user-selected intentions. Saving an example explicitly adds labeled illustrative content to local Library. No sample offers include a merchant price or checkout URL; no preview claims that a user image was analyzed. This preview uses no remote API.

## Coverage

| Framework surface | Native implementation | Requires connection? | Evidence boundary |
| --- | --- | --- | --- |
| Product summary, multi-object observations, category path, brand/model, attributes, use cases, uncertainty | Saved intelligence section | Yes | Unknown brand/model remains unknown; inference is labeled; no product identity is fabricated |
| Analysis pending / failed / unavailable / ready | Saved intelligence section and bounded, cancellable polling | Yes | A failed analysis never becomes a failed save |
| Explicit reanalysis | Refresh details button, capability-gated | Yes, configured analysis | Uses SDK `analyzeSave`; no provider key entered in app |
| Predictive annotation select, edit, reject, skip | Optional suggestion rows, edit sheet and overflow actions | Yes | Acknowledged as annotation only, never reminder/purchase/monitor execution |
| Library search and analyzed category facets | Server search with pagination and total count | Yes | No complete-library download substituted for analyzed search |
| Personalized Explore and catalog query | Explore tab, debounced search, paging, refresh | Yes | Explicit needs-saves / needs-analysis / no-match states; no fake fallback results |
| Recommendation explanation and evidence | Why-this detail with exact saved-item route and catalog fields | Yes | Heuristic scores never displayed as preference probabilities |
| Catalog attribution / license / source link | Source section in Explore detail | Yes | Source record remains separate from offer; unknown price/merchant/stock preserved |
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

## Verification so far

- All native app sources, shared code and SDK compiled for a physical iOS target using a separate temporary Xcode project, `CODE_SIGNING_ALLOWED=NO`; `/tmp/mymah-framework-check-build.log` ended `BUILD SUCCEEDED`.
- At the initial frontend-only checkpoint, root and backend `.env` files were absent and no provider was called. The later live-capture follow-up is documented above; credentials are kept out of source control.
- Real API/UI end-to-end validation remains dependent on a reachable authenticated service. Compilation alone is not evidence that a live AI result, price observation or push notification ran.
- Focused source review tightened monetary parsing (reject partial pasted input), shared currency exponent formatting, active-account verification before connected requests, annotation capability gating and current-offer links. A current offer must be a production merchant record with a nonnegative price, supported currency, bounded observation window and the exact HTTPS offer URL. The integrated signed physical-device build passed with these fixes and the local preview screens; Explore and Profile were visually checked on Adi's iPhone.

## Recommended acceptance checks

With a configured development service, run image-only capture, unreadable brand, multiple products, pending/failure analysis, edited/rejected annotation, category search with paging, cited Explore, unknown-price records, deletion invalidation, account switch, a stale discovery version, and interrupted/retried mutation. Confirm all sample catalog and simulated tracking labels. For local mode, verify saved material stays available while Explore clearly explains connection-dependent functionality.

## Local iPhone implementation and verified run (25 October 2026)

- Link, photo(s), camera, text, and file capture; bounded local attachments with Quick Look; editable on-device voice-to-text notes.
- Shared extension handles public links, text and supplied files/photos locally. System keyboard dictation is available when enabled; a Share Extension cannot record microphone audio itself.
- Shared inbox uses the development profile's shared Keychain group, then imports atomically into ordinary app files. The signed local build includes both targets without App Groups. The full shared-backend project retains App Groups.
- Existing version-one local arrays migrate in place; notes and existing content survive app upgrades. Favorites, archive, sorting, grid/list, search, appearance and haptics persist.
- Signed iPhone build/install succeeded. Safari share was exercised on Adi's physical iPhone: the public Apple iPhone page and user note appeared in the app detail screen. This verifies extension-to-app local handoff. Instagram's own share payload, photo picking, and actual speech transcription still require separate device acceptance checks.
- Local disk smoke checks passed for save/reopen, duplicate note preservation, invalid input atomicity, photo/file/text bytes, edits, favorites/archive, idempotent import, removal and empty-library persistence.
- Ten SDK tests passed. Native Swift SDK also passed real HTTP checks against a temporary migrated loopback backend with isolated fixture accounts; no live AI provider or deployed cloud database was used.
- Share-sheet favorites/order are owned by iOS. Users pin Mynah under Share > More > Edit; code cannot force first position.
