# Mynah Finds — Chrome capture and intent experiment

This is Chime’s standalone, side-panel extension, version 0.3.0 with optional shared-library sync. It belongs to the Coupang main challenge. It uses the repository’s shared backend; the older `extension/` popup scaffold remains separate and from the earlier hackathon games.

## Try it

Load this folder unpacked in Chrome. If you already installed the previous local `mynah-finds/` folder, update its files in place and click **Reload** on the existing extension in `chrome://extensions`. Keep the same folder and installation to preserve its extension ID and saved library. Do not uninstall it.

1. Open a regular website and click the Mynah Finds toolbar icon to grant access to that tab.
2. Click **Save page**, then tap one suggested intent. There is no required typing. **Add a note**, a custom answer, **Not now**, and inspiration-only choices remain available.
3. **Screenshot** saves the visible page. **Upload an image** accepts PNG, JPEG or WebP up to 8 MB. **Conversation screenshot** uses the same picker. Local/basic mode offers honest general choices; configured AI mode reads the uploaded image to generate contextual choices.
4. Right-click an image and choose **Save image to Mynah Finds**. The panel opens with the image and its intent choices. The image is copied locally, along with its page source and available alt text/caption. When browser cross-origin protections prevent copying pixels directly, the extension saves a labelled crop of the visible image. Bring the whole image into view if you need the full picture. Protected embedded frames may require opening the image in a new tab or uploading it.

The updated toolbar and panel use the team’s existing bird icons. No build step is needed. Local saving needs no server or key. Optional shared mode needs the local backend below. Run `npm test` for the tests.

## Connect to the local backend

From the repository root, install `requirements.lock` into `.venv` and run `make run`. Open **Connect a shared library** in the side panel and use `http://127.0.0.1:8000` with the development token `demo-alex`. Grant access to that local backend. The web library opens at the same URL and uses the same demo account.

After connecting, new captures and answers sync. Existing local saves stay local until you choose **Share with library**. Tokens last only for the Chrome session; reconnect after a browser restart. No provider key belongs in the extension.

For real image/text understanding, configure `ANNOTATION_PROVIDER=openai`, `OPENAI_MODEL=gpt-6-luna` (or another compatible model) and `OPENAI_API_KEY` in the server’s Git-ignored `.env`, then restart `make run`. Reconnect Chrome so it reads the updated capabilities. **Refresh / retry sync** can upgrade a previously basic result or retry failed understanding. Do not paste API keys into chat or shared docs.

The server uses the [Responses image-input API](https://developers.openai.com/api/docs/guides/images-vision) and [Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs). The default model supports both [image input and structured output](https://developers.openai.com/api/docs/models/gpt-6-luna).

## What the question uses

Local mode uses captured article text, selected text, social captions, image alt text/captions, optional notes, and the chosen conversation type. It preserves the existing birdwatching/creative intent choices. Basic backend mode never claims to read an image. AI mode sends only the explicitly shared save’s text/image to the server-side model, returning one question, possible intents and supporting evidence. “Just inspiration” and “Not now” remain available.

Text evidence is checked against captured text. Image evidence is labelled as an unverified AI reading. A quote from a friend or article is not independent verification of its claim. The model has no browsing or action tools; out-of-scope/unclear/refused results get a neutral fallback, unsupported text evidence fails safely, and numeric price/discount assertions are filtered. These controls reduce mistakes; they do not guarantee perfect model accuracy.

Reels use captured captions only, unless you explicitly save a visible frame as an image. Video/audio is not downloaded or analysed. Choosing an intent saves context and a next-step prompt; it does not book, purchase, recommend live products or start monitoring.

## Data, retries and deletion

- Local records remain in IndexedDB `saved-shopping` / `saves`. Existing records are readable without a destructive migration.
- `activeTab`, `scripting`, `sidePanel`, `contextMenus` and `storage` support explicit capture and short-lived connection state. Optional host permission is requested only for the backend hostname you choose. No browser-history access or background crawling.
- The token lives in `chrome.storage.session`. Captures, answer attempts and mutation keys are durable in IndexedDB and bound to the backend plus server-confirmed user ID. Unknown results retry with the original body/key; switching accounts does not replay them.
- Use **Refresh / retry sync** after a network failure or to pull a newer answer from the web app. Uploads remain local when disconnected; there is no unattended sync promise.
- Images resize to ≤2048 pixels. Backend accepts single-frame PNG/JPEG/WebP ≤4 MiB and ≤16 MP; large images that exceed the limit remain saved locally with an error. The local file picker limit is 8 MB before resizing.
- Right-click capture retains its original source and available alt text; protected image copying falls back to a labelled crop of the visible pixels. Unsupported frames report a recovery message.
- Remove requires a second click. Shared records are removed from the backend before the local copy is deleted; reconnect to the owning account to finish. Uninstalling/clearing Chrome extension data erases local records, but cannot erase server records.
- Server images are private authenticated attachments. Deleting a save deletes its image and invalidates old mutation receipts.

## Integration for Haydn and Adi

Use the existing `POST /v1/saves`, collection and response routes. The additive media/retry contract, limits and ownership are described in [the team handoff](../../docs/team-handoff.md). Generated OpenAPI/TypeScript and Swift models include images and next steps. Adi’s native UI is still separate work.

`shared.js` owns account-scoped capture/answer retries; `connection.js` owns explicit connection/permissions; `storage.js` retains local records. `lib/client.js` is copied from the shared SDK by `scripts/package_handoff.py`; keep copies identical. The provider lives in `backend/app/content.py`. CORS settings belong on the backend, and the OpenAI key stays there.

## Test sources

- NParks: https://www.nparks.gov.sg/publications-resources/articles/how-now-brown-bird
- Instagram: https://www.instagram.com/p/Dd1Z-TWs20c/ (requires availability/access in the current browser; uses caption only)
- `tests/conversation-sample.html`: clearly fictional conversation for a screenshot-upload test.

See `TESTING.md` for results and remaining limits. Browser context menu behavior follows [Chrome’s contextMenus API](https://developer.chrome.com/docs/extensions/reference/api/contextMenus).
