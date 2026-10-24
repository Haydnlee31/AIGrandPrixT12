# iOS shared-library sync handoff

Base: `codex/ios-app` at `89ce907` (catalog integration and Taste Lab included). Review branch: `codex/mynah-ios-shared-sync`. This branch changes the native sync paths only. It does not replace the web deployment, native Radar, local Taste Lab, catalog integrations or shopping-intelligence relay.

## Connect once

1. Build this branch with the existing Xcode project generator and your normal signing configuration. Keep the existing bundle IDs and Keychain Sharing group so installed local data stays available.
2. In Profile, expand **Connect a shared library**. The server defaults to `https://mynah-finds.vercel.app` (no `/v1` or page fragment).
3. Enter the same **Mynah account access key** used by the web app and Chrome extension. Obtain it privately from Chime; never commit it. This is not an OpenAI API key.
4. The client verifies `/v1/me` and stores the credential in Keychain. The server uses its existing PostgreSQL database, catalog and server-side AI.

## Behavior

- Library and Explore use the existing shared API paths. New in-app links and single photos upload immediately; an interrupted request retains its payload and idempotency key.
- The share sheet shows the destination account and offers **Keep only on this iPhone**. A shared save is first durably handed off through Keychain, then attempts an immediate upload. If offline or interrupted, opening Mynah Finds transfers the request to its account-scoped outbox and finishes it automatically. This works with the existing group-free development build as well as provisioned App Groups.
- The foreground app retries pending saves and refreshes its library every 15 seconds. It stops polling in the background. This is not an always-running background service or push sync; other clients refresh according to their own behavior.
- Definite permanent validation failures pause automatic retries and remain visible in Profile. **Sync library** explicitly retries them. A failed upload never blocks reading already-saved finds.
- Existing phone-only finds stay local until **Copy iPhone finds to shared library** is confirmed. The copy includes supported content, notes and chosen intents. Local originals remain intact. A durable account/origin/source-to-server receipt prevents repeated import, including after a remote deletion. Subsequent edits to a local original are not a two-way editing feed.
- Text-only content, arbitrary files, multiple attachments and overlong combined notes are not silently truncated or partially uploaded; they remain local. Local favorites, pinning, archive and Radar state are not part of this shared API contract.
- Images are normalized from the original into an orientation-correct JPEG with a conservative 3 MiB ceiling, or the smaller limit advertised by `/v1/capabilities`. Local originals are unchanged. The share sheet uses the conservative fallback when preparing an offline capture.
- New share drafts freeze their destination account/origin. Sign-out clears the active share destination and credentials; pending requests remain scoped to their original account. Reconnecting a different account does not replay them there.

## Validation

- `swift test --package-path clients/ios`: 17 passing tests. Seven new tests cover network-loss replay across restart, import deduplication and receipt retention, account/origin isolation, permanent rejection/manual retry, unauthorized preservation, legacy queue decoding, unsupported content and bounded image preparation.
- Read-only native Swift check against production: `/v1/me`, capabilities (3,145,728-byte image limit), one existing shared save and 20 Explore recommendations decoded successfully. No production writes.
- `sh clients/ios/Scripts/local_library_smoke.sh`: existing local persistence, attachments, notes/intents, grouping, edits and replay checks pass.
- `COMMONTHREAD_PYTHON=<existing-venv>/bin/python sh clients/ios/Scripts/native_http_smoke.sh`: native SDK against a temporary migrated backend passes two-account capture, same-key replay, read, duplicate, isolation and deletion checks.
- `MYMAH_DERIVED_DATA=<isolated-folder> sh clients/ios/Scripts/build-simulator.sh`: builds the app and embedded Share Extension. The generated project also adds references for files already present in the base branch (live pricing and photo selection).

Before merging, Haydn/Adi should verify physical-device signing and a real Safari/Instagram share: connect the demo account, share a link/photo, confirm it appears on the web and Chrome, interrupt connectivity, share again, reopen the app, then confirm only one server save. Also test sign-out and account switching with a pending share. No production saves or physical phone installs were performed for these checks.

## Profiles and authentication next

Keep one API and database. Add authentication in a separate shared-backend PR, then small client PRs; do not build three user databases.

A practical candidate is Clerk with one application for web, iOS and Chrome. Its [iOS SDK](https://clerk.com/docs/ios/getting-started/quickstart) supports hosted/native authentication, and its [Chrome SDK](https://clerk.com/docs/reference/chrome-extension/overview) supports a web Sync Host. The current side-panel integration requires closing/reopening the panel after web sign-in; account for this in the UX instead of promising seamless refresh. For a minimal first version, email one-time codes avoid a custom password system. Add Apple/Google sign-in with the corresponding provider setup.

Implementation sequence:

1. Add server authentication middleware that validates the provider token's signature, expiry, issuer and intended audience/authorized party. Map the verified stable subject to an internal user ID; never trust an account ID sent by the client. Follow [the provider's token-verification rules](https://clerk.com/docs/guides/sessions/manual-jwt-verification).
2. Add a profile record keyed by that internal ID: display name, optional avatar, region/currency and explicit shopping preferences. Keep login/session credentials in the auth provider, not in the profile table.
3. Apply account ownership to saves, media, annotations, intents, recommendations, watches and background jobs. Add integration tests proving user A cannot read, update, delete or receive recommendations citing user B's private data. Catalog records may remain public/shared; personal ranking and reasons must be scoped.
4. Replace the manual demo-key form with provider sign-in and refreshed short-lived tokens. Reuse the SDK's async token-provider seam. Keychain handles native credentials; extension code uses its SDK/session flow. Clear account-bound UI/media caches on logout and retain or explicitly discard pending saves only for their original account.
5. Explicitly assign or import the existing demo library to its intended owner/team. Do not copy the demo account into every new user. If the team wants a shared workspace, model membership separately from personal profiles.
6. Disable the old shared demo key after the migration has been verified. Add account deletion/export and per-user AI quotas before a wider release.

Authentication is a separate follow-up. This PR retains the current provisioned-key demo contract and does not create an auth-provider account or deploy a user migration.
