"""Public v1 response contracts. Client apps must not depend on ORM internals."""
from __future__ import annotations
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field


class Response(BaseModel):
    model_config = ConfigDict(extra="ignore")


class APIErrorDetail(Response):
    code: str
    message: str
    retryable: bool
    request_id: str
    current: DiscoveryView | None = None


class ErrorEnvelope(Response):
    error: APIErrorDetail


class Health(Response):
    status: str
    demo_mode: bool
    inference_provider: str


class Identity(Response):
    user_id: str
    demo_mode: bool
    inference_provider: str


class CaptureCapabilities(Response):
    clients: list[str]
    content_types: list[str]
    max_url_length: int
    max_title_length: int
    max_selected_text_length: int
    max_note_length: int
    max_image_bytes: int = 4194304


class Capabilities(Response):
    api_version: str
    contract_version: str
    authentication: str
    capture: CaptureCapabilities
    data_modes: dict[str, str]
    features: dict[str, bool]
    currencies: list[str]
    refresh: dict[str, Any]


class CaptureResult(Response):
    id: str
    status: Literal["pending", "ready", "enrichment_failed"]
    duplicate: bool


class SuggestionView(Response):
    id: str
    item_id: str
    kind: str
    text: str
    claim: str
    model_version: str
    status: Literal["proposed"]
    intent: Literal["buy_intent", "track_discount", "remind_later", "save_inspiration", "compare_options"] | None = None
    requires_confirmation: bool = True


class EventView(Response):
    id: str
    item_id: str | None
    event_type: str
    payload: dict[str, Any]
    occurred_at: float = Field(description="Unix timestamp in seconds (UTC)")


class SavedItemView(Response):
    id: str
    original_url: str
    canonical_url: str
    title: str
    source: str
    client: str
    selected_text: str
    note: str
    captured_at: float = Field(description="Server receive time, Unix seconds UTC")
    status: Literal["pending", "ready", "enrichment_failed"]
    features: dict[str, Any]
    revision: int
    suggestions: list[SuggestionView]
    responses: list[EventView]
    has_image: bool = False
    image_path: str | None = None


class CollectionPage(Response):
    items: list[SavedItemView]
    next_offset: int | None


class EvidenceView(Response):
    id: str
    item_id: str
    claim: str
    text: str
    origin: str
    relation: Literal["supports", "opposes_readiness", "unresolved"]


class DecisionView(Response):
    action_type: str
    evidence_ids: list[str]
    missing_information: list[str]
    reason_codes: list[str]
    context_version: int | None = None


class HypothesisView(Response):
    id: str
    goal: str
    support_score: float
    score_kind: str
    independent_saves: int
    readiness: str
    confirmed_preferences: list[str]
    evidence: list[EvidenceView]
    context_version: int
    status: Literal["suppressed", "invitable", "collecting"]
    decision: DecisionView


class Hypotheses(Response):
    items: list[HypothesisView]


class AnnotationResult(Response):
    intent: str | None = None
    execution_status: Literal["annotation_only"] = "annotation_only"
    event_id: str
    hypothesis: HypothesisView


class Preferences(Response):
    low_clutter: bool = False
    direction: Literal["warm", "focused"] | None = None
    budget_minor: int | None = None
    max_width_cm: int | None = None
    owned: list[str] = Field(default_factory=list)
    selected_variant: str | None = None


class ProductView(Response):
    variant_id: str
    name: str
    variant: str
    merchant: str
    price_minor: int
    currency: str
    width_cm: int
    style: str
    compact: bool
    in_stock: bool
    tradeoff: str
    source_record: str
    data_mode: str
    shipping_minor: int | None
    merchant_url: str | None


class RankedProduct(ProductView):
    fit_score: int
    explanation: str


class Catalog(Response):
    items: list[ProductView]
    data_mode: str


class DiscoveryView(Response):
    id: str
    version: int
    stage: Literal["exploring", "comparing", "ready", "paused", "dismissed", "handed_off"]
    preferences: Preferences
    evidence_ids: list[str]
    context_version: int
    created_at: float
    context_stale: bool
    products: list[RankedProduct]
    next_action: DecisionView


class Discoveries(Response):
    items: list[DiscoveryView]
    next_offset: int | None = None


class WatchView(Response):
    id: str
    variant_id: str
    currency: str
    target_minor: int
    enabled: bool
    rule_version: int
    below: bool
    episode: int
    last_price_minor: int | None
    last_checked_at: float | None
    price_basis: str = "item_price_excluding_shipping"
    data_mode: str = "simulated"


class Watches(Response):
    items: list[WatchView]
    next_offset: int | None = None


class QueuedPriceCheck(Response):
    job_id: str
    data_mode: str


class NotificationView(Response):
    id: str
    watch_id: str
    observation_id: str
    dedupe_key: str
    message: str
    delivery_status: str


class Notifications(Response):
    items: list[NotificationView]
    next_offset: int | None = None


class JobView(Response):
    id: str
    kind: str
    status: str
    attempts: int
    error: str | None


class TraceView(Response):
    hypothesis: HypothesisView
    jobs: list[JobView]
    provider: str
    catalog_mode: str
    tracking_mode: str


class Deleted(Response):
    deleted: bool


class Reset(Response):
    reset: bool


APIErrorDetail.model_rebuild()
ErrorEnvelope.model_rebuild()
