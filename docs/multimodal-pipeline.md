# Multimodal backend and client handoff

The additive pipeline accepts text, a source link, up to four product photos, and
one recorded voice note. Astra analyzes their combined context. Transcription has
a separate durable job and uses the same server-side OpenAI account.

Existing `/v1/saves`, the native `/v1/capture-preview` relay, local Library storage,
Radar, Taste Lab, intent refinement and Profile keep their existing routes and
behavior. Frontend teammates can adopt the new SDK methods independently. This
change does not implement cloud-library migration or custom microphone controls.

## Server setup and rollback

Run `alembic upgrade head` against the intended server database. The migration
adds two tables and does not rewrite existing saves. Set `MULTIMODAL_ENABLED=true`
in both API and separate worker environments. It defaults to `false`. Supply
`ASTRA_API_KEY` or `OPENAI_API_KEY`. `ASTRA_MODEL` defaults to `gpt-6-astra`;
`MULTIMODAL_TRANSCRIPTION_MODEL` defaults to `gpt-transcribe`.

These settings belong on the backend. Ordinary ASGI entry points read the process
environment; merely creating `.env` does not load it into uvicorn. Use an explicit
environment loader or export settings securely before starting the API/worker.
The live validation command explicitly loads its allowlisted inference settings
from the supplied file and uses an isolated temporary database.

Keep the flag off for existing clients during validation. Disabling it stops new
multimodal work while retaining read/delete access and stored Library records.
New processing jobs stay queued while disabled. Published-save reanalysis requires
the feature to be enabled. Do not drop the asset tables as a rollback.

New routes use the main API's authenticated user mapping, not the native relay's
shared token. A relay connection must not silently become a per-user identity.
Production login and cross-device Library synchronization are separate work.

## API lifecycle

Every mutation requires a retained `Idempotency-Key`. Exact retries replay the
original receipt, which may describe an older revision; GET the current capture
after replay. Reusing a key with different content returns 409. Deletion invalidates
cached receipts so a delayed retry cannot restore removed content.

1. `GET /v1/multimodal/capabilities` reports availability and limits.
2. `POST /v1/multimodal/captures` creates a durable draft with optional `title`,
   `text`, `note`, `url`, and `client`. It does not publish to a Library.
3. POST `/v1/multimodal/captures/{id}/assets` with
   `{revision, media_type, data_base64}` for each attachment. Keep the returned
   revision. Identical normalized attachments are deduplicated.
4. POST `/v1/multimodal/captures/{id}/analyze` with `{revision}`. It acknowledges
   queued work immediately; voice transcription precedes analysis.
5. Poll GET `/v1/multimodal/captures/{id}`. Outer status remains `pending`, `ready`
   or `enrichment_failed`. `stage` adds `draft`, `transcribing`, `analyzing`,
   `ready`, or `failed`. Drafts require an explicit analyze request.
6. Ready `result` contains ProductAnalysis v1 as `analysis`, the existing native
   v2 format as `preview`, and supporting attachment IDs as `source_assets`.
7. Apply the preview to the matching local find, or explicitly POST
   `/v1/multimodal/captures/{id}/publish` with `{revision}` to create a shared save.

PATCH the capture with `{revision, title?, text?, note?}` to edit context. PATCH
`/assets/{asset_id}` with `{revision, transcript}` to correct speech recognition;
the asset then reports `transcript_origin: "user"`. Corrections survive retries
without retranscribing unchanged audio. Edits cancel old jobs, clear stale results,
and advance the revision. Analyze again with that new revision.

DELETE `/assets/{asset_id}` with `{revision}` removes an attachment and invalidates
dependent work. DELETE the capture to erase its media, transcript and analysis.
After publication, captures are frozen; delete through the existing shared save
endpoint to remove the associated evidence and media together.

## Input, storage and processing limits

- Static JPEG/PNG/WebP images, at most 4 MiB each. Orientation is normalized and
  source metadata removed before storage/inference.
- AAC M4A (`audio/mp4`, `audio/m4a`, `audio/x-m4a`) or PCM WAV (`audio/wav`), at
  most 60 seconds and 4 MiB. M4A allows one second of encoder metadata rounding.
  WAV supports 8–48 kHz, one/two channels and 8–32-bit PCM.
- At most four images plus one audio asset; 16 MiB per capture, 128 MiB and 200
  retained captures per user. Remove old captures to release storage.
- Eight new analyses per minute, 100 per rolling day, and two queued jobs per
  user. Published-save reanalysis uses the same allowance. Unchanged idempotent
  retries do not consume additional allowances.
- WebM/MP3, PDF and video interpretation are not accepted by this first pipeline.
  Existing iOS local attachment support remains available.

Media is stored as deferred binary rows, separate from metadata and JSON views.
Metadata, bytes and deletion commit atomically in the existing database. This is
not a signed object-storage service; large-scale object storage needs an adapter
and orphan cleanup. Raw audio remains until capture/save deletion so the original
and reviewed transcript can be inspected. Make this retention visible in the UI.

Each model call has a 40-second maximum deadline within its own 60-second lease.
Transient failures receive at most three job attempts. New revisions, deletion,
lost leases and newer workers prevent stale publication. Errors omit raw provider
bodies, images, audio, notes and keys. PostgreSQL uses the same owner-first lock
order as API mutations; deployment concurrency still needs live verification.

## Understanding and compatibility

Image facts reference the exact asset ID; text evidence must quote its supplied
source. Intent must quote the explicit note/transcript. A request for a leather
strap does not establish that the photographed strap is leather. Unknown identity
stays unknown. Prompts do not become consent or execute actions automatically.

The native projection preserves three or zero `p1`–`p3` prompts, natural preference
questions, `schema_version:2` and a server timestamp. Shared publication preserves
stable intent IDs and annotation-only semantics. Library search indexes product
analysis and explicit transcripts. Explore keeps source/category/identity gates,
citations and unknown-price behavior. Reanalysis of published captures uses all
their images, reviewed transcripts and bounded recent confirmed annotations
(up to 12 evidence entries, prioritized within a 2,000-character note budget).

Semantic embeddings/ranking, realtime conversation, reminder execution, push,
production login and cloud-library migration remain separate changes. The new
pipeline neither supplies live Amazon prices nor relaxes catalog identity checks.

## Frontend handoff

JavaScript and Swift clients expose additive multimodal methods, revision-aware
polling and transcript correction. Preserve upload bodies and mutation keys until
acknowledged. Treat 409 as refresh/deliberate retry, 410 as terminal deletion, and 429
as a rate limit. Publishing is always explicit.

**iOS:** save to LocalLibrary/ShareInbox first. Custom recording should produce AAC
M4A; system keyboard dictation remains available. Before applying results, verify
the find, account, assets and note/transcript revision still match. A Share
Extension must not wait for inference before completing its save.
Use an account-scoped analysis client independently of the selected Library
destination; enabling analysis must not switch the visible local Library.

**Chrome:** add selected-image/user-triggered screenshot capture and a durable
account-scoped upload outbox. Browser audio must produce PCM WAV; default
MediaRecorder WebM is unsupported. Test popup closure, restart, permission denial
and backend/account switches. This branch fixes the main popup scaffold's stale
completion race. The richer `codex/mynah-extension-intelligence` side panel remains
a separate integration target; it has not been merged here.

## Validation

Run `make test`, `make smoke-http`, `make smoke-swift` and
`make smoke-multimodal-swift`. Routine tests remove inference credentials.
New suites cover schemas, grounding, staged jobs, edits/deletion during inference,
lost leases, retries, quotas, transcript correction, ownership, publication,
Library/Explore, reset and preservation of pre-migration data.

`make smoke-multimodal-live` is explicitly billable: at most five analysis
invocations and one transcription, with at most one internal corrective generation
per analysis. It uses synthetic media, `.env` inference settings, a temporary
database and actual Swift decoding. Missing credentials, unsupported models or
provider failures are failures, never a successful no-key fallback.

Before enabling an installed client, validate a signed iPhone build, physical
microphone/interruption handling, Share Extension, offline recovery, and installed
Chrome behavior. Mock HTTP, command-line Swift and live model responses do not
substitute for those device/browser checks.

## Verified implementation, 25 October 2026

Based on `main` at `9b79a97`, the implementation passed 883 backend tests,
54 JavaScript tests, the new Swift multimodal transport/decoding smoke, generated
contract checks, and both JavaScript and Swift real-HTTP journeys against isolated
migrated databases. All 28 prior API paths and 55 prior schemas are unchanged.

The [sanitized live validation record](validation/multimodal-live-2026-10-25.json)
records five successful Astra cases and one transcription request using
`gpt-6-astra` and `gpt-transcribe`. No corrective generation was needed. Cases
covered text-only uncertainty, an image and note, multiple images with an exclusion,
an image plus recorded speech, and a corrected transcript without retranscription.
Individual processing times were approximately 11–19 seconds in this run.
The actual response decoded in Swift and passed publication/search/deletion checks.

These were synthetic fixtures in temporary storage; the existing user Library was
not used or migrated. Full Xcode/simulator/device acceptance, installed-extension
acceptance and live PostgreSQL concurrency remain unverified. The feature remains
off by default and the frontends must explicitly adopt the new SDK/API.
