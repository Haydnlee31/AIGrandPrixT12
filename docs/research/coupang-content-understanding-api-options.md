# Content understanding and contextual questions: API recommendation

Research checked against official OpenAI documentation on 24 October 2026. The model, Decisions, Structured Outputs, vision, and transcription pages were independently rechecked against the official documentation connector. This is a proposed integration boundary, not implemented code. Model availability and SDK compatibility have not been tested with the team's account.

## Recommended first slice

Use **Python, Pydantic, and the OpenAI Responses API with Structured Outputs** behind a provider-neutral adapter. Start with configurable model ID `gpt-6-luna`: its current model page confirms text/image input, text output, and Structured Outputs; OpenAI positions it for efficient, focused, high-volume work. Benchmark it on the team's actual screenshots before choosing a more capable fallback. Do not hard-code model selection throughout the application. [Model documentation](https://developers.openai.com/api/docs/models/gpt-6-luna)

Send the model the content that was actually captured: screenshot/image bytes, extracted article text, caption text, and any user note. Responses accepts text and images together; a base64 image data URL is a documented input format. Vision can misread small text and make incorrect descriptions, so retain evidence and return an unreadable/insufficient-content result where appropriate. [Vision guide](https://developers.openai.com/api/docs/guides/images-vision)

A saved Instagram or TikTok URL alone does not establish that the backend has obtained the video. Make media fetching/extraction an upstream capability with explicit success/failure states. For the first demo, support screenshots, available article text, and user notes; handle unavailable video by asking for a screenshot or short description. Never describe unseen frames as observed facts.

For recorded voice notes, the current recommended model is **`gpt-transcribe`**, using `client.audio.transcriptions.create(model="gpt-transcribe", file=audio_file)` and reading `transcription.text`. The guide supports files up to 25 MB, including M4A, MP3 and WAV. A completed voice note needs no persistent Realtime connection. `gpt-live-transcribe` is the documented option for live microphone transcription if that experience is later required. [File transcription](https://developers.openai.com/api/docs/guides/speech-to-text), [transcription overview](https://developers.openai.com/api/docs/guides/transcription)

The current transcription overview marks older Whisper and GPT-4o transcription models, including `gpt-4o-mini-transcribe`, as deprecated with shutdown scheduled for 26 February 2027. Avoid starting a new integration from an older tutorial without checking this. [Deprecations](https://developers.openai.com/api/docs/deprecations#2026-08-26-transcription-models)

## Two functions Chime can own

```python
async def understand_content(content: ContentInput) -> ContentUnderstanding: ...
async def propose_next_interaction(context: DecisionInput) -> NextInteraction: ...
```

These should be importable modules in Haydn's Python backend/worker. Keep HTTP routes, authentication, storage, jobs, action eligibility and evidence mutations with Haydn. Adi renders the agreed typed payloads in iPhone and Chrome clients.

- **ContentInput:** content ID, source type and URL, supplied text/images, optional voice transcript or note, and context version. The input should state what was actually retrieved.
- **ContentUnderstanding:** neutral summary, observed objects/products/activities, evidence references, uncertainty, and proposed intent annotations. Separate a visible fact such as “wooden shelves” from an inference such as “might want this room's style.” Proposed annotations do not become confirmed user preferences automatically.
- **DecisionInput:** extracted understanding, prior answers, confirmed context, available evidence, context version, and Haydn's permitted actions. Selection must stay within those permitted actions.
- **NextInteraction:** preserve the team's fields `action_type`, `evidence_ids`, `missing_information`, `reason_codes`, and `context_version`; add a bounded question payload with a stable question ID, concise wording, answer option IDs/labels, optional free-text/voice response, and a skip option. Agree exact enums with Haydn and Adi before implementation.

Return at most one next question. For a bakery screenshot, a useful first question could be “What caught your eye?” with “Try it myself,” “Bring someone,” “Buy a gift,” and “Just keeping it.” Budget or seasonal monitoring comes after the user's purpose is clearer. This question design is a product recommendation, not a documented API requirement.

The verified Python SDK pattern is `client.responses.parse(model=..., input=..., text_format=YourPydanticModel)` followed by `response.output_parsed`. The documented vision `input_text`/`input_image` content blocks can supply the multimodal input. For an async worker/module, use the corresponding async SDK client and verify the installed SDK version in the initial smoke test. Handle refusals, incomplete responses, timeouts and schema-validation failures explicitly. Structured Outputs constrains shape; it does not prove that a statement is true. [Structured Outputs guide](https://developers.openai.com/api/docs/guides/structured-outputs), [vision guide](https://developers.openai.com/api/docs/guides/images-vision)

## Where Decisions API fits

**Decisions API is real and currently generally available.** Its endpoint is `POST /v1/decisions`, its documented supported model is `gpt-6-luna`, and it returns one of three typed answer forms: predicate probability, choice from supplied options, or score against a rubric. The Python guide documents `client.decisions.create(...)`. It accepts text, images and JSON; it does not execute the chosen action. [Decisions guide](https://developers.openai.com/api/docs/guides/decisions)

Use it optionally to choose among an existing permitted action set, such as ask for purpose, ask a constraint, retrieve products, or save without prompting. **Use Responses plus Structured Outputs to generate the actual question, answer options, extracted entities, and explanations.** This distinction is explicitly stated in the Decisions guide. Adding Decisions is unnecessary for the initial two-function prototype; first measure whether separate classification improves selection enough to justify another call. A probability returned by Decisions is a model estimate, not evidence that a product identity, price or discount is correct.

## Guardrails and integration handoff

1. Haydn validates allowed actions, evidence references and context versions before accepting an output. Chime returns proposals; the model cannot authorize a watch, change durable preferences, or initiate a purchase.
2. Treat posts, captions and screenshots as untrusted content, never instructions to the system. Limit generated questions to the shopping context; return a bounded out-of-scope result for unrelated requests.
3. Keep price, stock, discounts and coupon eligibility out of unsupported model claims. Those require a separate product/evidence source with observation time and conditions. A screenshot showing a discount is evidence of what the screenshot says, not confirmation of a current offer.
4. Hand over Pydantic schemas, mocked JSON examples, a provider adapter, prompt versions, and a small evaluation set before connecting the UI. Include clear and ambiguous screenshots, unreadable content, “just saving,” conflicting preferences, and embedded prompt-injection text.
5. Demonstrate the complete path: captured content → supported understanding → one useful question → answer changes the next shopping step. This is the smallest credible demonstration of multimodal understanding plus soft-intent discovery.

No agent framework, vector database, or live social-history import is needed to validate this first slice. Account access, model latency, cost per saved item, and extraction coverage remain measurements for the team's first integration test.

For the Chrome extension, send captured content to the same backend contract as the iPhone client. The extension should receive persisted job/item state and typed questions; it should not contain OpenAI credentials or duplicate this model pipeline. A successful save and a successful analysis are separate states, so model failure never loses the user's saved content.
