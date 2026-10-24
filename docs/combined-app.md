# Combined Mymah Finds app

This integrates `main@08144c8`, the Chrome side panel, and the deployed web/email
login contracts. The native app, Chrome extension and web Library use the same
authenticated service. Existing local iPhone records stay local until the user
explicitly chooses a shared destination.

## Run locally

Configure the ignored `.env` using `.env.example`, with `ASTRA_API_KEY` or
`OPENAI_API_KEY`. Run `make run`. The launcher loads known backend settings,
applies migrations and serves the combined app at `http://127.0.0.1:8000`.
Multimodal processing is on by default in this launcher. No provider key goes to
the phone, extension or web page. `EMBEDDED_WORKER=true` runs the durable worker
alongside the local API; a separately managed worker needs the same environment.

The unified origin serves shared Library APIs and the existing native preview,
intent, recommendation, Taste Lab and Radar routes. All accept the same verified
account. Native service state is account-scoped. Missing keys fail startup rather
than claiming that AI works.

## Install the clients

Run `make extension`, then load `dist/chrome-extension` through Chrome's
Extensions → Developer mode → Load unpacked. The default package is the complete
side panel, not the older popup. `dist/mymah-finds-chrome-extension.zip` contains
the same extension. Click its toolbar icon, open Profile and sign in through the
web app. The default hosted origin is `https://mynah-finds.vercel.app`.
An explicit development connection is available for isolated local testing.

Build the iPhone app with `sh clients/ios/Scripts/build-simulator.sh` or open the
generated Xcode project. Full Xcode and device signing remain prerequisites for
installation on a real iPhone. Profile email-code sign-in connects intelligence;
the user explicitly chooses whether to view the shared Library. Existing local
files are not silently migrated or hidden.

## Connected experience

- Save text, photos and a recorded voice note. iOS records AAC M4A; Chrome records
  PCM WAV. The API accepts up to four photos and one recording of at most 60 seconds.
- Voice is transcribed, then analyzed with the photos and written context. Chrome
  requires transcript review before shared publication. The iOS capture flow
  allows transcript review and correction before Save.
- Structured product observations and contextual predictive prompts appear in
  the saved find. Unknown brand/specification information remains unknown.
- Shared publication makes observations and reviewed voice searchable in the
  backend Library and available to the existing cited Explore recommender.
- Local iPhone analysis updates its local find and local recommendation inputs.
  Local and shared destinations remain distinct and visible to the user.
- Upload checkpoints and mutation keys persist across interruption. iOS shared
  uploads retain a local copy; Chrome retains account-scoped IndexedDB records.
  Queued work cannot move to another account merely because someone signs in.
- Sign-in refreshes managed tokens, and deletion removes associated server
  media/analysis. Prompt selection records intent; it does not purchase items,
  schedule notifications or claim live Amazon prices.

The web save form also uses the multimodal pipeline when enabled, retaining its
single-photo UI and durable resume. The richer multi-photo/recording controls
are in the native app and Chrome extension.

## Deploy the existing Vercel service

Target: `mynah-finds` in the Vercel team `4achime-4427s-projects`.
Existing app account access keys authenticate Library requests; they do not grant
Vercel deployment access. The repository is not automatically connected to Vercel.

Use the combined branch with the existing Vercel project and preserve its
`DATABASE_URL`, `NEON_AUTH_URL`, `NEON_ACCOUNT_LINKS`, account keys, login-origin
settings and `CRON_SECRET`. Set `MULTIMODAL_ENABLED=true`,
`ASTRA_MODEL=gpt-6-astra`, and `MULTIMODAL_TRANSCRIPTION_MODEL=gpt-transcribe`.
Keep inference keys in Vercel secrets. The worker and API use these same settings.

`app.py` uses the unified service, disables embedded worker threads and dispatches
durable jobs through Vercel Queues. Transcription dispatches its subsequent
analysis job after committing. Pending work survives delivery failures and is
recovered by subsequent authenticated requests and the recovery cron.

The build hook applies production migrations under a PostgreSQL advisory lock
and verifies the final revision. Failed migration stops the build. Preview builds
only verify schema and refuse to mutate a shared database: prepare an isolated
preview database at the current revision before using previews. Never substitute
ephemeral SQLite for the hosted database. The additive migration retains legacy
image rows for rollback compatibility.

With a Vercel CLI session authorized for that project, deploy using:

```sh
npx vercel deploy --prod --skip-domain --scope 4achime-4427s-projects
# Validate the returned deployment URL before assigning the live domain:
npx vercel promote <deployment-url> --scope 4achime-4427s-projects
```

Verify the linked project is `mynah-finds` before accepting the deployment. The
source excludes environment files, local databases, downloaded catalogs and
validation artifacts. Vercel advertises a 3 MiB asset limit to remain within its
HTTP payload limit; clients read capabilities before uploading. Hosted price
monitoring is unavailable rather than storing watches in ephemeral function disk.

## Validation and remaining acceptance

The [release verification record](validation/combined-release-2026-10-25.json)
links the hosted, installed Chrome and iPhone simulator results. The full native
workflow is [run 40143362288](https://github.com/Haydnlee31/AIGrandPrixT12/actions/runs/40143362288).
The final web packaging correction does not change the tested backend or Swift sources.

Run `make test`, `make smoke-http`, `make smoke-swift`,
`make smoke-multimodal-swift`, and the native multimodal/shared-outbox scripts.
The GitHub `Combined app validation` workflow performs a full app + Share
Extension build, Swift SDK tests and an ordinary iPhone simulator install/launch.
The Chrome HTTP/browser journey scripts exercise the actual extension controller
and installed extension against isolated databases and synthetic media.

The final verification record distinguishes deterministic tests, live provider
calls, actual browser checks, simulator checks and hosted deployment checks.
`scripts/validate_hosted_multimodal.py` exercises a disposable synthetic capture
on an explicit HTTPS origin, with credentials read from a private file. It checks
two-image/voice understanding, correction, publication, search, native decoding
and cleanup. It never requests the full existing Library or generates
recommendations from other saved content. Use a quiet test account when possible.
Do not equate an app API credential or local test pass with production promotion.
Physical microphone interruptions and a real Share Sheet gesture still need a
signed iPhone acceptance pass after deployment.
