# Mymah Finds — predictive annotations

The FastAPI backend saves content immediately, then asks GPT-6 Astra to suggest a few short annotations from the saved image and text. Suggestions are optional interpretations of what the person might want. Only an explicit selection or edit becomes confirmed user input. Contract version: **0.3.0**.

This is the next feature for the Chrome and iOS teammates to connect. Preserve **Library / Search / Profile**, use **Mymah Finds**, and keep provider settings, API keys, internal mode labels, and prototype/demo wording out of product screens.

## Backend configuration

Configure credentials in the backend environment or secret manager:

```dotenv
ANNOTATION_PROVIDER=auto
ASTRA_API_KEY=your-server-side-key
ASTRA_MODEL=gpt-6-astra
ASTRA_SERVICE_TIER=default
```

`OPENAI_API_KEY` is accepted when `ASTRA_API_KEY` is absent. Never put either key in the extension, iOS bundle, browser storage, account token, or client request. The client uses its existing Mymah bearer token; it does not connect directly to OpenAI.

`ANNOTATION_PROVIDER=auto` selects Astra when a backend key is configured and the local fallback when no key is available. `astra` requires the configured provider; `fallback` explicitly selects the limited local path. A configured provider failure must remain an enrichment failure/retry, rather than be presented as successful Astra output. The no-key path does not provide image understanding comparable to Astra.

`ASTRA_SERVICE_TIER=fast` or `ultrafast` can be requested when the API account supports them; `default` is the baseline. Model selection, service tier, credentials, and request budgets belong to backend configuration. Confirm actual latency and account availability with the configured deployment before promising an interactive response time. [GPT-6 documentation](https://developers.openai.com/api/docs/guides/latest-model)

After setting the backend key, run `make smoke-astra` to make **one explicit paid request** using a generated sample image. It checks real vision output and the suggestion schema, reports safe status/latency fields, and never substitutes the fallback. Live Astra credentials and latency have **not yet been verified**; mocked provider and privacy tests have passed.

## Shared client flow

1. Let the person select content and tap **Save**. Send `POST /v1/saves` with a retained `Idempotency-Key`. `url` is optional when `image_data_url` is present; send a URL, an image, or both. Preserve the same image bytes, payload, and key for an unchanged retry.
2. Show the saved item as soon as the capture receipt arrives. Enrichment runs independently; a slow or failed provider does not erase the saved content.
3. Refresh the saved item, or use bounded foreground polling. `status: pending` means suggestions are not ready. `enrichment_failed` means the item remains saved and annotation generation did not complete. Cancel polling when its view or account changes.
4. Display the returned `suggestions` as optional annotation chips. Each has a server ID, display `text`, `kind`, optional `intent`, and `requires_confirmation`. Keep an edit/skip path. Do not automatically select the highest-ranked suggestion.
5. Submit the selected server ID through `POST /v1/saves/{id}/responses`, using a new retained key for that explicit user action. The response's `execution_status: annotation_only` confirms the annotation was recorded.

Example image-only request:

```json
{
  "title": "Reading chair",
  "source": "product",
  "client": "ios_share_extension",
  "image_data_url": "data:image/jpeg;base64,<encoded JPEG bytes>",
  "note": "For my reading corner"
}
```

Use JPEG, PNG, or WebP with at most **4 MiB of decoded input bytes**, within a **6 MiB complete request body**. The backend validates and re-encodes the image without source metadata; an extension or phone should resize and compress selected media before sending. Arbitrary remote image URLs are not an upload mechanism. Image-only saves have an empty `original_url`; the backend supplies their private identity. Hide the original-link affordance when no URL exists, and never open the image's canonical identity as a website.

`has_image` indicates available image content. `image_path` is an API-relative resource served by authenticated `GET /v1/saves/{id}/image`. It is private to the current account. Use the bearer header, avoid persistent shared caches, and discard the displayed image when switching accounts. Do not append an access token to a URL or use an unauthenticated image element with this path.

The stable intent codes are:

| Code | Annotation meaning | What selection does now |
| --- | --- | --- |
| `buy_intent` | Interested in buying this | Records the stated intent |
| `track_discount` | Interested in a future discount | Records the stated intent |
| `remind_later` | Wants to revisit the saved item | Records the stated intent |
| `save_inspiration` | Keeps the content for inspiration | Records the stated intent |
| `compare_options` | Wants to consider alternatives | Records the stated intent |

Selection does not purchase, start a live price monitor, or schedule a notification. Use a confirmation such as **Annotation saved**. Do not show **Reminder set** or **Tracking enabled** from this endpoint. A future reminder flow must confirm the actual time and time zone; “tomorrow” alone is not a scheduled timestamp. Live price tracking needs a verified product/offer, a monitoring rule, and a delivery mechanism. The existing simulated commerce routes do not establish that live service.

## iOS integration

The SDK accepts image-only drafts without changing existing URL callers:

```swift
let request = CaptureRequest(
    title: title,
    source: .product,
    client: .iosShareExtension,
    imageDataUrl: "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
)
let draft = PendingCapture(request: request, accountId: account.userId, baseURL: apiBaseURL)
try await outbox.enqueue(draft)
let receipt = try await client.capture(draft.request, key: draft.key)
try await outbox.remove(draft)
let item = try await client.waitForEnrichment(receipt.id)
if item.hasImage {
    let bytes = try await client.savedImage(item.id)
    // Decode into the image view for the current account.
}
```

The iOS teammate must implement the system photo picker and image Share Extension handling. Convert HEIC or other unsupported formats to JPEG/PNG before encoding; apply orientation and sensible dimensions. Update activation rules for supported image shares, review the preview before upload, and keep Save explicit. This backend/SDK work does not automatically add photo handling to the existing URL-only Share Extension scaffold.

Keep extension work bounded: persist the selected payload before network work and recover in the containing app. Large images consume extension memory and outbox storage, so compress before enqueueing. Use native sheets, Dynamic Type, VoiceOver labels, and appropriate focus/selection states for annotation chips. Actual device acceptance must cover image shares, cancellation, app termination, offline retries, account changes, and authenticated image display.

## Chrome and web integration

The JavaScript SDK sends `image_data_url` through `capture()` and preserves the intent fields returned by `getSave()` and `respond()`; types are generated from OpenAPI. Image fetching is a binary request, outside the SDK's JSON `request()` method:

```js
const imageURL = new URL(`/v1/saves/${encodeURIComponent(item.id)}/image`, api.baseURL);
const response = await fetch(imageURL, {
  headers: {Authorization: `Bearer ${await validAppToken()}`},
  cache: 'no-store', redirect: 'error', signal
});
if (!response.ok) throw new Error(`Image unavailable (${response.status})`);
const objectURL = URL.createObjectURL(await response.blob());
// Assign objectURL to the current account's image view; revoke it on cleanup.
```

Capture the particular image selected through an explicit user gesture, such as a reviewed file picker or an image context-menu action. Add only the necessary Chrome permissions and trusted message handling. Site permissions and cross-origin image access differ; a visible page image does not guarantee readable bytes. Handle unsupported sites honestly and offer another explicit capture path. Do not use an arbitrary backend URL fetch, broad background crawling, cookies, or browsing-history collection to obtain the image. Keep popup closure/retry behavior and account/origin isolation intact.

Annotation chips may arrive after the popup closes. Refresh them when the saved-item view is next opened; do not keep the popup alive as the job runner. Browser notifications and reminder delivery require a separate integration and permissions.

## Dots integration status

Dots knowledge import is deliberately deferred. **Sign in with ChatGPT exists**, but its documented identity and optional inference scopes do not grant conversations or other account context. Dots maintains its own notes and uses relevant ChatGPT memory; no supported consumer endpoint or OAuth scope for reading those notes was verified for this integration. [Sign-in quickstart](https://developers.openai.com/siwc/quickstart), [scope boundary](https://developers.openai.com/siwc/token-sharing-open-source), [Dots tasks and memory](https://learn.chatgpt.com/docs/dots/tasks-and-memory)

A future Mymah plugin could let Dots call our explicitly authorized tools; that direction does not give Mymah permission to read Dots' private memory. A simpler alternative is an explicit, user-reviewed summary of preferences or goals imported into Mymah. Neither path is implemented here. [Plugin authentication](https://developers.openai.com/plugins/build/auth)

## Acceptance boundary

Provider transport, structured output, image validation, tenant isolation, retries, and deleted/stale saves require backend tests. SDK checks cover wire fields and private image transport. Those checks do not establish live model credentials, latency, Chrome permissions, native iOS image pickers, push delivery, or reminder scheduling. Run a real image capture against the configured Astra backend before presenting the connected experience.
