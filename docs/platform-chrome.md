# Mymah Finds — Chrome extension handoff

The Mymah Finds Chrome extension saves links, selected text, and notes into the user's Library through the shared `/v1` API. The product structure is **Library**, **Search**, and **Profile**, with only the user's saved content in view. The Chrome teammate owns capture and browser interactions in `extension/`; persistence and access control belong in the backend. Intelligence, recommendations, product catalogs, and commerce tracking are later work and do not appear in the current interface.

## Run and load

1. Follow the root README to install backend dependencies, then run `make run`. This starts the API with its embedded worker by default. The development API origin is `http://127.0.0.1:8000`; the root README describes the optional separate-worker setup.
2. Run `make extension` to copy the shared JavaScript client into `extension/lib/client.js` and generate `dist/chrome-extension/` plus its ZIP. Rerun it after changing the shared client.
3. Open `chrome://extensions`, enable **Developer mode**, choose **Load unpacked**, and select the repository's `extension/` directory. Pin **Mymah Finds** from the toolbar's extensions menu.
4. Open a public HTTP or HTTPS page, select text if useful, then open the extension. Review the link, title, text, and note. The local default workspace token is `demo-alex`; `demo-sam` exercises a separate user's Library. These internal development credentials have not been renamed.
5. Choose **Save to Library**. **Open Library** opens the web app at the configured backend origin. The worker handles the request if the popup closes; reopening the same draft retries with the same mutation key.

For a hosted backend, open **Settings**, enter an HTTPS origin without a path, and choose **Save and allow backend**. Chrome requests access to that precise scheme, hostname, and port. Permission denial keeps the previous configuration. Reopen the popup and enter the token for that workspace. Tokens never move automatically between origins. HTTP is accepted only for `localhost` and `127.0.0.1` development servers.

To share a build, run `make extension`; `make handoff` also packages the whole framework for both platform teammates. The extension ZIP contains `manifest.json` at its root and excludes tests and development metadata. A teammate extracts the archive and uses **Load unpacked**. A ZIP is not an automatic installer or a Chrome Web Store listing. This setup did not install the extension or grant any Chrome permissions on the user's machine.

## Module boundaries

| File | Responsibility |
| --- | --- |
| `manifest.json` | Manifest V3, toolbar action, module service worker, settings, permissions, bundled-script policy |
| `popup.html`, `popup.css`, `popup.js` | Capture review/edit form, active-page extraction, session draft, and visible states |
| `options.html`, `options.js` | Backend origin, explicit optional permission request, removal of the previous optional origin |
| `service-worker.js` | Trusted popup message boundary, configured-host permission check, serialized API calls |
| `capture-service.js` | Persist mutation identity before sending, bind retry identity to origin/token/content |
| `platform.js` | Pure URL validation, source attribution, limits, error copy, request fingerprints |
| `lib/client.js` | Packaged shared API client; edit its source in `clients/javascript/`, then rebuild the package |
| `tests/` | Dependency-free tests for permission scope, payloads, and retry behavior |

The service worker only accepts `capture:save` from this extension's popup. It never accepts an arbitrary fetch URL from a web page or content script. It sends through the configured `CommonThreadClient`; this existing internal SDK name remains unchanged by the Mymah Finds branding. `client:'chrome_extension'` records the capture interface while `source` identifies Pinterest, Instagram, or the web. No permanent content script runs on every page.

Use the shared SDK for new interfaces:

```js
import {CommonThreadClient} from './lib/client.js';
const client = new CommonThreadClient({baseURL, token});
const capabilities = await client.capabilities();
const page = await client.collection({offset:0, limit:20});
```

`/v1/capabilities` declares content types, size limits, feature support, and data modes. Currently capture accepts a URL, title, selected text, and note; it does not accept image/video binaries or screenshots. The existing `collection()` SDK method supplies the user's Library; its API name is unchanged. Search should operate on that user's saved content, and Profile should contain account and connection controls. Do not surface fixture products, generated annotations, intelligence scores, or tracking demonstrations in this version. Follow the shared API contract for mutation keys, version conflicts, pagination, and authorization; timestamps are Unix seconds UTC.

## State and retry rules

The backend origin is stored in `chrome.storage.local`. Workspace tokens, unfinished drafts, and the latest mutation key live in `chrome.storage.session`, with access limited to trusted extension contexts. Session state survives a popup or worker closing, but clears on browser restart, extension reload/update, or disable. Switching backend clears session credentials and capture state. Do not put credentials in page DOM, URL parameters, synced storage, logs, or collected payloads.

A key is persisted before sending. An unchanged retry uses that same key, including a retry after popup closure or an interrupted response. Changing the payload, token, or backend creates a different request identity. Requests are serialized in the worker so overlapping popup instances observe the same saved key. The scaffold keeps one pending capture, not a durable multi-item offline queue.

Successful retries still contact the backend. If an earlier save was invalidated by deletion, the backend returns `410 mutation_expired`; the popup keeps the key and offers **Start a new save**. Only that explicit action clears the previous attempt. Do not silently generate a fresh key after `mutation_expired`, a timeout, or a server error.

The popup recovers the URL/title from tab metadata when script injection is blocked on an otherwise supported public page. Browser-internal pages, local file URLs, and unsupported links show an explanation instead of attempting to capture. The server remains the final URL validator. Selection extraction is from the main document; iframe selections and image-only content require separate feature design.

## Chrome-specific work for the interface teammate

- Design the toolbar popup around **Save to Library** and **Open Library**. If adding an extension page or side panel, retain **Library / Search / Profile** and show only the user's own saves. Use Mymah Finds branding, warm neutral surfaces, and a restrained orange accent; keep prototype and demo messaging out of the interface. Preserve editable preview, explicit Save, loading, success, retry, empty, unauthorized, and unsupported-page states, with clear labels and keyboard focus.
- Keep `activeTab` as the capture entry point. Do not add background browsing, cookies, persistent all-site content scripts, or account scraping to implement saving. A context-menu action or keyboard command is a separate explicit capture trigger and needs its own manifest entries and review flow.
- Test toolbar pinning, site-access permission denial/revocation, HTTPS backend changes, restricted Chrome pages, navigation while opening the popup, selection-free pages, long titles/text, popup closure during submission, reload, and browser restart. An expired or missing workspace token must lead to a clear sign-in state.
- If adding offline capture, build an explicit durable queue with per-entry mutation keys, account/origin scoping, retention, visible retry/cancel controls, and token revalidation. The present session draft intentionally does not promise persistence across browser restart.
- Add proper hosted authentication and logout/session-expiry UX with the backend owner. The existing local bearer tokens are development credentials. A real browser auth flow may need `chrome.identity`; request it only as part of that feature.
- Notifications and commerce tracking are later features. Browser notifications would require a separate permission, user controls, and real delivery integration. Worker lifetime is event-driven; do not rely on a popup remaining open or an in-memory timer for delivery.
- Image capture/upload, screenshots, OCR, extracted product media, iframe selections, automatic metadata fetching, and direct purchasing are not implemented. Coordinate any new payload or backend capability before adding these UI affordances.
- Prepare extension icons, screenshots, privacy disclosure, production backend configuration, and Chrome Web Store assets for distribution. Replace the development localhost grant for a production-only package. If a website offers **Add to Chrome**, it must link to the published store listing; a website cannot silently install this extension.

## Validation

Run from the repository root:

```sh
node --test extension/tests/*.test.js
node --check extension/popup.js
node --check extension/options.js
node --check extension/service-worker.js
```

These checks cover request validation, optional permission scope, source/client separation, stable retry identities, credential scoping, and deletion invalidation. They do not substitute for loading the build in Chrome. Before distributing, manually exercise the scenarios above against the running backend and inspect `chrome://extensions` for manifest, service-worker, or permission errors.

Chrome API behavior is based on official documentation for [activeTab](https://developer.chrome.com/docs/extensions/develop/concepts/activeTab), [runtime optional permissions](https://developer.chrome.com/docs/extensions/reference/api/permissions), [host match patterns](https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns), [storage lifetimes](https://developer.chrome.com/docs/extensions/reference/api/storage), and [extension network requests](https://developer.chrome.com/docs/extensions/develop/concepts/network-requests).

The numeric port in a host pattern is intentional. Chrome's match-pattern documentation says that omitting the port matches all ports. Chromium's [extension CORS permission conversion](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/common/cors_util.cc) preserves a numeric port using `kAllowOnlySpecifiedPort`; it uses `kAllowAnyPort` for a wildcard. The framework also validates the complete configured API origin independently before sending a request.
