# Shared backend and iOS integration

Reference iOS build: `a4f2c3792a2c674373308cdca7cd66b79227c99c` (Adi's Radar, sharing and appearance update).
Web branch: `codex/mynah-web-app`. API/SDK contract: `0.4.0`.

## Deployment status

Vercel was selected for the hackathon demo on 2026-10-25. Hobby is the target plan,
subject to its personal, noncommercial-use terms. Vercel sign-in, a hosted database,
catalog import and the server-side AI credential are still pending. No public endpoint
has been created.

The portable long-running-server entrypoint is `python scripts/run_shared.py`. It runs migrations before
starting the existing FastAPI API and web interface on `0.0.0.0:$PORT`.
It requires PostgreSQL and explicit account access keys, and disables demo mutations.
This is a private beta with provisioned account keys, not public signup.

This entrypoint is not a Vercel Function entrypoint. Before deploying on Vercel:

- Export the FastAPI application through a supported Python entrypoint and run
  migrations as a deployment step, not on every function invocation.
- Disable the embedded infinite worker. Adapt the durable job queue to bounded
  invocations with a reliable retry trigger; saving a record must not depend on
  a background thread surviving the request.
- Keep both clients on the same authenticated API and hosted PostgreSQL database.
  A free database plan has its own storage and compute limits; measure the imported
  catalog and image storage before promising that the complete dataset fits.
- Handle Vercel's 4.5 MB request/response payload limit. The current API's 4 MiB
  decoded image allowance can exceed that once base64-encoded. Compress photos
  before upload or add authenticated direct object-storage uploads on both clients.

[Vercel Hobby limits](https://vercel.com/docs/plans/hobby) currently include
1 million function invocations, 4 active CPU-hours, 360 GB-hours of provisioned
memory, 100 GB of fast data transfer and 10 GB of origin transfer per month.
The first exhausted allowance can interrupt service. These are hosting quotas,
not free AI model calls or a database allocation.
[Function limits](https://vercel.com/docs/functions/limitations) include a maximum
300-second duration on Hobby with Fluid compute and the payload limit above.
Prices and limits were checked on 2026-10-25; verify them again before deployment.

Required environment for the portable server (Vercel-specific configuration is pending):

- `DATABASE_URL`: hosted PostgreSQL connection string. Both migrations and the API use psycopg 3.
- `API_TOKENS`: JSON mapping random access keys to account IDs; alternatively
  `MYNAH_ACCOUNT_TOKEN` with `MYNAH_ACCOUNT_ID` for one initial account.
  Generate at least 32 random bytes. Keep values in the hosting secret store, never Git or chat.
- `PORT`: supplied by the host, defaults to `10000`.
- `ANNOTATION_PROVIDER`: `astra` requires an OpenAI/Astra key; `auto` permits saving
  without AI when no key is configured. Missing analysis is exposed through capabilities.
- `OPENAI_API_KEY` or `ASTRA_API_KEY`, and `ASTRA_MODEL`: server-side only.
  The shared provider defaults to `gpt-6-astra`; the local iOS relay uses a separate
  provider/prompt configuration. Changing the hosting URL does not make those equivalent.
- `EXPLORE_CATALOG_SOURCE`: the imported shared catalog source, for example `abo`.
- `EMBEDDED_WORKER=true` runs the existing leased-job worker in the single API service.

The current licensed catalog bundle and live AI credential are not available in this
checkout or its process environment.
Do not claim live recommendations until both have been configured and tested.
Haydn can run `make catalog-bundle` on the machine that holds the reviewed datasets.
Transfer the resulting data-only bundle separately; the existing
`scripts/import_catalog_bundle.py` verifies hashes/counts before importing it with
`DATABASE_URL` set to the shared database. Keep source notices and attribution.
Do not copy an iPhone library, a private database, credentials or synthetic test products into that bundle.

## What is already in Adi's build

`CommonThreadApp.swift` already has an authenticated shared-account connection path.
It verifies `/v1/me` and capabilities, stores the origin/account in `SharedEnvironment`,
stores the token in Keychain, and loads the shared collection. The Swift SDK already
supports captures, idempotent retries, shared Library search, private images and Explore.
`CaptureForm` can use this connection for supported captures.

Connecting this mode does **not** import `LocalLibrary` or `LocalShareInbox`.
The optional capture-intelligence relay and `POST /v1/recommendations` currently work
from local context. They do not synchronize Library records. Radar also persists locally.

## Haydn's changes

1. Configure the deployed **origin** and the same account access key used on web.
   Preserve `SharedEnvironment` and its `verify` check; use `/v1/me`'s `user_id`,
   never a hardcoded client identity. Different people receive different account keys.
   Never put the OpenAI key or account key in an app bundle or URL.
2. Keep connected Library backed by `collection()`, `searchLibrary()` and
   `savedItem()`. Paginate until `nextOffset` is absent. Refresh on foreground and
   after mutations; this contract does not provide realtime or incremental sync.
3. Use `CaptureOutbox` for connected host and Share Extension saves. Persist the
   payload and `MutationKey` before sending `capture(_:key:)`; retain both after
   timeouts and retry with the same key. Scope the outbox to origin and account.
   Check App Group/Keychain entitlements for both targets. A group-free local build
   must explicitly transfer inbox entries to the host outbox; it cannot assume a shared directory.
4. Add an explicit import of existing local finds. Record a durable mapping from
   local find ID to backend ID separately for each account/origin. Preserve local
   originals until the server receipt is verified, and make retries safe. The current
   capture API accepts URL or one JPEG/PNG/WebP image (4 MiB decoded, 6 MiB request),
   not arbitrary files, audio/video, text-only finds or multi-attachment records.
   Leave unsupported items local and explain which were not imported. Do not drop them.
   URL/image deduplication can return an existing item without merging notes; surface
   that conflict rather than claiming every local field was imported.
5. In connected Explore, use `CommonThreadClient.explore()` (`GET /v1/explore`),
   the same endpoint as web. Render saved-find evidence and catalog citations from
   that response. Refresh after captures, selected/edited/rejected annotations and
   deletion. Do not continue using local `POST /v1/recommendations` and describe it
   as the shared account's feed: its request and ranking engine are different.
6. Use server analysis and suggestions for connected records. Follow
   `analysis_status`, `analyzeSave(_:key:)` and `respond(to:with:key:)`.
   A pending or failed analysis must not turn a successful save into a failed save.
   Existing local preview analysis/chosen chips are not accepted as trusted server
   analysis by this capture contract. Preserve them locally; import user-approved
   context as notes/annotation edits with appropriate length checks.
7. Use `savedImage()` with authorization and `deleteSavedItem(_:key:)` for shared
   records. Clear account-specific images, cached recommendations and pending UI
   state on sign-out/account change; cancel stale responses.

Radar's `intent-radar.json`, pins, favorites, archives and local attachment metadata
are not synchronized by contract 0.4.0. The existing shared price-watch endpoint is
not a compatible replacement for native product/brand/category/need Radar watches.
Keep this boundary visible until a reviewed shared Radar contract is implemented.
There is no live price monitor or notification delivery in this deployment.

## Acceptance before calling it synchronized

- Save a real link/image on web and see the same backend ID in iOS after refresh.
- Save from the host and from the Share Extension and see both on web.
- Retry an interrupted capture without creating a duplicate; switch accounts with
  pending entries and verify they never upload into the other account.
- Import the same local library twice without duplicates or lost unsupported files.
- With a configured provider and licensed catalog, verify real recommendations on
  both clients from the same saved context, including the cited saved IDs.
- Delete a find on either client; verify it disappears and stops supporting recommendations.
- Restart/redeploy the service and verify saves/images remain. Check a second account
  cannot list, read, retrieve images from or delete the first account's records.

Physical iPhone/Share Extension acceptance and live AI/catalog validation remain required.
