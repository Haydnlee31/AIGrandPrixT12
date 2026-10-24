# Native iPhone build

Open `clients/ios/Mymah Finds.xcodeproj` in Xcode and select the **Mymah Finds** scheme. The checked-in project contains the iPhone app, embedded **Save to Mynah Finds** Share Extension, and the local `CommonThreadKit` Swift package. The app targets iOS 18 or later. The reusable SDK retains its iOS 16 minimum.

The visible app name is **Mynah Finds**. The existing `Mymah Finds.xcodeproj` filename and scheme, bundle/App Group/Keychain identifiers, onboarding preference and `MymahFinds` local-library directory remain unchanged for compatibility with ongoing work and existing installs. This branding update does not migrate or reset saved data.

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

Simulator builds use `CODE_SIGNING_ALLOWED=NO`. To run on a physical iPhone, set your team's `DEVELOPMENT_TEAM` and owned identifiers in `project.yml`, regenerate, then verify Signing & Capabilities for both targets. Defaults are `com.aigrandprix.mymahfinds`, extension suffix `.share`, and App Group `group.com.aigrandprix.mymahfinds`; these are build configuration values, not a claim that Apple Developer identifiers have been registered. Both targets must share the App Group and Keychain access group.

The app requests microphone and speech recognition permission only when starting voice capture. Debug plists permit local networking for simulator development. Release plists retain standard App Transport Security; no arbitrary-load bypass is enabled. The SDK restricts insecure HTTP to loopback origins; use HTTPS for a remote server or physical iPhone.

## Local frontend and optional connection

The app starts with an on-device library and four labeled sample finds. Add a public link, optional title and typed/voice note; save, search and delete without any server or database. Local saves are atomically persisted in Application Support. Generated sample imagery is illustrative; provenance is in `clients/ios/ASSETS.md`. Sample content has no merchant links or invented prices.

Profile → Connect a shared library is optional. It switches to the existing backend library and leaves local finds separate; signing out returns to the local library. There is no automatic upload or merge of local saves. The existing Share Extension requires a connected shared account; local-only capture is through the host app.

Enter the backend origin and a team-supplied access token in Profile. Tokens are stored in Keychain, not build settings or source control. Configure the host app before using the Share Extension. Account-scoped pending captures are stored in the shared App Group and preserve their mutation key when retried.

See `platform-ios.md` for the SDK, server contract and device acceptance checks. Its earlier workstation limitations describe the original handoff environment; use current build output for this checkout's validation status.

## Validation on 25 October 2026

- `sh clients/ios/Scripts/build-simulator.sh`: app and embedded Share Extension build succeeded for generic iOS Simulator (arm64 and x86_64).

- `swift test --package-path clients/ios`: 9 SDK tests passed.
- `sh clients/ios/Scripts/local_library_smoke.sh`: samples, durable save/reopen, canonical duplicate preservation, invalid-input atomicity, deletion and empty-library persistence passed without network.
- `sh clients/ios/Scripts/native_http_smoke.sh`: real Swift SDK against isolated FastAPI passed capture/outbox, receipt, replay idempotency, duplicate notes, account isolation and deletion. No deployed database used.
- Native device rendering, microphone transcription, Keychain/App Group sharing and Safari extension UI remain unverified on an ordinary iPhone. The installed iOS 27.1 runtime supports Duo only; the compatible iOS 26.2 download did not complete.
