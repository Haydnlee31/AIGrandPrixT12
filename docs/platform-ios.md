# Mymah Finds — iOS handoff

The shared native SDK and host/Share Extension scaffold live in `clients/ios`. The agreed app design is now **Library**, **Explore**, and **Profile**: saved content with analyzed search, cited product recommendations, and account/app controls. Existing native views predate this plan and are not yet the finished three-page experience. There is no Map or Community tab. The browser reference in `frontend/` is a separate client.

**Use the [Library / Explore / Profile integration guide](ios-ai-handoff.md) for the current contract (0.4.0).** Product analysis, [predictive annotations](predictive-annotations.md), server Library search and cited Explore are ready for teammate integration. Live watches, reminder execution and checkout remain separate work. A successful capture receipt immediately means **Saved to your library**; generation must not block that confirmation. The `CommonThreadKit` SDK and existing Keychain/App Group identifiers retain their internal names for compatibility; visible app and Share Sheet names are **Mymah Finds**.

## What is ready

- A dependency-free Swift package for iOS 16+, also compilable on macOS 13+: typed capture, product analysis, Library search, reanalysis, Explore reasons/citations, and annotation APIs. Older discovery/watch methods remain for compatibility.
- Injected API URL and bearer-token provider; structured error codes, request IDs and current-session snapshots for version conflicts. Default transport rejects redirects and uses an ephemeral session.
- Explicit `MutationKey` on every write. Persist and reuse the same key and exact payload for retries; create a new key only for a new user action.
- Bounded foreground enrichment polling, typed annotation intents and observations, image-only capture payloads, and authenticated `savedImage(id)` retrieval are ready. Teammates must wire the platform's image selection/sharing and the new analysis/chip presentation into their views.
- A durable capture outbox using one atomic file per immutable save, scoped to verified account and backend. No bearer token is serialized into the queue.
- Existing native navigation, saved-content rows and detail scaffolding to adapt. Any old local search or seeded/local-only cards must be replaced or connected to the shared backend for the new Library/Explore experience; their presence is not evidence that server AI ran.
- A bundled Share Extension scaffold. It accepts URL/plain text from `NSItemProvider`, lets the user review/edit and explicitly tap Save, queues before sending, and exposes pending/retry/discard states.
- Shared nonsecret App Group settings and Keychain token storage. Host account validation prevents replaying one account’s drafts as another account.
- `project.yml` for XcodeGen; target manifests and entitlements are generated from it.

## Start in Xcode

1. Install/select full Xcode with an iOS SDK. This machine currently has Command Line Tools only. Install XcodeGen if your team uses the supplied generator; otherwise create an iOS app plus Share Extension targets manually and add this local Swift package.
2. In `clients/ios/project.yml`, replace `COMMON_THREAD_BUNDLE_PREFIX`, `COMMON_THREAD_APP_GROUP` and the Keychain group suffix with identifiers owned by your team. Set `DEVELOPMENT_TEAM`. Both targets must use the same registered App Group and shared Keychain access group; the extension bundle ID must be under the app’s ID.
3. Run `xcodegen generate --spec clients/ios/project.yml` and open the generated `clients/ios/Mymah Finds.xcodeproj`. Select the **Mymah Finds** scheme. Check Signing & Capabilities for both targets. Generated plist/entitlement/project files are intentionally ignored; `project.yml` is the source.
4. Build and run on an iPhone simulator or device. In **Profile**, enter the backend origin and a team-supplied token. No token is compiled into the app. This uses the existing bearer-token backend; do not invent Apple/Google sign-in or other authentication functionality before the server supports it.
5. Share a web link from Safari, choose **Save to Mymah Finds**, review the content and tap Save. iOS controls Share Sheet presentation; users may need to enable/reorder the extension in the sheet’s options. The installed host app contains the extension—there is no Chrome-style installation inside iOS.

Use a trusted HTTPS development endpoint, including for a physical iPhone. The client accepts origin-only URLs and permits HTTP only for `localhost`, `127.0.0.1` and `::1`; remote/LAN HTTP and URL path prefixes are rejected. No global App Transport Security bypass is included. `localhost` on a physical iPhone refers to that phone, not your Mac. Use a trusted HTTPS dev tunnel or HTTPS LAN endpoint, with the correct server bind/firewall and local-network permission. If your localhost simulator setup requires a transport exception, scope it to Debug and the development host; never ship a broad arbitrary-load exception.

## Use the SDK

```swift
let client = try CommonThreadClient(baseURL: apiBaseURL) {
    try await credentialStore.validAccessToken()
}
let draft = PendingCapture(
    request: CaptureRequest(url: link, title: title, note: note),
    accountId: verifiedAccount.userId,
    baseURL: apiBaseURL
)
try await outbox.enqueue(draft) // only after the person taps Save
let receipt = try await client.capture(draft.request, key: draft.key)
try await outbox.remove(draft)
// Receipt is durable storage acknowledgment: show Saved to your library now.
// Refresh collection data immediately; optional suggestions can arrive later.
```

The outbox is for user-confirmed capture intent, not an automatic upload of visited content. Recover its scoped records when the app becomes active. Profile displays pending entries with sync and discard controls; design the final account-deletion flow. Don’t blindly retry permanent 4xx failures. `401` requires reconnection; `410 mutation_expired` means the original mutation cannot be replayed; `409 idempotency_conflict` means the key was used for a different request. Keep a failed intent visible until acknowledged or explicitly discarded. A duplicate capture keeps the existing note/text: display **Already in your library**, never imply the new note replaced the original.

Pagination is offset-based; restart from offset zero on foreground/refresh and deduplicate IDs when appending. Use `searchLibrary(query:category:limit:offset:)` to search the account's saved content and analyzed facets on the server. Use `explore(query:)` for catalog search and `explore()` for cited recommendations. The old scaffold's local filter is not the implementation of the new server search contract.

Read `capabilities()` and the [AI integration guide](ios-ai-handoff.md). The backend accepts image-only saves and the SDK preserves their payload through the outbox. `CaptureRequest.url` is optional; `imageDataUrl` carries JPEG/PNG/WebP bytes. A URL or image is required. URL-only analysis uses supplied title/text/note; it does not fetch the page or acquire its image. Saved-item `analysis` is nullable and `analysisStatus` describes readiness. Use `analyzeSave(_:key:)` to retry or request fresh analysis; explicit annotation selections/edits can queue refinement automatically. Show unknown identity as unknown and distinguish inferred style from observed details. Legacy discovery/watch flows, live monitoring, reminder delivery, checkout, push and Dots knowledge access remain outside this integration. Do not show provider-key controls. Dates are Unix seconds.

Explore chooses its source on the backend through `EXPLORE_CATALOG_SOURCE` (default `abo`). Render the supplied reasons, Library evidence links and catalog citation. Historical records with unknown price/merchant/URL are ideas or source records, not verified live offers. Refresh Explore after saves, annotation changes and deletion. The match score is a heuristic, not a prediction of purchase probability.

## Platform-specific work to remind the iOS teammate

| Area | Required design/integration work |
| --- | --- |
| Native interface | Implement Library, Explore and Profile. Add analyzed facets/search, optional annotation chips and **Why this?** citations. Refine safe areas, sheets, keyboard behavior, loading/empty/error/offline states, Dynamic Type, VoiceOver and dark mode. Preserve immediate save confirmation and edit/reject/skip. Legacy discovery, live watches and checkout remain deferred. |
| Share Sheet | Test Safari and third-party host payloads. Some hosts provide only a URL or text, not a preview image/title. Preserve explicit Save, cancellation, bounded work and pending-versus-synced status. Never scrape another app in the background. |
| Extension lifetime | The system may terminate the extension shortly after its task; the containing app may not be running. Queue before attempting network work, finish promptly, and recover on foreground. This scaffold does not implement background URLSession transfers. See Apple’s [extension lifecycle](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html). |
| Shared data and auth | Configure App Group and shared Keychain entitlements on both targets. Keep tokens in Keychain; shared preferences contain only nonsecret configuration. Coordinate a backend-issued login/session flow and handle expiry/sign-out. Keep the existing Keychain service identifiers stable when refining branding. See Apple’s [shared keychain access](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps) and [extension data sharing](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html). |
| Background work | Server workers must own reliable enrichment and eventual price schedules. iOS chooses when background refresh runs; a periodic phone timer cannot guarantee price checks. Cancel foreground polling when its screen/task is inactive. See Apple’s [background execution strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app). |
| Notifications | Design opt-in and notification deep links, but coordinate implementation with the backend. APNs requires app capability, device-token registration and a provider server; none is currently wired. In-app notification records are not push delivery. See Apple’s [APNs registration](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns). |
| Incoming links | Universal Links require your real domain, associated-domain entitlements and an association file. Do not promise opening a session from notifications until the routing contract is implemented. |
| Photos/camera | Add a system photo picker and image `NSItemProvider` handling under explicit user selection. Convert HEIC to JPEG/PNG, normalize orientation, and compress below the 4 MiB decoded limit. Update the URL/text-only Share Extension activation rule. Use authenticated `savedImage(id)` for display. |
| Account changes | Refresh server state on foreground; never combine account collections or replay drafts against a different backend/account. Include pending-draft deletion in sign-out/account-deletion UX decisions. |

## Verification and remaining device checks

Backend-produced fixtures are committed under `Tests/CommonThreadKitTests/Fixtures`; regenerate using `.venv/bin/python clients/ios/Scripts/export_fixtures.py` from the repository root. The script uses a temporary isolated database and no external services.

- `sh clients/ios/Scripts/smoke.sh` compiles the real SDK and runs a standalone macOS harness for actual API fixtures, typed analysis/search/Explore, mocked HTTP requests, stable retry payload/key, structured errors/conflicts, origin validation, polling and account-scoped durable queue behavior. This command passed on the current machine.
- `swift test --package-path clients/ios` runs the XCTest suite on a complete, matching toolchain. On this workstation SwiftPM’s installed `PackageDescription` module/library do not match (missing initializer linker symbol) and XCTest is absent. The XCTest command has **not passed here**.
- Native SwiftUI host and Share Extension targets are **not built or run here**: a full Xcode app/iOS SDK is unavailable. Project/signing setup and native behavior still need simulator/device validation.

Before handoff acceptance on a device, verify Library/Explore/Profile navigation; server Library search by detected style/category; readable versus unknown watch brands; analysis failure/retry; cited Explore cards and no-match/missing-offer states; profile/Keychain sharing; Safari URL/text/image shares; HEIC conversion; private image display; annotation select/edit/reject/skip and subsequent refinement; cancellation; offline recovery; extension termination; duplicate retries; account switching; API 401/409/410/422 handling; Dynamic Type and VoiceOver. Saved content must remain visible regardless of enrichment status. No backend Astra key was available for live-model verification here: configure it and run `make smoke-astra`, then exercise representative real captures. SDK tests do not establish device behavior or model recognition accuracy.
