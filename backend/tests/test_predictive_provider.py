import asyncio
from copy import deepcopy
import json
from types import SimpleNamespace

import httpx
import pytest

from backend.app.intelligence import DemoAnnotationProvider
from backend.app.predictive import (
    ACTION_TEXT, ASTRA_ENDPOINT, MAX_RESPONSE_BYTES, AstraAnnotationProvider,
    ProviderError, get_annotation_provider,
)


@pytest.fixture(autouse=True)
def clean_provider_environment(monkeypatch):
    for key in ("ASTRA_API_KEY", "OPENAI_API_KEY", "ASTRA_MODEL", "ASTRA_SERVICE_TIER", "ANNOTATION_PROVIDER"):
        monkeypatch.delenv(key, raising=False)


def capture(**updates):
    fields = dict(title="Desk lamp", selected_text="A reading corner", note="Just ideas for now",
                  image_data_url=None, confirmed_preferences=("I like warm lighting",))
    fields.update(updates)
    return SimpleNamespace(**fields)


def result(**updates):
    value = {
        "subject": "A compact desk lamp", "content_kind": "product", "visual_attributes": [],
        "actions": ["save_inspiration", "remind_later", "compare_options"],
    }
    value.update(updates)
    return value


def envelope(value=None):
    return {
        "status": "completed",
        "output": [
            {"type": "reasoning", "summary": []},
            {"type": "message", "role": "assistant", "status": "completed",
             "content": [{"type": "output_text", "text": json.dumps(value or result())}]},
        ],
    }


def provider(handler, **kwargs):
    return AstraAnnotationProvider("secret-not-to-log", transport=httpx.MockTransport(handler), **kwargs)


def test_actual_image_and_confirmed_context_use_strict_responses_contract():
    image = "data:image/png;base64,iVBORw0KGgo="
    calls = []

    def handle(request):
        calls.append(request)
        assert request.url == ASTRA_ENDPOINT
        assert request.headers["Authorization"] == "Bearer secret-not-to-log"
        body = json.loads(request.content)
        assert body["model"] == "gpt-6-astra"
        assert body["reasoning"] == {"effort": "low"}
        assert body["store"] is False
        assert body["max_output_tokens"] == 1600
        assert "temperature" not in body and "tools" not in body
        assert body["text"]["format"]["strict"] is True
        assert body["text"]["format"]["schema"]["additionalProperties"] is False
        content = body["input"][0]["content"]
        assert content[1] == {"type": "input_image", "image_url": image, "detail": "auto"}
        text = json.loads(content[0]["text"])
        assert text["note"] == "Just ideas for now"
        assert text["confirmed_preferences"] == ["I like warm lighting"]
        return httpx.Response(200, json=envelope(result(visual_attributes=["warm light", "compact base"])))

    model = provider(handle)
    output = model.understand_capture(capture(image_data_url=image))
    assert len(calls) == 1
    assert output["features"]["image_analyzed"] is True
    assert output["features"]["confirmed_context_used"] is True
    assert output["features"]["data_mode"] == "astra"
    assert output["suggestions"] == [
        {"kind": "intent", "claim": action, "text": ACTION_TEXT[action]}
        for action in ["save_inspiration", "remind_later", "compare_options"]
    ]
    assert model.version == "gpt-6-astra:predictive-v1"


def test_capture_and_history_are_bounded_without_fetching_urls():
    def handle(request):
        content = json.loads(request.content)["input"][0]["content"]
        assert len(content) == 1
        data = json.loads(content[0]["text"])
        assert len(data["title"]) == 300
        assert len(data["selected_text"]) == 4000
        assert len(data["note"]) == 1000
        assert len(data["confirmed_preferences"]) == 12
        assert all(len(value) == 300 for value in data["confirmed_preferences"])
        return httpx.Response(200, json=envelope())

    provider(handle).understand_capture(capture(title="t" * 1000, selected_text="s" * 10000,
                                              note="n" * 5000, confirmed_preferences=("p" * 500,) * 20))


@pytest.mark.parametrize("image", ["https://example.com/a.png", "file:///etc/passwd", "data:image/svg+xml;base64,AAAA", "data:image/png;base64,AAA!", "data:image/png;base64,AAAA\n"])
def test_non_upload_image_rejected_before_network(image):
    def handle(_):
        pytest.fail("Invalid image must never reach API")
    with pytest.raises(ProviderError, match="astra_invalid_image"):
        provider(handle).understand_capture(capture(image_data_url=image))


@pytest.mark.parametrize("status,code,retryable", [
    (401, "astra_authentication_failed", False), (403, "astra_authentication_failed", False),
    (429, "astra_rate_limited", True), (503, "astra_unavailable", True),
    (408, "astra_unavailable", True), (400, "astra_request_rejected", False),
    (302, "astra_request_rejected", False),
])
def test_http_errors_are_classified_without_body_or_credentials(status, code, retryable):
    calls = []
    def handle(request):
        calls.append(request)
        return httpx.Response(status, text="secret-not-to-log private customer image", headers={"location": "https://evil.example"})
    with pytest.raises(ProviderError) as error:
        provider(handle).understand_capture(capture())
    assert error.value.code == code and error.value.retryable is retryable
    assert "secret" not in repr(error.value) and "private" not in repr(error.value)
    assert len(calls) == 1  # no redirects or hidden retries


def test_total_deadline_cancels_slow_request():
    closed = []
    async def slow(_):
        try:
            await asyncio.sleep(5)
        finally:
            closed.append(True)
        return httpx.Response(200, json=envelope())
    with pytest.raises(ProviderError) as error:
        provider(slow, timeout_seconds=0.01).understand_capture(capture())
    assert error.value.code == "astra_timeout" and error.value.retryable
    assert closed == [True]


@pytest.mark.parametrize("exception", [httpx.ReadTimeout("secret-not-to-log"), httpx.ConnectError("private capture")])
def test_transport_error_text_is_not_retained(exception):
    def handle(_):
        raise exception
    with pytest.raises(ProviderError) as error:
        provider(handle).understand_capture(capture())
    assert error.value.retryable
    assert str(error.value) in {"astra_timeout", "astra_unavailable"}
    assert error.value.__suppress_context__ is True


@pytest.mark.parametrize("value", [
    result(actions=["buy_intent"]),
    result(actions=["buy_intent", "buy_intent", "remind_later"]),
    result(actions=["buy_intent", "delete_library", "remind_later"]),
    result(subject="x" * 121),
    result(subject="\n"),
    result(content_kind="verified_sku"),
    result(visual_attributes=["unseen texture"]),
    result(price=199),
])
def test_schema_and_semantic_validation_rejects_untrusted_model_output(value):
    with pytest.raises(ProviderError) as error:
        provider(lambda _: httpx.Response(200, json=envelope(value))).understand_capture(capture())
    assert not error.value.retryable


def test_refusal_is_not_fallback_success():
    value = envelope()
    value["output"][1]["content"] = [{"type": "refusal", "refusal": "private reason"}]
    with pytest.raises(ProviderError, match="astra_refused") as error:
        provider(lambda _: httpx.Response(200, json=value)).understand_capture(capture())
    assert not error.value.retryable


@pytest.mark.parametrize("kind", ["malformed", "too_large", "incomplete", "empty", "multiple_messages", "nested"])
def test_response_envelope_is_bounded_and_complete(kind):
    response = envelope()
    if kind == "malformed":
        transport_response = httpx.Response(200, content=b"{broken json")
    elif kind == "too_large":
        transport_response = httpx.Response(200, content=b" " * (MAX_RESPONSE_BYTES + 1))
    elif kind == "nested":
        transport_response = httpx.Response(200, content=b"[" * 2000 + b"]" * 2000)
    else:
        if kind == "incomplete":
            response["status"] = "incomplete"
        elif kind == "empty":
            response["output"] = []
        else:
            response["output"].append(deepcopy(response["output"][1]))
        transport_response = httpx.Response(200, json=response)
    with pytest.raises(ProviderError) as error:
        provider(lambda _: transport_response).understand_capture(capture())
    assert not error.value.retryable


def test_backend_configuration_auto_astra_and_explicit_fallback(monkeypatch):
    assert isinstance(get_annotation_provider(), DemoAnnotationProvider)
    monkeypatch.setenv("OPENAI_API_KEY", "backend-only-secret")
    assert isinstance(get_annotation_provider(), AstraAnnotationProvider)
    monkeypatch.setenv("ASTRA_API_KEY", "preferred-backend-secret")
    monkeypatch.setenv("ASTRA_SERVICE_TIER", "fast")
    model = get_annotation_provider()
    assert model._api_key == "preferred-backend-secret"
    assert model.service_tier == "fast"
    assert "secret" not in repr(model)
    monkeypatch.setenv("ANNOTATION_PROVIDER", "fallback")
    assert isinstance(get_annotation_provider(), DemoAnnotationProvider)


def test_explicit_astra_requires_key_and_invalid_settings_fail_startup(monkeypatch):
    monkeypatch.setenv("ANNOTATION_PROVIDER", "astra")
    with pytest.raises(ProviderError, match="astra_key_missing"):
        get_annotation_provider()
    monkeypatch.setenv("ANNOTATION_PROVIDER", "unrecognized")
    with pytest.raises(ProviderError, match="annotation_provider_invalid"):
        get_annotation_provider()
    with pytest.raises(ProviderError, match="astra_invalid_model"):
        AstraAnnotationProvider("key", model="https://evil.example")
    with pytest.raises(ProviderError, match="astra_invalid_service_tier"):
        AstraAnnotationProvider("key", service_tier="made-up")
    with pytest.raises(ValueError):
        AstraAnnotationProvider("key", timeout_seconds=60)


def test_closed_provider_cannot_make_further_requests():
    model = provider(lambda _: pytest.fail("closed provider"))
    model.close()
    with pytest.raises(ProviderError, match="astra_provider_closed"):
        model.understand_capture(capture())
