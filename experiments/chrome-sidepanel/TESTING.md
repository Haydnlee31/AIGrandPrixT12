# Mynah Finds 0.3.0 — shared-flow verification

Checked 25 October 2026. This branch extends the original local capture experiment.

- Final automated results: **37 backend tests and 57 JavaScript tests passed** (29 shared/web/scaffold, 28 side-panel), with OpenAPI/TypeScript drift checks, HTTP image-capture smoke checks and the standalone Swift harness passing. Upgrading an existing database retained its saved item.
- Backend automated checks cover image validation, bounded uploads, independent images from the same page, private media access, duplicate/idempotent capture, shared answers, media deletion, refusal/out-of-scope fallbacks, unsupported text quotes, numeric discount claims, and deletion while inference is running. Existing framework/journey tests remain included.
- Side-panel tests cover retained capture/answer keys, account/backend mismatch, local intent preservation in basic mode, and importing a newer web answer without overwriting it.
- Shared SDK, original extension and web library tests run with `make test`; OpenAPI/TypeScript drift is checked. Swift wire models support image-only capture and new media/next-step fields; the standalone Swift harness passes. Native UI, device builds and App Store signing are not tested here.
- Chrome for Testing 151, isolated profile: connected to the local backend through the real hostname permission prompt; saved the real NParks article; uploaded the existing clearly fictional conversation screenshot; selected **Plan something from it** with one click; opened the web library and verified the original image and same persisted intent/next-step text. Changed the intent to **Explore the idea** in the web app, refreshed the side panel, and verified Chrome showed that newer answer without overwriting it.
- Regular Chrome: user reloaded the existing installation; all four earlier saves remained visible. Connected to the local backend, shared the existing NParks article and retained its **Explore binoculars for birdwatching** answer. Duplicate capture correctly reused the existing backend item.
- Real OpenAI calls have **not** been run because no server key is configured. Provider tests use mocked HTTP responses, not fake live-AI results. Browser testing uses visibly labelled basic mode. Full video/audio, live product recommendations/prices, autonomous monitoring and production identity remain unimplemented.

The original v0.2 capture-only test history follows. Its limits describe that earlier version, not the v0.3 backend contract.

---

## Mynah Finds 0.2.0 — earlier verification

Checked 25 October 2026. This is the standalone side-panel experiment, not the backend-connected extension scaffold.

## Automated checks

`npm test`: **22 tests passed**. JavaScript syntax checks passed. Tests cover safe URL/image boundaries; note precedence and optional/skipped answers; real-example article/caption intent routing; conversation type without invented OCR; article extraction and exclusion of social comment threads; tab/navigation changes; selected-image provenance; blocked-frame recovery; and viewport clipping at screenshot scale.

## Actual browser checks

Regular Chrome, installed extension `mmkdjbfokpagfgkeoomfjfifpepfimmk`:

- Reloaded in place; toolbar/panel use the supplied bird artwork.
- Saved the real NParks “How Now Brown Bird?” article with no note. Tapped “Explore binoculars for birdwatching”; answer displayed as saved.
- Imported `tests/sample-conversation.png` using **Conversation screenshot**. The fictional image was retained, conversation intent options appeared, and “Plan something together” was saved. No text was typed and no private conversation was accessed.
- Saved the open Instagram post `https://www.instagram.com/p/Dd1Z-TWs20c/`. Its actual claymation caption became the saved title and supplied creative-activity choices. Tapped “Learn how it was made”; the UI explicitly says it used the caption, not the video/audio.
- Closed the panel, right-clicked the NParks Brown Shrike photo, and used **Save image to Mynah Finds**. Panel opened and saved that image, its alt text and original page link. All previous test saves remained in the collection.

Chrome for Testing 151, isolated profiles:

- Saved the real NParks article and its Eurasian Tree Sparrow image; tap-based birdwatching intents worked.
- Exercised an intentionally cross-origin image (`127.0.0.1` page, `localhost` image, no CORS headers). The first check exposed a viewport change while the side panel opened. Added a short layout-settling delay while retaining the before/after geometry guard. Retested in a fresh process with the final code: save succeeded from a closed panel.
- Visually inspected the fallback crop: it contained only the chosen image, excluded the fixture’s surrounding heading/footer, and displayed “Saved the visible part of this image…” accurately.
- Choices scroll into view automatically after save and fit the default side-panel width.

## Limits not claimed as tested or implemented

- No OCR, image recognition, video/audio understanding, model API, recommendations, live prices, monitoring, backend sync, shared accounts or store publication.
- Keywords and site captions can be incomplete. Instagram layouts/access can change; a bookmark fallback is not full media understanding.
- A protected image crop captures its currently visible pixels (including any visual occlusion); it is not a full-resolution original. Unsupported/protected embedded frames offer a recovery message.
- No exhaustive cross-site, multiple-window, storage-quota, browser-version or accessibility audit. Existing records remain readable by inspection; no destructive database migration is performed.
- The final crop timing fix was verified in Chrome for Testing. Regular Chrome verified original-image saving; its worker loads updated files on a subsequent restart/reload.

The fixtures are explicit test files, not pre-seeded user-library content. Screenshot evidence is kept in the workspace `.artifacts/` directory; it is not embedded into shared app screens.
