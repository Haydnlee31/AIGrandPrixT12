# Mynah Finds — Chrome capture and intent experiment

This is Chime’s standalone, locally stored side-panel extension, version 0.2.0. It belongs to the Coupang main challenge. It is separate from the repository’s backend-connected `extension/` scaffold and from the earlier hackathon games.

## Try it

Load this folder unpacked in Chrome. If you already installed the previous local `mynah-finds/` folder, update its files in place and click **Reload** on the existing extension in `chrome://extensions`. Keep the same folder and installation to preserve its extension ID and saved library. Do not uninstall it.

1. Open a regular website and click the Mynah Finds toolbar icon to grant access to that tab.
2. Click **Save page**, then tap one suggested intent. There is no required typing. **Add a note**, a custom answer, **Not now**, and inspiration-only choices remain available.
3. **Screenshot** saves the visible page. **Upload an image** accepts PNG, JPEG or WebP up to 8 MB. **Conversation screenshot** uses the same picker and offers conversation-specific intent choices without reading the image’s words.
4. Right-click an image and choose **Save image to Mynah Finds**. The panel opens with the image and its intent choices. The image is copied locally, along with its page source and available alt text/caption. When browser cross-origin protections prevent copying pixels directly, the extension saves a labelled crop of the visible image. Bring the whole image into view if you need the full picture. Protected embedded frames may require opening the image in a new tab or uploading it.

The updated toolbar and panel use the team’s existing bird icons. No build step, server or API key is needed. Run `npm test` for the tests.

## What questions use

Available article text, explicit selections, social-post captions, image alt text/captions, an optional note, or the explicitly selected conversation type. The NParks bird article has learning, binoculars, outing and inspiration choices. A claymation caption offers creative-activity choices. Unknown content gets general choices. Notes take precedence.

These are local keyword suggestions, not generative AI. Images are not OCR’d; video/audio is not analysed or downloaded. A saved social link is not proof that its media was understood. Choices record the user’s intent for that item; they do not start shopping, price monitoring, booking or purchasing. Prices and exact product identities are never invented.

## Data and permissions

- IndexedDB `saved-shopping`, store `saves`, retains images and answers locally. The original record shape remains readable; new provenance fields are additive. No migration or deletion runs on update.
- `activeTab` and `scripting`: read the specific tab after a toolbar/menu action; `sidePanel`: the UI; `contextMenus`: the explicit image action; `storage`: short-lived context-action status shared between worker and panel.
- No host permissions, browser-history access, background crawling, account access, analytics, remote requests or uploads. CSP keeps extension connections disabled.
- Images resize to at most 2048 pixels. This is a convenient saved copy, not an archival original. Failed captures are reported without discarding existing saves. Changing tabs or moving a protected image during capture cancels the operation.
- Removing an item requires a second confirmation click. Clearing extension data or uninstalling it removes the local library.

## Integration boundary for Haydn and Adi

The current shared handoff accepts URL/title/selected text/note, but has no image-upload or editable-save-metadata endpoint. This experiment deliberately does not call those backend APIs, change their contracts, or claim cross-device sync. Its optional intents expand the experience requested by Chime without changing the shared library scaffold.

Review `questions.js` for the typed question/choice/answer shape, `capture.js` for page and upload inputs, and `image-capture.js` for right-click capture and provenance. A backend integration needs an agreed media upload contract, privacy/retention rules, stored intent updates, and real question generation. API credentials must stay server-side. Local screenshot data must not silently become an uploaded artifact.

The team handoff currently spells the app “Mymah Finds”; this experiment uses the user-confirmed “Mynah Finds.” Shared naming changes are not included.

## Test sources

- NParks: https://www.nparks.gov.sg/publications-resources/articles/how-now-brown-bird
- Instagram: https://www.instagram.com/p/Dd1Z-TWs20c/ (requires availability/access in the current browser; uses caption only)
- `tests/conversation-sample.html`: clearly fictional conversation for a screenshot-upload test.

See `TESTING.md` for results and remaining limits. Browser context menu behavior follows [Chrome’s contextMenus API](https://developer.chrome.com/docs/extensions/reference/api/contextMenus).
