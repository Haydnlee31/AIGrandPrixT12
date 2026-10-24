# Mynah Finds — iOS handoff

**Native frontend update, 25 October 2026:** the iPhone app now defaults to a persistent on-device library with four labeled sample finds, onboarding, capture with optional editable voice notes, search and saved-item details. It requires no backend/database setup. Profile can optionally connect the existing shared backend; local finds remain separate. The shared SDK, outbox, Keychain and Share Extension paths are preserved. The Share Extension still requires a connected shared account. See [build and validation](ios-build.md).

The native integration lives in `clients/ios`. The SwiftUI host uses exactly three native tabs: **Library**, **Search**, and **Profile**. Library contains the person’s saved content; Search filters titles, notes, saved text and URLs already loaded into that library; Profile holds connection, session and pending-save controls. There is no Map or Community tab. The browser interface in `frontend/` is a separate client.

Intelligence and catalog integration are deferred. Keep suggestions, discovery, recommendations, price watches and processing status out of the current interface. A successful capture receipt immediately means **Saved to your library**. The `CommonThreadKit` SDK and existing Keychain/App Group identifiers retain their internal names for compatibility; visible app and Share Sheet names are **Mynah Finds**.

## What is ready

- A dependency-free Swift package for iOS 16+, also compilable on macOS 13+: typed capture, collection, annotation, hypothesis, discovery, catalog, watch, job and notification APIs.
- Injected API URL and bearer-token provider; structured error codes, request IDs and current-session snapshots for version conflicts. Default transport rejects redirects and uses an ephemeral session.
- Explicit `MutationKey` on every write. Persist and reuse the same key and exact payload for retries; create a new key only for a new user action.
- Foreground enrichment polling remains available in the SDK for future integration; the current library interface does not invoke it or expose enrichment status.
- A durable capture outbox using one atomic file per immutable save, scoped to verified account and backend. No bearer token is serialized into the queue.
- Native Library/Search/Profile navigation, real saved-content rows and a detail view with the original link, personal note and saved text. Search runs locally and clearly offers **Load more saved items** when older pages are not yet loaded. No catalog results or invented profile information are shown.
- A bundled Share Extension scaffold. It accepts URL/plain text from `NSItemProvider`, lets the user review/edit and explicitly tap Save, queues before sending, and exposes pending/retry/discard states.
- Shared nonsecret App Group settings and Keychain token storage. Host account validation prevents replaying one account’s drafts as another account.
- `project.yml` for XcodeGen; target manifests and entitlements are generated from it.

## Start in Xcode

1. Open the checked-in `clients/ios/Mymah Finds.xcodeproj` in full Xcode. Run `sh clients/ios/Scripts/generate-project.sh` after adding source files; the pinned generator is downloaded locally when required.
2. In `clients/ios/project.yml`, replace `COMMON_THREAD_BUNDLE_PREFIX`, `COMMON_THREAD_APP_GROUP` and the Keychain group suffix with identifiers owned by your team. Set `DEVELOPMENT_TEAM`. Both targets must use the same registered App Group and shared Keychain access group; the extension bundle ID must be under the app’s ID.
3. Run `sh clients/ios/Scripts/generate-project.sh` and select the **Mymah Finds** scheme. Check Signing & Capabilities for both targets. Commit the generated project, plists and entitlements with their `project.yml` source.
4. Build and run on an iPhone simulator or device; the local library works immediately. For optional shared-backend integration, expand **Connect a shared library** in **Profile** and enter the backend origin and a team-supplied token. No token is compiled into the app. This uses the existing bearer-token backend; do not invent Apple/Google sign-in or other authentication functionality before the server supports it.
5. Share a web link from Safari, choose **Save to Mynah Finds**, review the content and tap Save. iOS controls Share Sheet presentation; users may need to enable/reorder the extension in the sheet’s options. The installed host app contains the extension—there is no Chrome-style installation inside iOS.

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
// Refresh collection data; do not wait for intelligence or show processing UI.
```

The outbox is for user-confirmed capture intent, not an automatic upload of visited content. Recover its scoped records when the app becomes active. Profile displays pending entries with sync and discard controls; design the final account-deletion flow. Don’t blindly retry permanent 4xx failures. `401` requires reconnection; `410 mutation_expired` means the original mutation cannot be replayed; `409 idempotency_conflict` means the key was used for a different request. Keep a failed intent visible until acknowledged or explicitly discarded. A duplicate capture keeps the existing note/text: display **Already in your library**, never imply the new note replaced the original.

Pagination is offset-based; restart from offset zero on foreground/refresh and deduplicate IDs when appending. Search matches the current loaded library only and discloses this when more pages remain. It does not call a search service, browse the web, query a catalog or simulate AI results.

The SDK still includes annotation/discovery/catalog/watch methods and corresponding fixtures, but they are not connected to this interface. Read `capabilities()` before any future integration and coordinate its contract with the backend owner. Images, merchant handoff, live price monitoring, push and personal-agent connectors remain unavailable. The API requires a public HTTP(S) URL even for a text share; image-only and text-only saves have no upload endpoint. Do not show internal fixture/provider/mode labels in the app. Dates are Unix seconds.

## Platform-specific work to remind the iOS teammate

| Area | Required design/integration work |
| --- | --- |
| Native interface | Preserve exactly Library, Search and Profile. Refine native safe areas, sheets, keyboard behavior, loading/empty/error/offline states, Dynamic Type, VoiceOver and dark mode. Keep Library about saved content and capture immediate. Do not add suggestions, discovery or catalog UX yet. |
| Share Sheet | Test Safari and third-party host payloads. Some hosts provide only a URL or text, not a preview image/title. Preserve explicit Save, cancellation, bounded work and pending-versus-synced status. Never scrape another app in the background. |
| Extension lifetime | The system may terminate the extension shortly after its task; the containing app may not be running. Queue before attempting network work, finish promptly, and recover on foreground. This scaffold does not implement background URLSession transfers. See Apple’s [extension lifecycle](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html). |
| Shared data and auth | Configure App Group and shared Keychain entitlements on both targets. Keep tokens in Keychain; shared preferences contain only nonsecret configuration. Coordinate a backend-issued login/session flow and handle expiry/sign-out. Keep the existing Keychain service identifiers stable when refining branding. See Apple’s [shared keychain access](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps) and [extension data sharing](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html). |
| Background work | Server workers must own reliable enrichment and eventual price schedules. iOS chooses when background refresh runs; a periodic phone timer cannot guarantee price checks. Cancel foreground polling when its screen/task is inactive. See Apple’s [background execution strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app). |
| Notifications | Design opt-in and notification deep links, but coordinate implementation with the backend. APNs requires app capability, device-token registration and a provider server; none is currently wired. In-app notification records are not push delivery. See Apple’s [APNs registration](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns). |
| Incoming links | Universal Links require your real domain, associated-domain entitlements and an association file. Do not promise opening a session from notifications until the routing contract is implemented. |
| Photos/camera | Images require a separate upload/storage contract and explicit user permissions/selection. The current Share Extension activation rule deliberately supports web URLs and text only. |
| Account changes | Refresh server state on foreground; never combine account collections or replay drafts against a different backend/account. Include pending-draft deletion in sign-out/account-deletion UX decisions. |

## Verification and remaining device checks

Backend-produced fixtures are committed under `Tests/CommonThreadKitTests/Fixtures`; regenerate using `.venv/bin/python clients/ios/Scripts/export_fixtures.py` from the repository root. The script uses a temporary isolated database and no external services.

- `sh clients/ios/Scripts/smoke.sh` compiles the real SDK and runs a standalone macOS harness for 20 actual API response fixtures, mocked HTTP requests, stable retry payload/key, structured errors/conflicts, origin validation, polling states/options and account-scoped durable queue behavior. This command passed on the current machine.
- `swift test --package-path clients/ios` passed 9 SDK tests under full Xcode 27.1 on the iOS teammate workstation. The original handoff workstation had a mismatched Command Line Tools installation.
- Native SwiftUI host and embedded Share Extension build with Xcode for a generic iOS simulator. The local-library smoke and real Swift-to-FastAPI smoke passed. Native rendering, microphone, shared Keychain and Safari Share Sheet still require a compatible ordinary-iPhone runtime or signed device; see the precise boundary in `ios-build.md`.

Before handoff acceptance on a device, verify Library/Search/Profile navigation; actual library rows and saved-item details; local search and older-page loading; profile connection and Keychain sharing; Safari URL and text-link shares; unsupported image-only share behavior; cancellation; offline Save and foreground recovery; termination immediately after Save; repeated retry without duplicates; sign-out/account switching with pending drafts; API 401/409/410/422 handling; Dynamic Type and VoiceOver. Saved content must remain visible regardless of enrichment status. These checks are native acceptance work, not claimed completed by the macOS SDK test.
