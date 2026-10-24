# Mynah Finds 0.2.0 — verification

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
