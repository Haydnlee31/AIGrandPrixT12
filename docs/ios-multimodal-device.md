# Local iPhone multimodal integration

The native capture sheet and Share Extension use the additive multimodal SDK when
an independent analysis connection is configured. This does not connect the
Library to the shared account or publish any saved content. Existing Library,
Explore, Radar, Taste Lab, highlighting, appearance and price services remain.

Up to four photos and one imported M4A/WAV recording can accompany the link,
text and typed note. Existing local support for other attachments is retained;
unsupported audio or excess photos produces an analysis message, not silent
partial analysis. No custom microphone was reintroduced. The existing keyboard
dictation can still supply the editable note.

The analysis account is separate from the preview-relay credential and from the
Library destination. Scoped tokens live in Keychain; OpenAI keys remain on the
server. The configuration transfer is deleted after import. Updating the legacy
relay connection in Profile preserves the separate analysis connection.

`scripts/run_multimodal_device.py` loads inference settings explicitly, runs
`alembic upgrade head` against the dedicated analysis database, sets
`MULTIMODAL_ENABLED=true` for the API and embedded worker, and listens on 8788.
It reads an ignored `.env.multimodal-device` JSON file with `database_url`,
`access_token`, `account_id` and optional `model`. The existing 8787 relay is
unchanged. This development arrangement needs the Mac and both tunnels running;
it does not enable or migrate a production Vercel deployment.

The device configuration helper accepts an optional third argument containing
the analysis HTTPS origin. It transfers that account's scoped token alongside
the existing preview service configuration. No credentials belong in Git.

Temporary server drafts are never published. Cleanup runs after success,
failure or cancellation, with bounded retries. If connectivity prevents cleanup,
temporary drafts can remain on the server; this is disclosed in Profile.
Saving locally never waits for AI. Missing analysis can be retried from the
saved-item/Explore flow. Changed notes and image sets invalidate stale results.

## Validation on 25 October 2026

- 883 backend tests, 54 JavaScript tests, the Swift suite, multimodal SDK smoke,
  generated contracts and signed physical-device build passed.
- Adi's physical iPhone submitted two existing watch photos plus a comparison
  note through the new service. Astra returned three specific questions about
  dial markers and strap stitching; the app decoded them and rendered its
  photo overlay. This was an unsaved draft, not a cloud-library migration.
- The server completed that capture and deleted its temporary image assets.
- All 11 original local records remained identical and all three original
  photo files remained byte-identical. The current library also contains one
  newer save, for 12 total.
- No new physical audio-import/transcription or Share Extension gesture test
  is claimed. The SDK/backend audio paths are covered by branch tests; the
  signed Share Extension compiles with the same analysis implementation.
