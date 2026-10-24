"""Source-isolated catalog retrieval with reasons tied to current private saves.

Astra analyzes the user's capture. Catalog matching happens locally; licensed
catalog content is never sent to a model by this service. Scores are bounded
retrieval heuristics, not probabilities or claims of purchase intent.
"""
from __future__ import annotations

from dataclasses import dataclass
import re
import time
from typing import Literal

from pydantic import BaseModel, ConfigDict, ValidationError
from sqlalchemy import func, select
from sqlalchemy.orm import load_only

from .catalog.registry import SOURCES
from .catalog.schemas import CatalogRecord, SourceID, public_url
from .catalog.search_index import matching_product_ids
from .catalog.service import CatalogError, visible_records
from .db import CatalogFeed, CatalogProduct, Evidence, SavedItem, UserState
from .understanding import ProductAnalysis


CANDIDATE_LIMIT = 500
PROFILE_LIMIT = 24
QUERY_LIMIT = 12
RANKING_VERSION = "facet-match-v1"
_INTENTS = {"buy_intent", "track_discount", "remind_later", "save_inspiration", "inspiration_only", "compare_options"}
_GENERIC = {"product", "item", "accessory", "fashion", "electronics", "home", "garden", "goods", "object", "other"}
_ALIASES = {"wristwatch": "watch", "wristwatches": "watch", "watches": "watch", "watch": "watch",
            "accessories": "accessory", "boxes": "box", "men": "man", "women": "woman"}


class ExploreContract(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


class ExploreReason(ExploreContract):
    kind: Literal["category_match", "attribute_match", "brand_match", "confirmed_intent", "query_match"]
    text: str
    saved_item_id: str | None = None
    saved_item_title: str | None = None
    saved_item_revision: int | None = None
    analysis_path: str | None = None
    evidence_id: str | None = None
    matched_value: str
    catalog_field: str | None = None
    catalog_value: str | None = None


class CatalogCitation(ExploreContract):
    source_id: SourceID
    record_id: str
    title: str
    license_id: str | None
    license_url: str | None
    attribution: str | None
    record_url: str | None


class ExploreItem(ExploreContract):
    product: CatalogRecord
    score: float
    score_kind: Literal["heuristic_match"] = "heuristic_match"
    reasons: list[ExploreReason]
    catalog_citation: CatalogCitation
    action: Literal["view_offer", "view_source"]
    action_url: str | None


class ExplorePage(ExploreContract):
    items: list[ExploreItem]
    source_id: SourceID
    query: str
    mode: Literal["personalized", "search"]
    status: Literal["ready", "needs_saves", "needs_analysis", "no_matches"]
    next_offset: int | None
    candidate_count: int
    candidate_limit: int = CANDIDATE_LIMIT
    candidate_window_limited: bool
    personalized_from_saves: int
    profile_limit: int = PROFILE_LIMIT
    profile_window_limited: bool
    context_version: int
    generated_at: float
    ranking_version: str = RANKING_VERSION
    expires_at: float | None


@dataclass(frozen=True)
class Facet:
    path: str
    value: str
    kind: str
    weight: float


@dataclass(frozen=True)
class Profile:
    item_id: str
    title: str
    revision: int
    anchor: tuple[Facet, ...]
    facets: tuple[Facet, ...]
    intent_id: str | None = None
    intent: str | None = None


def _tokens(value):
    values = re.findall(r"[^\W_]+", value.casefold(), flags=re.UNICODE)
    result = []
    for token in values:
        token = _ALIASES.get(token, token)
        if len(token) > 4 and token.endswith("ies"):
            token = token[:-3] + "y"
        elif len(token) > 3 and token.endswith("s") and not token.endswith(("ss", "us", "is")):
            token = token[:-1]
        if token not in {"a", "an", "the", "of", "and", "for", "with"}:
            result.append(token)
    return tuple(dict.fromkeys(result))


def _profiles(db, user_id):
    rows = db.scalars(select(SavedItem).options(load_only(SavedItem.id, SavedItem.user_id, SavedItem.title,
        SavedItem.revision, SavedItem.features, SavedItem.captured_at, SavedItem.status, SavedItem.deleted)).where(SavedItem.user_id == user_id, SavedItem.deleted.is_(False),
        SavedItem.status == "ready").order_by(SavedItem.captured_at.desc(), SavedItem.id).limit(PROFILE_LIMIT + 1)).all()
    truncated = len(rows) > PROFILE_LIMIT
    rows = rows[:PROFILE_LIMIT]
    item_ids = [item.id for item in rows]
    intentions = {}
    if item_ids:
        for evidence in db.scalars(select(Evidence).where(Evidence.user_id == user_id,
                Evidence.item_id.in_(item_ids), Evidence.active.is_(True),
                Evidence.origin.in_(["confirmed_annotation", "explicit_statement"]), Evidence.claim.in_(_INTENTS))
                .order_by(Evidence.observed_at.desc(), Evidence.id)):
            intentions.setdefault(evidence.item_id, (evidence.id, evidence.claim))
    profiles, analyzed_items = [], set()
    for item in rows:
        try:
            analysis = ProductAnalysis.model_validate(item.features.get("analysis"))
        except (ValidationError, TypeError, ValueError):
            continue
        analyzed_items.add(item.id)
        for index, product in enumerate(analysis.products):
            base = f"products.{index}"
            anchors = [Facet(base + ".product_type", product.product_type, "category_match", 8)]
            if product.category_path:
                leaf = product.category_path[-1]
                if set(_tokens(leaf)) - _GENERIC:
                    anchors.append(Facet(base + f".category_path.{len(product.category_path) - 1}", leaf, "category_match", 10))
            facets = list(anchors)
            for attribute_index, attribute in enumerate(product.attributes):
                facets.append(Facet(base + f".attributes.{attribute_index}.value", attribute.value, "attribute_match", 4))
            if product.brand and product.brand.certainty == "observed":
                facets.append(Facet(base + ".brand.value", product.brand.value, "brand_match", 6))
            intent_id, intent = intentions.get(item.id, (None, None))
            profiles.append(Profile(item.id, item.title, item.revision, tuple(anchors), tuple(facets), intent_id, intent))
    return profiles, len(analyzed_items), truncated


def _candidate_queries(profiles, query):
    if query:
        return [query], False
    queries = []
    # A specific category is tried before its broad type, so a large source
    # does not fill the candidate window with arbitrary low-specificity rows.
    for profile in profiles:
        product_tokens = _tokens(profile.anchor[0].value)
        for facet in profile.facets:
            if facet.kind != "brand_match":
                continue
            value = " ".join(dict.fromkeys((*product_tokens, *_tokens(facet.value))))[:100]
            if value and value not in queries:
                queries.append(value)
        for facet in reversed(profile.anchor):
            tokens = _tokens(facet.value)
            if not tokens or not (set(tokens) - _GENERIC):
                continue
            value = " ".join(tokens)[:100]
            if value not in queries:
                queries.append(value)
    return queries[:QUERY_LIMIT], len(queries) > QUERY_LIMIT


def _candidates(db, source_id, queries, now):
    candidates, limited = {}, False
    per_query = max(1, CANDIDATE_LIMIT // max(1, len(queries)))
    for query in queries:
        selection = visible_records(source_id, now)
        indexed = matching_product_ids(db, query)
        if indexed is not None:
            selection = selection.where(CatalogProduct.id.in_(indexed))
        else:
            for term in query.casefold().split():
                selection = selection.where(CatalogProduct.search_text.contains(term, autoescape=True))
        rows = db.scalars(selection.order_by(CatalogProduct.id).limit(per_query + 1)).all()
        limited = limited or len(rows) > per_query
        for row in rows[:per_query]:
            candidates[row.id] = row.record
    return candidates, limited


def _catalog_fields(record):
    fields = []
    for key in ("title", "category", "brand", "description"):
        value = record.get(key)
        if isinstance(value, str) and value.strip():
            fields.append((key, value))
    for key, value in list(record.get("attributes", {}).items())[:32]:
        if isinstance(value, str):
            fields.append((f"attributes.{key}", value))
        elif isinstance(value, list):
            for index, entry in enumerate(value[:12]):
                if isinstance(entry, str):
                    fields.append((f"attributes.{key}.{index}", entry))
    return [(name, value, set(_tokens(value))) for name, value in fields]


def _match(value, fields, *, prefix=False):
    tokens = set(_tokens(value))
    if not tokens or not (tokens - _GENERIC):
        return None
    for name, field_value, field_tokens in fields:
        if tokens.issubset(field_tokens) or prefix and all(any(word.startswith(token) for word in field_tokens) for token in tokens):
            # Keep the citation an exact source excerpt, even for descriptions.
            start = min((field_value.casefold().find(token) for token in tokens if token in field_value.casefold()), default=0)
            start = max(0, start - 60) if len(field_value) > 300 else 0
            return name, field_value[start:start + 300]
    return None


def _profile_match(profile, fields):
    # Avoid recommending a watch-storage box or replacement strap solely
    # because its catalog category contains the word watch.
    product_tokens = set(_tokens(profile.anchor[0].value))
    category_tokens = set().union(*(tokens for name, _, tokens in fields if name == "category"))
    accessories = {"box", "case", "strap", "band", "winder", "holder", "stand", "organizer"}
    if "watch" in product_tokens and not product_tokens.intersection(accessories) and category_tokens.intersection(accessories):
        return 0, []
    if not any(_match(anchor.value, fields) for anchor in profile.anchor):
        return 0, []
    score, reasons, seen = 0, [], set()
    for facet in profile.facets:
        match = _match(facet.value, [field for field in fields if field[0] == "brand"] if facet.kind == "brand_match" else fields)
        signature = (facet.kind, _tokens(facet.value))
        if not match or signature in seen:
            continue
        seen.add(signature)
        name, value = match
        score += facet.weight
        reasons.append(ExploreReason(kind=facet.kind,
            text=f"Matches {facet.value!r} detected in your saved {profile.title!r}.",
            saved_item_id=profile.item_id, saved_item_title=profile.title, saved_item_revision=profile.revision,
            analysis_path=facet.path, matched_value=facet.value, catalog_field=name, catalog_value=value))
    if profile.intent in {"buy_intent", "track_discount", "compare_options"}:
        text = {"buy_intent": "You marked this saved item as something you would like to buy.",
                "track_discount": "You marked this saved item for possible discount tracking.",
                "compare_options": "You asked to compare options for this saved item."}[profile.intent]
        score += 2
        reasons.append(ExploreReason(kind="confirmed_intent", text=text, saved_item_id=profile.item_id,
            saved_item_title=profile.title, saved_item_revision=profile.revision,
            evidence_id=profile.intent_id, matched_value=profile.intent))
    return score, reasons


def _source_link(record):
    for field in ("source_url", "record_url", "product_url", "original_url"):
        value = record.get("provenance", {}).get(field)
        if not isinstance(value, str):
            continue
        try:
            return public_url(value)
        except ValueError:
            continue
    return None


def explore(db, user_id, source_id, q="", limit=20, offset=0, now=None):
    """Return a bounded, auditable ranking within one explicitly selected source."""
    now = time.time() if now is None else now
    if source_id not in SOURCES:
        raise CatalogError("unknown_catalog_source", "Choose a registered catalog source")
    if (not isinstance(q, str) or len(q) > 100 or any(ord(char) < 32 for char in q)
            or type(limit) is not int or not 1 <= limit <= 50 or type(offset) is not int or not 0 <= offset < CANDIDATE_LIMIT):
        raise CatalogError("invalid_explore_query", "Use a query up to 100 characters, limit 1–50 and offset below 500")
    query = q.strip()
    enabled = db.scalar(select(func.count()).select_from(CatalogFeed).where(
        CatalogFeed.source_id == source_id, CatalogFeed.enabled.is_(True)))
    if not enabled:
        raise CatalogError("catalog_not_configured", "No catalog has been imported for this source")
    context_version = db.scalar(select(UserState.version).where(UserState.user_id == user_id)) or 0
    profiles, profile_count, profile_limited = _profiles(db, user_id)
    queries, query_limited = _candidate_queries(profiles, query)
    candidates, candidate_limited = _candidates(db, source_id, queries, now)
    candidate_limited = candidate_limited or query_limited
    source = SOURCES[source_id]
    ranked = []
    for identity, record in candidates.items():
        fields = _catalog_fields(record)
        matches = [_profile_match(profile, fields) for profile in profiles]
        # One strong saved product drives the ranking; a flood of similar saves
        # cannot inflate a candidate's score or invent a stronger preference.
        score, reasons = max(matches, key=lambda entry: entry[0], default=(0, []))
        if query:
            query_match = _match(query, fields, prefix=True)
            if query_match:
                name, value = query_match
                reasons.insert(0, ExploreReason(kind="query_match", text=f"Matches your search for {query!r}.",
                    matched_value=query, catalog_field=name, catalog_value=value))
                score += 1
            else:
                # Search terms can span source fields. Each cited term must
                # still occur in a field; raw FTS prefix hits alone are no proof.
                term_matches = [(term, _match(term, fields, prefix=True)) for term in _tokens(query)]
                if not term_matches or any(match is None for _, match in term_matches):
                    continue
                for term, (name, value) in term_matches:
                    reasons.insert(0, ExploreReason(kind="query_match", text=f"Your search term {term!r} occurs in this source record.",
                        matched_value=term, catalog_field=name, catalog_value=value))
                score += 1
        if not reasons:
            continue
        link = _source_link(record)
        live = record.get("data_kind") == "merchant_feed" and bool(record["offer"].get("url"))
        item = ExploreItem(product=CatalogRecord.model_validate(record), score=score, reasons=reasons[:18],
            catalog_citation=CatalogCitation(source_id=source_id, record_id=record["source_record_id"], title=record["title"],
                license_id=source.license_id, license_url=source.license_url, attribution=source.attribution, record_url=link),
            action="view_offer" if live else "view_source", action_url=record["offer"]["url"] if live else link)
        ranked.append((score, identity, item))
    ranked.sort(key=lambda value: (-value[0], value[1]))
    items = [item for _, _, item in ranked[offset:offset + limit]]
    next_offset = offset + limit if offset + limit < len(ranked) else None
    status = "ready" if items else "no_matches"
    if not query and not profiles and profile_count == 0:
        own_count = db.scalar(select(func.count()).select_from(SavedItem).where(SavedItem.user_id == user_id, SavedItem.deleted.is_(False)))
        status = "needs_analysis" if own_count else "needs_saves"
    # Read the scalar again rather than the Session identity map. A concurrent
    # deletion, annotation or analysis publication invalidates the citations
    # captured at the beginning of this request.
    current_version = db.scalar(select(UserState.version).where(UserState.user_id == user_id)) or 0
    if current_version != context_version:
        raise CatalogError("explore_context_changed", "Your saved content changed while recommendations were loading. Refresh to use current context.")
    return ExplorePage(items=items, source_id=source_id, query=query, mode="search" if query else "personalized",
        status=status, next_offset=next_offset, candidate_count=len(candidates), candidate_window_limited=candidate_limited,
        personalized_from_saves=profile_count, profile_window_limited=profile_limited,
        context_version=context_version, generated_at=now,
        expires_at=min((item.product.offer.expires_at for item in items if item.product.offer.expires_at is not None), default=None)).model_dump()
