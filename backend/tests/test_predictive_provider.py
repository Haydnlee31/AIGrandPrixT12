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
from backend.app.understanding import ProductAnalysis, analysis_terms


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
        "analysis": {
            "schema_version": 1, "summary": "A desk lamp for a reading corner",
            "products": [{"product_type": "Desk lamp", "category_path": ["Home", "Lighting", "Desk lamps"],
                          "brand": None, "model": None, "attributes": [], "use_cases": ["Reading"],
                          "search_terms": ["desk light", "task lighting"]}],
            "intent_context": [], "uncertainties": ["Brand and model are not established"],
        },
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
        assert body["max_output_tokens"] == 3500
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
    assert model.version == "gpt-6-astra:predictive-v2"


def test_ios_relay_model_omits_unsupported_reasoning_option():
    def handle(request):
        body = json.loads(request.content)
        assert body["model"] == "gpt-4.1-mini"
        assert "reasoning" not in body
        assert body["text"]["format"]["strict"] is True
        return httpx.Response(200, json=envelope(result()))

    output = provider(handle, model="gpt-4.1-mini").understand_capture(capture())
    assert output["features"]["data_mode"] == "astra"


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


def watch_analysis(**updates):
    value = {
        "schema_version": 1, "summary": "A digital wristwatch with a rectangular face and retro styling",
        "products": [{
            "product_type": "Wristwatch",
            "category_path": ["Accessories", "Watches", "Wristwatches", "Digital watches"],
            "brand": None, "model": None,
            "attributes": [
                {"name": "display_type", "value": "digital", "basis": "image", "evidence": "The face shows numerical time digits", "certainty": "observed"},
                {"name": "style", "value": "vintage-inspired", "basis": "image", "evidence": "Rectangular face and restrained monochrome styling", "certainty": "inferred"},
            ],
            "use_cases": ["Everyday timekeeping"], "search_terms": ["digital wristwatch", "retro watch"],
        }],
        "intent_context": [],
        "uncertainties": ["No readable brand or model", "Appearance does not establish the watch's age"],
    }
    value.update(updates)
    return value


def analyze_watch(value, **capture_updates):
    output = result(subject="Digital wristwatch", analysis=value, visual_attributes=["rectangular digital display"])
    return provider(lambda _: httpx.Response(200, json=envelope(output))).understand_capture(
        capture(title="My watch find", image_data_url="data:image/png;base64,iVBORw0KGgo=", **capture_updates))


def test_watch_subcategory_and_visual_style_preserve_uncertainty():
    output = analyze_watch(watch_analysis())
    observed = ProductAnalysis.model_validate(output["features"]["analysis"])
    watch = observed.products[0]
    assert watch.category_path[-1] == "Digital watches"
    assert watch.brand is None and watch.model is None
    assert watch.attributes[0].certainty == "observed"
    assert watch.attributes[1].certainty == "inferred"
    assert "digital watches" in analysis_terms(observed)
    assert "vintage-inspired" in analysis_terms(observed)
    assert "casio" not in analysis_terms(observed)
    assert "Appearance does not establish the watch's age" in observed.uncertainties


def test_readable_brand_and_model_are_attributed_to_image_evidence():
    value = watch_analysis()
    watch = value["products"][0]
    watch["brand"] = {"value": "Casio", "basis": "image", "evidence": "CASIO is printed above the display", "certainty": "observed"}
    watch["model"] = {"value": "F-91W", "basis": "image", "evidence": "F-91W label is visible below the display", "certainty": "observed"}
    parsed = analyze_watch(value)["features"]["analysis"]
    assert parsed["products"][0]["brand"]["basis"] == "image"
    assert "f-91w" in analysis_terms(parsed)


@pytest.mark.parametrize("identity", ["brand", "model"])
@pytest.mark.parametrize("failure", ["inferred", "unquoted_name", "unrelated_text"])
def test_brand_model_cannot_be_guessed_or_grounded_in_historical_context(identity, failure):
    value = watch_analysis()
    fact = {"value": "Casio", "basis": "image", "evidence": "Casio name is visible", "certainty": "observed"}
    if failure == "inferred":
        fact["certainty"] = "inferred"
    elif failure == "unquoted_name":
        fact["evidence"] = "The shape looks familiar"
    else:
        fact.update(basis="captured_text", evidence="Casio")
    value["products"][0][identity] = fact
    with pytest.raises(ProviderError, match="astra_invalid_analysis"):
        analyze_watch(value, confirmed_preferences=("Casio",))


def test_explicit_current_annotation_is_separate_from_historical_preferences():
    value = watch_analysis(intent_context=["The user is considering a gift"])
    value["products"][0]["brand"] = {
        "value": "Casio", "basis": "user_note", "evidence": "It is a Casio", "certainty": "observed",
    }
    def handle(request):
        body = json.loads(request.content)
        data = json.loads(body["input"][0]["content"][0]["text"])
        assert data["confirmed_annotations"] == ["It is a Casio", "A gift for a friend"]
        assert data["confirmed_preferences"] == ["I usually like analog Rolex watches"]
        assert "Historical confirmed_preferences may\nrank annotation actions ONLY" in body["instructions"]
        return httpx.Response(200, json=envelope(result(analysis=value)))
    output = provider(handle).understand_capture(capture(
        image_data_url="data:image/png;base64,iVBORw0KGgo=", note="",
        confirmed_annotations=("It is a Casio", "A gift for a friend"),
        confirmed_preferences=("I usually like analog Rolex watches",),
    ))
    assert output["features"]["analysis"]["products"][0]["brand"]["value"] == "Casio"
    assert "rolex" not in analysis_terms(output["features"]["analysis"])


def test_captured_text_fact_must_quote_current_title_or_selected_text():
    value = result()
    value["analysis"]["products"][0]["brand"] = {
        "value": "Acme", "basis": "captured_text", "evidence": "Acme reading lamp", "certainty": "observed",
    }
    output = provider(lambda _: httpx.Response(200, json=envelope(value))).understand_capture(
        capture(title="Acme reading lamp", note=""))
    assert output["features"]["analysis"]["products"][0]["brand"]["value"] == "Acme"


def test_image_fact_requires_image_and_personal_intent_requires_current_explicit_context():
    with pytest.raises(ProviderError, match="astra_invalid_analysis"):
        provider(lambda _: httpx.Response(200, json=envelope(result(analysis=watch_analysis())))).understand_capture(capture())
    value = result()
    value["analysis"]["intent_context"] = ["The user wants to purchase this"]
    with pytest.raises(ProviderError, match="astra_unconfirmed_intent_context"):
        provider(lambda _: httpx.Response(200, json=envelope(value))).understand_capture(capture(note="", confirmed_annotations=()))


def test_multiple_products_and_unknown_content_have_distinct_supported_shapes():
    value = watch_analysis()
    value["products"].append({
        "product_type": "Bracelet", "category_path": ["Accessories", "Jewelry", "Bracelets"],
        "brand": None, "model": None, "attributes": [], "use_cases": ["Adornment"], "search_terms": ["bracelet"],
    })
    assert len(analyze_watch(value)["features"]["analysis"]["products"]) == 2
    unknown = result(content_kind="unclear", analysis={"schema_version": 1, "summary": "No product can be identified",
        "products": [], "intent_context": [], "uncertainties": ["Subject is not sufficiently clear"]})
    output = provider(lambda _: httpx.Response(200, json=envelope(unknown))).understand_capture(capture())
    assert output["features"]["analysis"]["products"] == []
    assert analysis_terms(output["features"]["analysis"]) == []


@pytest.mark.parametrize("bad", ["too_many_products", "too_deep_category", "oversized_attribute", "unknown_field", "duplicate_attributes", "wrong_schema", "boolean_schema"])
def test_product_analysis_is_bounded_and_strict(bad):
    value = watch_analysis()
    if bad == "too_many_products":
        value["products"] *= 5
    elif bad == "too_deep_category":
        value["products"][0]["category_path"] = [f"level-{i}" for i in range(7)]
    elif bad == "oversized_attribute":
        value["products"][0]["attributes"][0]["value"] = "x" * 81
    elif bad == "unknown_field":
        value["verified_price"] = 100
    elif bad == "duplicate_attributes":
        value["products"][0]["attributes"].append(deepcopy(value["products"][0]["attributes"][0]))
    elif bad == "wrong_schema":
        value["schema_version"] = 2
    else:
        value["schema_version"] = True
    with pytest.raises(ProviderError, match="astra_invalid_analysis"):
        analyze_watch(value)


def test_library_terms_are_normalized_and_do_not_promote_intent_to_product_fact():
    value = watch_analysis(intent_context=["Buy a gift tomorrow"])
    terms = analysis_terms(value)
    assert len(terms) == len(set(terms))
    assert "digital watches" in terms
    assert "buy a gift tomorrow" not in terms
    assert analysis_terms({"schema_version": 0, "summary": "legacy"}) == []


def test_analysis_schema_is_embedded_and_strict_at_every_object():
    def handle(request):
        schema = json.loads(request.content)["text"]["format"]["schema"]["properties"]["analysis"]
        def verify(node):
            if isinstance(node, list):
                for child in node:
                    verify(child)
            elif isinstance(node, dict):
                assert "$ref" not in node
                if node.get("type") == "object":
                    assert node["additionalProperties"] is False
                    assert set(node["required"]) == set(node["properties"])
                for child in node.values():
                    verify(child)
        verify(schema)
        return httpx.Response(200, json=envelope())
    provider(handle).understand_capture(capture())
