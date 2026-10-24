# Mymah Finds — combined Chrome app 0.5.0

Library, Explore and Profile use the combined backend. Save a page, screenshot,
selected image, up to four uploaded photos, or a text/voice note. Recorded voice is
encoded as bounded PCM WAV; the provider key stays on the server.

## Run and sign in

Load `experiments/chrome-sidepanel/` unpacked in Chrome, or extract
`dist/mynah-finds-sidepanel.zip`. Keep an existing installation's folder and
extension ID to preserve its IndexedDB saves. The combined packager includes the
shared JavaScript SDK and all side-panel modules.

Profile → Library connection → **Sign in with the web app** opens the configured
server (default `https://mynah-finds.vercel.app`). Use the same account as iPhone.
Grant Chrome access only to that chosen host. The extension reads the web app's
HttpOnly session through the authenticated session endpoint and requests a fresh,
subject-checked token for API requests. Credentials are not stored in IndexedDB.
Advanced development connections can use an account bearer token; never enter an
AI provider key in the extension.

The deployed API must include the combined changes, completed migrations and
`MULTIMODAL_ENABLED=true`, with a working background worker or configured
serverless job dispatch. A URL by itself does not update the deployed server.

## Actual save flow

1. Save a page or screenshot, upload one to four images, or use **Save note**.
   Record up to 60 seconds of optional voice context first; **Stop recording**
   produces a WAV preview. Capture requires an explicit action.
2. The complete original saves locally before network work. When connected, its
   queued upload is bound to that account and server. Create/upload/analyze request
   bodies and mutation keys persist before sending.
3. The backend transcribes voice and analyzes the combined content. Image/text
   saves publish to the shared Library after processing. Voice saves first show
   the transcript and analysis: review or correct it, then choose **Save to shared
   Library**. An edited transcript is reanalyzed without reuploading audio.
4. The shared find shows product characteristics, supporting evidence,
   uncertainties and contextual predictive choices. Choosing a prompt saves
   explicit intent through the existing annotation API. It does not buy products,
   schedule reminders or start price alerts.
5. Library search includes analyzed attributes and reviewed voice. Explore reads
   the same shared saves and displays catalog reasons, evidence links and source
   attribution. Local-only saves do not influence shared recommendations.

Raw voice remains locally and on the server until the associated save is removed.
The local original stays safe if inference fails. **Retry analysis** resumes the
same capture; failed provider work is not presented as successful AI. Closing the
panel during an uploaded analysis is recoverable on reopening. Unsaved active
microphone recording ends when its panel closes.

## Recovery and privacy

- Offline saves made while connected keep their account scope. Reconnecting to a
  different account hides them and never redirects their uploads.
- A saved pending mutation resumes after restart/reconnect. Uncertain requests
  reuse their original key/body; partial uploads do not create duplicate finds.
- Session expiry requires signing in again. Disconnect invalidates managed token
  callbacks. An account change during token issuance is rejected.
- Voice correction is available before publication. Published media stays frozen;
  new annotations can refine its shared analysis.
- Remove deletes shared evidence/media first, then its local original. Removing an
  unpublished voice capture deletes that backend draft too.
- Private thumbnails use authenticated requests and temporary blob URLs. No keys
  enter image URLs, content scripts or catalog links.
- This remains an unpacked Chrome distribution, not a Web Store installation.

## Validation

Run `node --test experiments/chrome-sidepanel/tests/*.test.js`. Tests cover capture
navigation, modern/legacy compatibility, multimodal uploads, uncertain create /
upload / publish retries, transcript correction, account switching, offline scope,
WAV encoding, managed login and revision polling.

`tests/http-journey.mjs` runs the actual controller and bundled SDK against an
explicit isolated API. Supply `MYMAH_TEST_API_URL`,
`MYMAH_TEST_ACCOUNT_TOKEN`, and `MYMAH_TEST_VOICE_WAV` (synthetic speech fixture).
It requires the feature on and verifies analysis, review, correction, shared
publication, voice search, annotation, Explore, resume and deletion. It makes model
calls when pointed at a live provider. The combined-release validation record owns
installed-browser and live API results; old 0.4 verification is historical.
