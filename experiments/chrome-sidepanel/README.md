# Mynah Finds — Chrome extension 0.4

Capture a page, screenshot or selected image, understand its products, and explore recommendations from the same shared library as the web app. This is the installed side-panel extension in `experiments/chrome-sidepanel/`; the older `extension/` popup is a separate scaffold.

## Run and connect

There is no build step. Load this folder unpacked in Chrome, or run `python3 scripts/package_handoff.py --sidepanel` at the repository root for `dist/mynah-finds-sidepanel.zip`.

For an existing installation, replace its files **in the same unpacked folder** and click Reload in `chrome://extensions`. Keep the extension ID to preserve IndexedDB saves; do not uninstall. Back up the source folder first. Reloading or restarting Chrome clears the session credential, so reconnect in settings.

1. Open the extension's **Library connection settings**.
2. Use **https://mynah-finds.vercel.app** and the same **Mynah account access key** as the web app. Never use an OpenAI provider key here.
3. Approve Chrome's permission for that backend hostname. New saves and answers go to the shared account; existing unshared saves remain local until **Share with library**.
4. Open a normal page and click the toolbar bird to grant active-tab access. **Save page** captures visible article text/selection; **Screenshot** captures the visible page. Upload accepts JPEG, PNG or WebP. Right-click an image to save that detail.
5. **Library** combines local finds with the account's shared finds. **Refresh**, reopening the panel or returning to it pulls changes from other clients.
6. Open a shared find for **Based on your find**: AI summary, products, observed or inferred attributes, supporting evidence and uncertainties. Choose an intent or write a note. **Refresh AI insights** requests a fresh analysis.
7. **Explore** shows catalog matches based on analyzed shared saves, or an explicit product search. **Why this?** explains the match and opens the saved evidence. Each result retains its source and license attribution.

Unshared local saves do not influence shared recommendations. If iOS still says **On this iPhone / Local Library**, it is not syncing yet: it must use the same URL, account and shared API contract. This branch makes no iOS changes. Native iOS Radar/notifications are not part of this extension update.

## Shared backend contract

The default production backend runs contract 0.4, with server-side product AI and the imported ABO catalog. No AI credential, catalog dump or database connection string ships in the extension.

| Function | API |
| --- | --- |
| Connection and features | `GET /v1/me`, `/v1/capabilities` |
| Capture | `POST /v1/saves` (`image_data_url`, optional URL) |
| All shared finds | `GET /v1/collection` (paginated) |
| Details and private image | `GET /v1/saves/{id}`, `/v1/saves/{id}/image` |
| Intent / refreshed AI | `POST /v1/saves/{id}/responses`, `/analyze` |
| Recommendations / search | `GET /v1/explore` |
| Shared deletion | `DELETE /v1/saves/{id}` |

The deployed AI observes saved content; the recommendation endpoint ranks catalog records with attributed reasons. It does not establish a verified product identity or live stock/price. Historical prices are labelled; unverified catalog records never get a live-offer link. Only the existing public ABO image host is allowed for remote product thumbnails; other sources receive text placeholders.

Legacy local 0.3 servers still support capture, intents and sync using their original `image_data` and `/retry` contract. They cannot provide the 0.4 Explore interface. Default URL is production; use a loopback URL only for a deliberately local demo.

## Privacy and recovery

- Local originals stay in IndexedDB `saved-shopping/saves` with no schema migration. Outgoing images alone are resized if necessary to fit the backend limit, capped at 3 MiB for the deployed request budget. Local uploads accept up to 8 MB before resizing.
- Session tokens are kept in `chrome.storage.session`; cached shared finds and pending mutations are bound to backend origin plus confirmed user ID. A different account's cached finds are hidden. Reconnect to the original account to access its cached saves; they are not deleted or silently copied to a new account.
- Every mutation stores its body and idempotency key before sending. An uncertain request retries unchanged. An in-flight legacy request is not silently rewritten during an upgrade.
- Explicit shared removal affects that account across clients. Server removal finishes before the local mirror is deleted. Remote deletion is respected on the next successful refresh; offline local data is retained.
- Private images use an authenticated request to the chosen backend and temporary blob URLs, revoked on navigation/account changes. Tokens never enter image URLs or catalog links.
- Saving is explicit. No background crawling or browser-history access. Captured text/images go to the configured backend AI provider. Captions are saved for video posts; full audio/video is not analyzed.
- Intents save context; they do not purchase, schedule reminders or enable live price monitoring. Individual sign-in remains a separate follow-up to the shared-account demo.

## Ownership and validation

`panel.js` owns navigation and account refresh; `intelligence.js` renders product insights and Explore; `shared.js` owns durable capture/answer retries; `library-view.js` merges local and remote data; `connection.js` requests host access; `storage.js` remains unchanged.

The transport and feed/presentation helpers in `lib/` were taken from the deployed web branch at `898a6d8`, with a legacy `retrySave` adapter. The generic handoff packager must not overwrite this SDK with the older root SDK. No dependencies were added.

Run `npm test` in this folder. See [TESTING.md](TESTING.md) for verification and remaining limits. `tests/shopping-sample.html` is explicitly synthetic and contains no real offer; it supports manual screenshot-capture QA.
