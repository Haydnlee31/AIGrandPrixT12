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

The host requests microphone permission only when starting a voice note. Host dictation now records a short AAC clip and sends it through the authenticated OpenAI relay; it does not use on-device speech recognition. Debug plists permit local networking for simulator development. Release plists retain standard App Transport Security; no arbitrary-load bypass is enabled. The SDK restricts insecure HTTP to loopback origins; use HTTPS for a remote server or physical iPhone.

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

Confirmed saves are queued in bounded Keychain entries, encrypted with `AfterFirstUnlockThisDeviceOnly`, with synchronization disabled. A manifest is committed after the payload chunks. Only after that durable save succeeds, the extension briefly shows **Saved!** and completes its request, returning to the original sharing app. **Done** can finish that acknowledgment immediately; there is no Open Mynah launch attempt. The host imports by stable UUID into its ordinary local file store, then removes the queue entry. Opening or refreshing the local library completes the import. This inbox is a development handoff, not permanent media storage; a normally provisioned build can use an App Group folder instead. Reinstallation should not be treated as a way to erase pending Keychain data.

Apple prohibits direct microphone access in ordinary Share Extensions. The extension's editable note supports the system keyboard's dictation when the keyboard offers it; this is system dictation, not OpenAI transcription. Direct recording and OpenAI dictation belong in the host app. See [Apple's extension restrictions](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html). Camera and microphone permissions are requested by the host when those features are used.

## Local frontend and optional connection

The app starts with an empty on-device library. Upgrades remove only the four exact original starter records; real saves and attachments remain intact. Capture links, photos, camera images, text, or files, with an optional title and typed/voice note. Local saves, search, editing and deletion work without a server or database. Local saves and attachments are persisted in Application Support. The Library uses actual saved images and bounded LinkPresentation website previews; unavailable previews use a compact symbol fallback. Website metadata never replaces a custom saved title.

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
- Selecting a returned prompt keeps an independent intention and can open one skippable follow-up through `POST /v1/refine-intent`, preserving earlier answers and the free-text note. Kept choices become compact editable chips; further refinement requires another deliberate tap. Up to eight intentions persist; every change invalidates Explore results. Analysis is versioned and persisted for Library search and customer-facing observations; editing source content invalidates old analysis. Profile can disconnect AI without deleting local finds.
- The earlier share revision offered **Done** and an optional **Open Mynah** attempt. That launch flow has been removed: the current extension acknowledges a durable local save, then completes back to the original app. iOS owns share-target ordering; pin it under Share > More > Edit > Favorites. No private API or responder-chain workaround is used.

Historical verification for that revision: 33 relay tests passed; live authenticated HTTPS requests returned different watch/lamp prompts, and an actual bundled lamp image produced image-grounded suggestions with unknown brand preserved. A signed physical-iPhone build ran the real capture-analysis path successfully. Local-store checks include analysis persistence and invalidation after source edits. The earlier Open action failed on the device; it is no longer part of the current flow.

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

## Minimal Library and progressive refinement (previous validated revision)

- Library cards show the image, saved title and source. Pin/unpin lives in the find menu; pins persist across relaunch and archive/restore. Advanced filters and settings stay in menus/Profile.
- Website preview requests are coalesced per URL, limited to three concurrent fetches, downsampled and cached on the device with memory/disk bounds. Unavailable sites show a compact fallback, not a fabricated image. Preview metadata does not rename saved finds.
- Explore has a glass **Explore / Your finds** switch (material fallback before iOS 26). The first segment retrieves real catalog records; the second shows the actual local collection. Exact-context recommendation caching reuses recent results, cancels obsolete requests and clears stale cards when source context changes. Available catalog results render before optional additional model analysis.
- Capture, sharing and saved details offer one optional, product-grounded refinement question after a selected detail. Prior answers remain visible as compact chips, and saving another answer updates Explore. Stable saved-find identity keeps refinement/editing sheets open across metadata refreshes.
- The integrated signed iPhone build passed and was installed on Adi’s physical iPhone. Device screenshots verified the minimal Library with real website images, both glass segments, actual saved cards and an OpenAI-generated refinement question with three choices. The final install and view-only checks preserved all five current finds and their complete stored data. DEBUG-only `-showYourFinds` and `-showRefinement` routes allow repeatable screen checks without selecting or changing preferences.
- Local-store checks passed, including pin persistence/archive/legacy-data decoding. Live HTTPS refinement returned in 2.28 seconds; recommendations returned 24 real watch/phone records in 2.01 seconds, then 0.15 seconds on a cached request. These are observed development-tunnel timings, not latency guarantees.
- All 104 focused capture, recommendation and catalog-index tests passed. Matching distinguishes strap, dial and stitching evidence; the current catalog has no leather-strap watch, so alternatives never claim a leather/stitching match. Source edits replace running analysis safely, while pin/detail changes preserve it; stale results cannot overwrite an edited find.
- At that revision, remote tap control returned `noWindowsAvailable`; screenshots, API checks and storage tests did not prove the Share → Save → Open Mynah gesture. The current revision removes the Open Mynah action in favor of returning to the source app after saving. The Mac and development tunnel must stay running for AI and catalog retrieval.

## New Insights, share completion and OpenAI dictation (current revision)

- Saved finds use one **New Insights** section for grounded observations, selected details and optional personalization. The photo preview shows one compact question that leads into this section; the complete response choices do not cover the image. Larger accessibility text moves the question below the preview.
- A first share starts analysis without the earlier debounce. A supplied photo or useful product caption goes directly to analysis instead of waiting for unnecessary website metadata. Bare links and generic social captions retain bounded metadata enrichment; slow or blocked pages still need a caption or screenshot. This changes the request path, not a guarantee of a particular API latency.
- **Save find** remains available independently of AI. After the secure inbox finishes its durable write, the Share Extension shows **Saved!** for about 850 ms, then completes and returns to the original app. It neither automatically opens Mynah nor offers the retired Open Mynah action. Save errors remain in the extension so the person can retry.
- Profile's system/light/dark selection is mirrored through `SharedAppearance` in the shared Keychain group. Newly opened share screens use that same choice, including the explicit local-device build without App Groups.
- Host voice notes use a microphone control next to **What caught your eye?**, with recording/transcribing states and editable results. `AVAudioRecorder` records mono AAC at 44.1 kHz/64 kbps for at most 60 seconds. Explicit stop submits; dismissing or canceling discards. The temporary file is removed after stop/cancel, and retry audio stays only in host memory until success or cancellation.
- Authenticated `POST /v1/dictation` accepts `{"audio_data_url":"data:audio/mp4;base64,..."}` and returns `{"text":"..."}`. The relay uses OpenAI `gpt-4o-mini-transcribe` through multipart `/v1/audio/transcriptions`, checks M4A/AAC format and duration metadata, caps decoded audio at 4 MiB, and applies authentication before body parsing. It has a 30-second upstream timeout, at most two concurrent dictations and eight starts per minute. The relay does not log, persist or cache audio or transcripts. Empty transcription returns `no_speech`; failure never substitutes a sample transcript. [OpenAI transcription reference](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create).
- Share-sheet keyboard dictation remains the operating system's feature. The Share Extension does not record audio or call the OpenAI dictation endpoint itself.

Current automated evidence: **142 tests passed** across `test_dictation.py`, `test_capture_preview.py`, `test_local_recommendations.py` and `test_catalog_search_index.py`. The one warning is the existing Starlette/httpx test-client deprecation. Dictation coverage includes auth before parsing, format/body limits, multipart transport, empty/malformed responses, upstream errors, cancellation, rate/concurrency limits and no transcript cache. A real Apple-encoded AAC container also passed local format validation. These automated transport tests mock upstream transcription. A separate authenticated HTTPS call with a synthetic spoken test phrase in a real Apple-encoded AAC file returned HTTP 200 and the exact phrase, “I like the black leather strap and the simple silver dial.”, in 2.1 seconds. That proves real OpenAI transcription through the relay, not the physical microphone gesture. The signed build installed on Adi’s physical iPhone; screenshots verified the actual Apple website preview in light mode and the watch’s New Insights in dark mode. All six current finds remained identical in the stored JSON after installation and view-only checks. The phone mirror still cannot send taps, so microphone permission/recording and automatic return to Safari or Instagram require a manual acceptance check. The Mac and HTTPS development tunnel must remain running for AI.


## First-attempt sharing and presentation repairs (25 October, follow-up)

- The user confirmed that Save returns from the Share Extension to the source app. This is manual device evidence for that completion path.
- A first-share task race was reproduced: a canceled import task could overwrite the current request UUID before checking cancellation, discarding the first valid response. `ShareIntelligenceLifecycle` now guards ownership before any loading/result mutation; rendered input is captured by value and readiness is separate from source identity. `python3 scripts/check_share_lifecycle.py` compiles the production gate and passes 14 focused checks, including the delayed canceled-import schedule. First-attempt physical sharing still needs a fresh uncached URL check after installation.
- The existing authenticated relay and HTTPS tunnel were healthy. A fresh caption returned three prompts on its first request in 2.294 seconds; cached repeats were faster. The relay intentionally finishes and caches paid in-flight analysis even if a client disconnects; warming it up is not a solution for UI task cancellation.
- Question overlays are swipeable cards with page dots again. Explore's local-collection segment is named Insights. Profile exposes System/Light/Dark directly, and appearance updates existing tab/sheet chrome without resetting navigation. DEBUG appearance launch arguments are consumed once, so they cannot lock the control for the remainder of that process.
- Spoken-note recording now uses default voice input processing and the phone's built-in microphone, displays an input meter, and offers a Settings link after denied microphone access. The previous -55 dB prefilter could reject quiet usable audio; only near-muted input and too-short recordings are rejected locally now. DEBUG builds write one bounded hardware-state diagnostic in Caches, containing permission/route type/level/status and numeric error codes, never audio, transcript, user content, URL or credentials. Physical recording/transcription needs a fresh direct-on-phone check.

- Catalog photos use a bounded, coalesced HTTPS loader with transient retry, per-view ownership protection, MIME/size checks, and decoded-size bounds. All nine source photos in the then-current recommendations returned JPEG and decoded through the actual Swift loader; photos were also visibly rendered on the physical iPhone. Records with no source image are explicitly labeled; no substitute product photo is fabricated. Photo-bearing results are ordered first only after relevance selection.
- Library adds All, Images, Links, Voice, Files, and Text format filters alongside search/favorites/source controls. Voice includes audio attachments and explicitly dictated notes. The optional `hasVoiceNote` field is backward compatible; capture, edit and intent writes persist it atomically and later ordinary edits preserve it. Old notes are not guessed to be voice notes.
- Intent Radar is a fourth native tab in the existing app style. Suggestions come from actual recent saves and confirmed notes. Selecting one opens an editable interpretation; only the explicit Save need action creates a watch. Product, brand, category and need scopes store a target, conditions and a frequency preference. Check now queries real catalog matches; editing sources, pausing/resuming and removing watches work locally. The interface explains that background checks/alerts are not connected and that unavailable live prices or comparable quality evidence cannot determine the ordering. Supporting citations link back to actual saved links, photos or notes.
- Radar persists `intent-radar.json` separately from Library. `sh clients/ios/Scripts/radar_store_smoke.sh` checks save/reopen/edit/pause/resume/delete, invalid/corrupt input, and stale checks after a watch changes. `sh clients/ios/Scripts/catalog_image_smoke.sh` covers cache/coalescing/retry and transport boundaries. The expanded local-library smoke covers voice provenance and audio format detection.
- Integrated signed iPhone build passed. Device screenshots verified Radar, format filters, question carousel dots, Explore/Insights, website previews and catalog photos. All seven current saves remained identical after installation and view-only inspection. Physical microphone transcription, first-share suggestions and the live appearance toggle were requested as manual acceptance checks; these are not proven merely by a build or screenshot.


### Device acceptance and final follow-up

- Aditya confirmed that a newly shared link now shows suggestions on its first opening. The automatic return to the originating app was also confirmed earlier.
- The physical iPhone microphone still failed. At Aditya's explicit request the custom in-app recording controls have been removed; typed notes and system keyboard dictation remain. The prior relay transcription fixture is not evidence of a working physical microphone.
- Profile's appearance change still did not update the visible app even though the physical device persisted `finds.appearance=light`. The final follow-up replaces separate preference observers with a shared appearance state. Device acceptance of that replacement remains pending.
- Smartphone/iPhone intent now excludes landline, DECT, cordless and answering-machine products before ranking. The recommendation/index suite passed 57 checks. After the relay restart, a real authenticated request using the seven-save snapshot returned 24 records, eight with genuine catalog photos, and zero incorrect home-phone records. Missing catalog photos remain unavailable rather than fabricated.

- Final appearance implementation uses one root-owned observable selection for Profile, SwiftUI and UIKit. Its focused state checks cover Light/Dark/System changes, observation, persisted reopen, launch-override initialization and application callbacks. This replaces the earlier argument-domain workaround.
- Removed native `VoiceNoteRecorder`, `VoiceDictationStatus` and `OpenAIDictation`, all recorder buttons, related onboarding/privacy claims and `NSMicrophoneUsageDescription` from generated app plists. Audio-file import and legacy voice metadata remain compatible. No custom app microphone is requested.

- Final signed iPhone build succeeded after microphone removal and shared appearance replacement; app and Share Extension installed on Adi's connected iPhone 17 Pro. Profile screenshot shows the persisted Light selection and a light interface. The Mac device view still cannot send taps (`noWindowsAvailable`), so Aditya was asked to exercise Dark then Light on the physical phone. This final toggle remains unconfirmed until that response.
- Post-install local Library JSON is identical to its immediate pre-install snapshot; all eight current saves are preserved. The latest microphone usage description is absent from the built app. A credential scan passed across 274 tracked/unignored source and built-bundle paths.
- Saved-photo loading now ignores canceled tasks before clearing active image state, preventing stale task entry from removing a newer photo.

- Final physical-device acceptance: Aditya confirmed **Both modes now switch correctly** when tapping Dark then Light in Profile on the newly installed shared-state build. First-opening share suggestions were also user-confirmed earlier in this revision. These confirmations supersede the pending appearance/share checks above; custom recording remains intentionally removed.


### Radar simplification and inline merged insights

- Fixed a deterministic failure: a custom Radar intention created no source IDs, while the old native path rejected empty source selections before making any request. The new intent endpoint works with or without selected saves; conversational needs are not hard all-word catalog filters.
- Replaced the long review form with an intention and budget slider. Removed optional search terms, small-space template settings, saved-example controls and the separate Insights list. Show matches opens photo results with standard Back navigation, and parent/editor focus is cleared before presentation transitions.
- Product insight reducer checks pass for deduplication, complete stored summaries, retained uncertainty/conflicts, caption echo removal and no invented empty-input facts. Local store checks pass, including the copied real eight-save library rendering as six exact groups while originals remain byte-identical.
- The first signed build passed. Final installed-build and manual navigation evidence follows below when complete.

- Final signed Xcode build passed (`/tmp/mynah-radar-merged-build.log`), then app and Share Extension installed on Adi's physical iPhone. Device screenshots show grouped product cards, inline insight previews, the two-save badge and actual Library/Explore photos. Raw local Library remains byte-equivalent after installation: all eight originals retained behind six displayed groups.
- Final backend verification: 150 tests pass across Radar, capture-preview, catalog retrieval/search, official photo recovery and integration. Native Radar matching smoke covers source aliases, deleted-source fallback, exact target propagation, retired-control removal and cache/retry behavior; local-store and insight reducer suites pass.
- Live authenticated HTTPS `POST /v1/radar` with no saved examples returned 12 real silver-retro-watch matches with 12 photos in 2.53 seconds. After final relay restart, the actual saved Apple Watch context returned eight relevant matches with six official OPF photos recovered in 3.21 seconds. Photo lookup is bounded to 12 records, four workers and three seconds; it never substitutes another product or invents images/prices. Records without genuine images remain labeled unavailable.
- Profile Light/Dark and first-share suggestion acceptance from the prior revision remain confirmed. Final Radar slider → photo results → Back/keyboard interaction was requested on the physical device; no automated tap claim is made because the phone review tool cannot tap.
- Credential scan passed on tracked/unignored sources and the signed app bundle. The scoped relay connection remains private; no provider key is embedded in the app.

- Final physical-device acceptance: Aditya confirmed **Yes, results and navigation work** after entering “silver retro watch,” adjusting the budget slider and opening Show matches. Photo results, dismissed keyboard and normal Back navigation are now user-verified on the installed build.
