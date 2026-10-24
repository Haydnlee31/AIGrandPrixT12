# iOS email login review

This draft adds email-code sign-in to Profile, managed session storage in the existing Keychain access group, and short-lived JWT refresh shared by app and Share Extension. Server identity is verified before connecting. Local-only saves are not silently uploaded.

It is stacked on `codex/mynah-ios-shared-sync`, with iOS source through `1fcda93`. Adi subsequently merged and reverted that shared-sync foundation (`5eab5d5`, then `b110375`). Do not merge this draft into the active iOS branch until the reason for the revert is resolved. This branch does not restore changes to the team's branch or replace its newer local-library recovery work.

The backend must deploy `codex/mynah-auth-web` first. Use the same backend URL and email as the web app. No Neon or OpenAI secret belongs in the app. The backend administrator links the verified existing owner's Neon UUID to the demo library; other users receive isolated libraries.

Neon's session cookie is named `__Secure-neon-auth.session_token`. Both native parsing and backend forwarding use that provider name. A regression test uses a provider fixture independent of the backend constant, preventing successful-code/absent-cookie regressions.

Validation: 20 Swift tests pass; app and embedded Share Extension simulator build passed before the cookie-name-only correction. Real Neon email-code login and library API verification passed in the web preview. Native login, Keychain persistence across restart, signed-device Share Sheet, offline outbox recovery, account switching and multi-client updates still require physical-device acceptance before merge.

Detailed rollout and acceptance sequence: `docs/neon-login-handoff.md` on `codex/mynah-auth-web`. Existing local preferences and native Radar/Taste Lab remain separate from the shared library contract.
