# Native iPhone build

The app has a local-first iPhone frontend and an optional connection to the team backend. The regular project retains App Group provisioning for shared cloud configuration. A separate local-device generator builds and signs the host plus a working local Share Extension using Keychain Sharing. The [Library / Explore / Profile handoff](ios-ai-handoff.md) describes the backend screen contracts.

Open `clients/ios/Mymah Finds.xcodeproj` in Xcode and select the **Mymah Finds** scheme. The checked-in project contains the iPhone app, embedded **Mynah Finds** Share Extension, and the local `CommonThreadKit` Swift package. The app targets iOS 18 or later. The reusable SDK retains its iOS 16 minimum.

## Reproduce the project and build

From the repository root:

```sh
sh clients/ios/Scripts/build-simulator.sh
```

This regenerates the project from `clients/ios/project.yml` using the pinned XcodeGen 2.46.0 official release and builds for a generic iOS simulator. The generator downloads to a temporary cache and verifies its published SHA256; no Homebrew or global installation is needed. Full Xcode, Python 3, curl and standard macOS command-line tools are required. Build products default to the temporary `mymah-finds-derived` folder; set `MYMAH_DERIVED_DATA` to choose another path.

After adding or removing Swift source files, regenerate with:

```sh
sh clients/ios/Scripts/generate-project.sh
```

Commit `project.yml`, the generated `.xcodeproj/project.pbxproj`, shared scheme, and Configuration plists/entitlements together. Per-user Xcode state stays ignored.

## Run and signing

Choose an installed ordinary iPhone simulator in Xcode, then Run. A generic simulator build proves compilation and extension embedding; it does not launch or validate the native screens. If the only installed runtime supports iPhone Duo, install an iOS runtime compatible with a standard iPhone before running. Do not substitute or rename a Duo device.

Simulator builds use `CODE_SIGNING_ALLOWED=NO`. To run on a physical iPhone, set your team's `DEVELOPMENT_TEAM` and owned identifiers in `project.yml`, regenerate, then verify Signing & Capabilities for both targets. Defaults are `com.aigrandprix.mymahfinds`, extension suffix `.share`, and App Group `group.com.aigrandprix.mymahfinds`; these are build configuration values, not a claim that Apple Developer identifiers have been registered. For this full configuration, both targets must share the App Group and Keychain access group. A configured but unavailable App Group produces an error; the app does not silently switch storage containers.

The app requests microphone and speech recognition permission only when starting voice capture. Debug plists permit local networking for simulator development. Release plists retain standard App Transport Security; no arbitrary-load bypass is enabled. The SDK restricts insecure HTTP to loopback origins; use HTTPS for a remote server or physical iPhone.

## Local device build with Share Extension

When the development profile permits Keychain Sharing but lacks App Groups, generate the explicit local-device project. This does not change the regular project or remove its production entitlements:

```sh
sh clients/ios/Scripts/generate-local-device-project.sh YOUR_DEVELOPMENT_TEAM
xcodebuild -project '/tmp/mynah-local-device/Mynah Finds Local.xcodeproj' \
  -scheme 'Mynah Finds' -configuration Debug \
  -destination 'id=YOUR_IPHONE_UDID' \
  -derivedDataPath /tmp/mynah-local-device-build build
xcrun devicectl device install app --device YOUR_IPHONE_UDID \
  /tmp/mynah-local-device-build/Build/Products/Debug-iphoneos/CommonThread.app
xcrun devicectl device process launch --device YOUR_IPHONE_UDID com.aigrandprix.mymahfinds
```

Pass an optional second argument to the generator to choose its output directory. The local project uses the existing bundle IDs, so installing over the previous preview preserves its app sandbox. It embeds `com.aigrandprix.mymahfinds.share`; both targets declare the same team-prefixed Keychain access group. The helper itself does not download an iOS runtime or require a backend.

In Safari or another app, choose Share → Mynah Finds (use More if needed). The extension accepts links, text, photos, and files, and lets you edit the title, captured text, and optional note. It shows available attachments and explicit import failures. If only part of a share was readable, saving the available subset requires a visible confirmation toggle. Photos are downsampled to JPEG for the local handoff. Limits are 10 attachments, 4 MB per attachment and 12 MB total; larger media must be reduced or saved as a link. This does not download an Instagram post's private media: it saves the URL or media that Instagram actually shares.

Confirmed saves are queued in bounded Keychain entries, encrypted with `AfterFirstUnlockThisDeviceOnly`, with synchronization disabled. A manifest is committed after the payload chunks. The host imports by stable UUID into its ordinary local file store, then removes the queue entry. Opening or refreshing the local library completes the import. This inbox is a development handoff, not permanent media storage; a normally provisioned build can use an App Group folder instead. Reinstallation should not be treated as a way to erase pending Keychain data.

Apple prohibits direct microphone access in ordinary Share Extensions. The extension's editable note supports the system keyboard's dictation when the keyboard offers it; direct voice capture belongs in the host app. See [Apple's extension restrictions](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html). Camera and microphone permissions are requested by the host when those features are used.

## Local frontend and optional connection

The app starts with an empty on-device library. Upgrades remove only the four exact original starter records; real saves and attachments remain intact. Capture links, photos, camera images, text, or files, with an optional title and typed/voice note. Local saves, search, editing and deletion work without a server or database. Local saves and attachments are persisted in Application Support. Generated sample imagery is illustrative; provenance is in `clients/ios/ASSETS.md`. Sample content has no merchant links or invented prices.

Profile → Connect a shared library is optional. It switches to the existing backend library and leaves local finds separate; signing out returns to the local library. There is no automatic upload or merge of local saves. The Share Extension always saves locally and requires no login, even when the host has a backend connection. Return to the local library to import and view these shared finds.

Enter the backend origin and a team-supplied access token in Profile. Tokens are stored in Keychain, not build settings or source control. In the regular build, nonsecret connection configuration and account-scoped cloud pending captures use the shared App Group. In the explicitly group-free local build, Profile can still connect: connection configuration uses the host's standard preferences, and cloud pending captures use the host's Application Support `MynahFinds/CaptureOutbox` directory. Tokens remain in Keychain in both builds. Queued cloud captures preserve account, API origin, and mutation key when retried; signing out leaves them scoped to their original account. The local Share Extension never inherits this cloud connection or uploads content.

See `platform-ios.md` for the SDK, server contract and device acceptance checks. Its earlier workstation limitations describe the original handoff environment; use current build output for this checkout's validation status.

## Validation on 25 October 2026

- Earlier baseline: `sh clients/ios/Scripts/build-simulator.sh` passed for generic iOS Simulator (arm64 and x86_64). The expanded local/preview UI is validated with the signed physical-device build below.

- `swift test --package-path clients/ios`: 10 SDK tests passed.
- `sh clients/ios/Scripts/local_library_smoke.sh`: samples, durable save/reopen, canonical duplicate preservation, invalid-input atomicity, image/file/text bytes, edits, favorites/archive/intent persistence, idempotent import, deletion and empty-library persistence passed without network.
- `sh clients/ios/Scripts/native_http_smoke.sh`: real Swift SDK against isolated FastAPI passed capture/outbox, receipt, replay idempotency, duplicate notes, account isolation and deletion. No deployed database used.
- Local physical-device host plus embedded Share Extension compiled and signed successfully with the cached wildcard development profile using the local-device generator. Host and extension entitlements were inspected and contain the same Keychain access group.
- Final Library / Explore / Profile UI and local preview content passed the integrated signed build and installation. Explore, Profile and the multi-format capture sheet were visually checked on Adi’s iPhone; this does not imply live GPT analysis or recommendation execution.
- The local inbox checks passed JSON photo/link round trips, stable IDs, Unicode-aware field limits, oversized-attachment rejection and empty-share rejection. Separately, the Safari share flow was verified on Adi’s physical iPhone: the Apple iPhone URL and user note appeared in the app. Instagram sharing is not separately verified.
- Safari extension UI and cross-process local import were verified on the physical iPhone. Camera, photo picking, keyboard dictation and microphone transcription still need separate device acceptance. Standard simulator runtime installation remains incomplete; physical-device validation is the current path.

## Live capture intelligence (25 October follow-up)

The local app and Share Extension can now request product-specific note suggestions from an optional private relay. Saves remain local. The relay also retrieves source-cited catalog recommendations from current local save context. It does not connect the full shared-account backend or establish live merchant offers.

- `backend.app.capture_preview:app` exposes authenticated `POST /v1/capture-preview`. It uses the OpenAI Responses API with vision and strict structured output, currently `gpt-4.1-mini`. The capture endpoint uses no private database and does not fetch arbitrary URLs. The separate recommendation endpoint reads an ignored licensed catalog database.
- Provider credentials stay in the server environment or ignored `.env.local` (`OPENAI_API_KEY`). A separate random `MYNAH_PREVIEW_TOKEN` protects the relay. The phone stores only that scoped token and HTTPS origin in shared Keychain; neither credential is included in the app bundle or Git.
- Start locally with `.venv/bin/python scripts/run_capture_preview.py`. It listens on loopback port 8787. Expose only this service through an HTTPS development tunnel or deploy it behind HTTPS. A development tunnel requires the Mac and tunnel process to remain running; it is not a permanent cloud deployment.
- Configure Profile > AI connection & privacy, or install a DEBUG connection with `python3 clients/ios/Scripts/configure-intelligence-device.py DEVICE_UDID HTTPS_ORIGIN`, then launch the app. The helper transfers only the scoped relay connection; the app imports it into Keychain and deletes the transfer file.
- Capture requests debounce briefly, cancel/ignore stale results, and keep the save button available on AI failure. The first selected image is resized for analysis. LinkPresentation can supply a page title, but a blocked/private social post may require a screenshot or caption. Unsupported or unclear content receives no fabricated prompts.
- Selecting a returned prompt toggles an independent intention, preserving the free-text note. Up to eight intentions persist; every change invalidates Explore results. Analysis is versioned and persisted for Library search and customer-facing observations; editing source content invalidates old analysis. Profile can disconnect AI without deleting local finds.
- The failed Open in Mynah action has been removed: Apple does not support opening the host this way from an ordinary Share Extension. Confirmation offers Done and clear manual-switch guidance. iOS owns share-target ordering; pin it under Share > More > Edit > Favorites. No private API or responder-chain workaround is used.

Verification: 33 relay tests passed; live authenticated HTTPS requests returned different watch/lamp prompts, and an actual bundled lamp image produced image-grounded suggestions with unknown brand preserved. A signed physical-iPhone build ran the real capture-analysis path successfully. Local-store checks include analysis persistence and invalidation after source edits. That earlier Open action failed on the device and was replaced in the next revision.

## Real catalog and capture refinement (25 October, later follow-up)

- Installed the signed host and embedded Share Extension on Adi’s physical iPhone. The final Xcode build passed. Existing real saves, original URLs, notes and attachments were preserved; only the four known starter examples disappeared.
- Replaced the local Example ideas / Your finds segments with real catalog retrieval, search, saved-find filters, recommendation details and source-find citations. Catalog facets remain searchable behind the scenes; the interface presents colorful human-readable observations and choices.
- Verified the supplied bundle and indexed 263,787 non-synthetic real/historical records, including 147,702 Amazon Berkeley Objects records. Excluded 20,581 synthetic/fictional records. Data remains ignored and is reproducible with `scripts/prepare_recommendation_bundle.py`; use `--help` for its bundle option.
- Actual saved watch analysis returned grounded optional questions. Real HTTPS retrieval returned actual watches, excluding separate straps; the supplied catalog also supports actual iPhone records. Images retain their source attribution. No current price, availability or checkout is fabricated; Amazon buttons explicitly open a search.
- The detail screen was visibly checked on the physical phone with two selected preferences; the stored JSON confirmed persistence. Explore and an actual watch recommendation detail were also visibly checked after retrieval gates were tightened; source-find citations and the labeled Amazon search action rendered on the phone.
- 80 focused relay, recommendation and catalog-index tests passed. Expanded local-store smoke checks cover migrations, atomic share context import, multiple intentions, manual-title preservation and versioned analysis.
- LinkPresentation contributes bounded title and product-preview metadata where available. Private/blocked social posts may still need a screenshot. Optional AI requests retry one transient failure, respect cancellation and leave local saving usable.
- The mirror’s tap control currently returns `noWindowsAvailable`; the latest share-sheet gesture sequence and voice/camera flows require manual acceptance. Prior Safari-to-local-library handoff was verified. Do not equate compilation or API tests with every device gesture working.
- The HTTPS relay is still a development tunnel running on the Mac, not a permanent cloud deployment. Keep the Mac and tunnel alive for AI and Explore; local saves remain available offline.
