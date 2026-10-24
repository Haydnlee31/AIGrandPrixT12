# Mynah email login and automatic sync

Status: real email-code sign-in and authenticated API access passed in the local preview; production and cross-client acceptance remain pending. Do not describe this as live until the acceptance checks below pass.

## Shared identity

All three clients use the same Mynah backend URL. Neon manages email codes and persistent sessions; the backend verifies short-lived EdDSA JWTs with the exact Neon Auth issuer, audience, expiry and verified-email claim. Saves, images, events and recommendations remain in the existing database. Clients never choose their own server-side user ID. OpenAI credentials remain server-only.

The browser uses a host-only, Secure, HttpOnly session cookie through the narrow `/v1/auth/session/` transport. The exact managed-provider cookie name is `__Secure-neon-auth.session_token`. iOS keeps this session in Keychain. Chrome uses the web session with explicit host permission; its storage contains connection metadata, not the session or JWT.

## Configuration and rollout

1. Enable managed Neon Auth with email verification and email codes. Add the production web origin to trusted domains. The shared Neon email sender is for the hackathon; configure production email delivery before a public launch.
2. Set `NEON_AUTH_URL` to the exact branch Auth URL and `AUTH_WEB_ORIGIN` to the canonical web origin. Keep `CORS_ORIGINS` restricted to exact approved origins, including the installed Chrome extension origin. No wildcard credentialed CORS.
3. Have the owner sign in and verify their Neon user UUID. Set `NEON_ACCOUNT_LINKS` to a JSON mapping from that verified UUID to the existing demo library ID. Do not map by client-supplied email, and never automatically grant the first signup the demo library. New accounts otherwise get `neon:<UUID>` and an empty private library.
4. Preserve existing `API_TOKENS` during migration so current iOS/Chrome builds continue working. No database rewrite is required. Retire legacy keys only after every client is migrated.
5. Deploy the backend/web change, then update Chrome and review/build the separate iOS auth branch. Sign in with the same email on each device. Existing iPhone-only saves still require the explicit copy-to-shared-library action; sign-in does not silently upload them.

## Sync behavior

Web and Chrome check a small account revision every 15 seconds while visible and refresh when it changes. Focus/network return triggers another check. iOS retains its foreground refresh and account-scoped outbox from the shared-sync branch. Server enrichment completion advances the revision, so finished AI results appear without a manual refresh.

Submitted web captures and Chrome uploads retain the original idempotency key and payload for retry after connection failure. Account switches never replay them into another library. Permanent validation errors need correction; deletes and all other operations are not promised to work offline. This is foreground polling, not background push or a guarantee that a suspended iPhone updates immediately.

## Review branches

- `codex/mynah-auth-web` builds on `codex/mynah-web-app`.
- `codex/mynah-auth-extension` builds on `codex/mynah-extension-intelligence`, including the latest 0.4.1 prompt fixes.
- `codex/mynah-auth-ios` builds on `codex/mynah-ios-shared-sync`, with iOS source through `1fcda93` merged into the isolated branch.

PR #7 was merged and then reverted by Adi (`b110375`). The iOS auth draft depends on that earlier shared-sync foundation and must not be merged into the active iOS branch until the team resolves that revert. No reverted changes have been restored to their branch.

Merge the backend before relying on email login in either client. These branches do not update teammates' working branches.

## Acceptance checks before declaring rollout complete

- Real email code produces a session; reload and reopen retain it. Verify actual JWT claims against the API, not only mocks.
- Link the verified owner's account to the demo library and confirm the kept lamp find remains visible.
- Save in one client and see it plus completed recommendations in the other clients while open, without a manual refresh.
- Sign into a second account and confirm no first-account saves/images/recommendations are accessible.
- Confirm Chrome can use the web cookie with the installed extension ID and that disconnect/sign-out clears private UI.
- Test iOS sign-in, Keychain persistence, Share Sheet and offline recovery on a physical device with the appropriate signing capabilities. Simulator builds alone do not establish these behaviors.

## Rollback and remaining scope

Disabling `NEON_AUTH_URL` and redeploying restores legacy-key login. Keep the identity mapping stable once users start saving; changing it makes an account point to a different library. No destructive migration is included. A later release still needs account deletion/export, production email delivery, abuse controls, and shared profile preferences; appearance/layout preferences are currently local to each client.
