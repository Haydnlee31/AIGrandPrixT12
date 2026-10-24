"""Private local-first recommendations from actual licensed catalog records.

The caller supplies the current saved-find context. It is neither written to the
catalog nor sent to a model. GPT capture analysis supplies the product facets;
retrieval and explanations are deterministic and retain exact source identities.
No fixture/synthetic product, current offer or price is fabricated as a fallback.
"""
from __future__ import annotations

from pathlib import Path
import re
import sqlite3
import threading
import time
from typing import Annotated, Literal

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator
from sqlalchemy import create_engine, func, or_, select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import sessionmaker

from .catalog.registry import SOURCES
from .catalog.schemas import public_url
from .catalog.search_index import matching_product_ids
from .catalog.recommendation_index import category_product_ids
from .db import CatalogFeed, CatalogProduct
from .explore import Facet, Profile, _candidate_queries, _catalog_fields, _match, _profile_match, _tokens

ROOT = Path(__file__).resolve().parents[2]
CATALOG_PATH = ROOT / "local-data" / "recommendation-catalog.db"
ELIGIBLE_SOURCES = tuple(key for key, source in SOURCES.items() if source.kind == "open_dataset")
SOURCE_URLS = {"abo": "https://registry.opendata.aws/amazon-berkeley-objects/", "wands": "https://github.com/wayfair/WANDS",
               "open_beauty_facts": "https://world.openbeautyfacts.org/", "open_products_facts": "https://world.openproductsfacts.org/",
               "open_food_facts": "https://world.openfoodfacts.org/", "uci_retail": "https://archive.ics.uci.edu/dataset/502/online+retail+ii"}
MAX_FINDS = 24
_GENERIC = {"product", "item", "object", "accessory", "accessories", "fashion", "home", "garden", "electronic", "electronics", "goods", "other"}
_STOP = {"i", "my", "a", "an", "the", "this", "that", "it", "like", "love", "want", "need", "looking", "look", "for", "and", "or", "to", "of", "with", "would", "something", "similar", "one", "find", "save", "as", "is", "are", "me", "more", "prefer", "please", "color", "colour", "design", "style", "quality", "price"}
_NOUNS = {"wristwatch": "watch", "wristwatches": "watch", "watches": "watch", "smartphone": "phone", "smartphones": "phone", "mobilephone": "phone", "couch": "sofa", "couches": "sofa", "sneakers": "shoe", "sneaker": "shoe", "headphone": "headphone", "earbuds": "earbud"}


class Contract(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False, str_strip_whitespace=True)


Short = Annotated[str, StringConstraints(min_length=1, max_length=100)]
Intent = Annotated[str, StringConstraints(min_length=1, max_length=500)]


class FindAnalysis(Contract):
    # A client can pass its complete capture-preview result. Only bounded,
    # shopping-relevant facets are read here; prompts are never user choices.
    model_config = ConfigDict(extra="ignore", allow_inf_nan=False, str_strip_whitespace=True)
    product_name: Short | None = None
    category_path: list[Short] = Field(default_factory=list, max_length=6)
    brand: Short | None = None
    style: list[Short] = Field(default_factory=list, max_length=8)
    summary: str = Field(default="", max_length=600)


class RecommendationFind(Contract):
    id: str = Field(min_length=1, max_length=128)
    title: str = Field(min_length=1, max_length=300)
    note: str = Field(default="", max_length=2000)
    text: str = Field(default="", max_length=12000)
    intents: list[Intent] = Field(default_factory=list, max_length=8)
    analysis: FindAnalysis | None = None


class RecommendationRequest(Contract):
    finds: list[RecommendationFind] = Field(default_factory=list, max_length=MAX_FINDS)
    query: str = Field(default="", max_length=100)
    limit: int = Field(default=24, strict=True, ge=1, le=50)

    @model_validator(mode="after")
    def distinct_finds(self):
        if len({find.id for find in self.finds}) != len(self.finds):
            raise ValueError("Find identities must be unique")
        return self


class RecommendationReason(Contract):
    find_id: str
    find_title: str
    text: str
    matched_value: str


class RecommendationItem(Contract):
    id: str
    title: str
    image_url: str | None
    source_id: str
    source_record_id: str
    source_name: str
    source_url: str
    license_url: str | None
    attribution: str | None
    product_url: str | None = None
    price_minor: int | None = None
    currency: str | None = None
    availability: Literal["unknown"] = "unknown"
    reasons: list[RecommendationReason]
    score: float


class RecommendationResult(Contract):
    status: Literal["ready", "needs_saves", "needs_analysis", "no_matches", "catalog_unavailable"]
    items: list[RecommendationItem]
    catalog_count: int
    query: str
    generated_at: float


def _https_url(value):
    if not isinstance(value, str) or not value.startswith("https://"):
        return None
    try:
        return public_url(value)
    except ValueError:
        return None


def _type(value):
    words = [_NOUNS.get(token, token) for token in _tokens(value)]
    meaningful = [token for token in words if token not in _GENERIC and token not in _STOP]
    return meaningful[-1] if meaningful else None


def _profile(find):
    analysis = find.analysis
    if analysis is None or not analysis.product_name:
        return None
    categories = [category for category in analysis.category_path if _type(category)]
    # Leaf category nouns keep a richly described photo ("small silver retro
    # digital wristwatch") from requiring every adjective in the catalog title.
    product_type = _type(categories[-1]) if categories else _type(analysis.product_name)
    if not product_type:
        return None
    anchors = [Facet("product_name", product_type, "category_match", 8)]
    if categories:
        anchors.append(Facet("category_path", categories[-1], "category_match", 10))
    facets = list(anchors)
    if analysis.brand:
        facets.append(Facet("brand", analysis.brand, "brand_match", 5))
    for style in analysis.style:
        # A multiword visual description can still provide an individual color
        # or shape match; each reason cites only the word actually present.
        for word in _tokens(style):
            if word not in _STOP and word not in _GENERIC and len(word) > 2:
                facets.append(Facet("style", word, "attribute_match", 3))
    return Profile(find.id, find.title, 1, tuple(anchors), tuple(facets))


def _intent_terms(find):
    text = " ".join([find.note, *find.intents]).casefold()
    excluded = set()
    for match in re.finditer(r"\b(?:no|not|without|avoid|exclude)\s+([\w-]+)", text):
        excluded.update(_tokens(match.group(1)))
    terms = [term for term in _tokens(text) if term not in _STOP and term not in _GENERIC
             and term not in excluded and term not in {"no", "not", "without", "avoid", "exclude"} and len(term) > 2 and not term.isdigit()]
    return list(dict.fromkeys(terms))[:16], excluded


def _matches_query(query, fields):
    return not query or all(_match(token, fields, prefix=True) for token in _tokens(query))


def _category_compatible(profile, record):
    """A contextual mention of a watch/phone cannot turn furniture into one."""
    wanted = profile.anchor[0].value
    category = {_NOUNS.get(word, word) for word in _tokens(record.get("category") or "")}
    accessories = {"case", "strap", "band", "box", "winder", "holder", "stand", "organizer", "accessory", "protector", "charger", "mount"}
    if wanted in {"watch", "phone"}:
        # ABO includes generic HOME rows that mention watches in a description
        # (including cushions and separate straps). For these high-ambiguity
        # product types insist on an actual matching catalog category.
        if wanted not in category or category.intersection(accessories):
            return False
        title = (record.get("title") or "").casefold()
        if wanted == "watch" and re.search(r"\bwatch(?:es)?\s*(?:/|and)?\s*(?:band|box|holder|winder|strap|case)\b", title):
            return False
        if wanted == "phone" and set(_tokens(title)).intersection(accessories):
            return False
    if category - _GENERIC and wanted not in category:
        return False
    return True


def _candidates(db, profiles, queries, now):
    # Constrain the category before the candidate window. The ABO corpus has
    # >64k phone-case records; slicing an unrestricted phone search first would
    # hide the real phones behind accessories even if filtering later is right.
    category = func.lower(CatalogProduct.record["category"].as_string())
    anchors = list(dict.fromkeys(profile.anchor[0].value for profile in profiles))
    category_ids = category_product_ids(db, anchors)
    compatible = CatalogProduct.id.in_(category_ids) if category_ids is not None else or_(*(category.contains(anchor, autoescape=True) for anchor in anchors))
    candidates = {}
    per_query = max(20, 500 // max(1, len(queries)))
    for query in queries:
        selection = _visible().where(compatible)
        indexed = matching_product_ids(db, query)
        if indexed is not None:
            selection = selection.where(CatalogProduct.id.in_(indexed))
        else:
            for word in query.casefold().split():
                selection = selection.where(CatalogProduct.search_text.contains(word, autoescape=True))
        for row in db.scalars(selection.order_by(CatalogProduct.id).limit(per_query)).all():
            candidates[row.id] = row.record
    return candidates


def _visible():
    return select(CatalogProduct).join(CatalogFeed).where(CatalogFeed.source_id.in_(ELIGIBLE_SOURCES), CatalogFeed.enabled.is_(True))


def recommend(factory, request: RecommendationRequest, now=None) -> RecommendationResult:
    now = time.time() if now is None else now
    result = dict(items=[], catalog_count=0, query=request.query, generated_at=now)
    if not request.finds:
        return RecommendationResult(status="needs_saves", **result)
    if factory is None:
        return RecommendationResult(status="catalog_unavailable", **result)
    profiles = [(find, _profile(find)) for find in request.finds]
    profiles = [(find, profile) for find, profile in profiles if profile is not None]
    with factory() as db:
        enabled = db.scalar(select(func.count()).select_from(CatalogFeed).where(CatalogFeed.source_id.in_(ELIGIBLE_SOURCES),
                                                                              CatalogFeed.enabled.is_(True)))
        if not enabled:
            return RecommendationResult(status="catalog_unavailable", **result)
        result["catalog_count"] = db.scalar(select(func.count()).select_from(_visible().subquery())) or 0
        if not profiles:
            return RecommendationResult(status="needs_analysis", **result)
        queries, _ = _candidate_queries([profile for _, profile in profiles], "")
        # Put user's concrete current preferences in candidate retrieval too,
        # not only reranking an arbitrary slice of the broad product category.
        preference_queries = []
        for find, profile in profiles:
            terms, _ = _intent_terms(find)
            for term in terms[:4]:
                preference_queries.append(f"{profile.anchor[0].value} {term}"[:100])
        queries = list(dict.fromkeys([*preference_queries[:6], *queries]))[:16]
        if request.query:
            queries = [request.query]
        candidates = _candidates(db, [profile for _, profile in profiles], queries, now)
        ranked = []
        seen_products = set()
        for identity, record in candidates.items():
            if record.get("data_kind") != "open_dataset" or record.get("source_id") not in ELIGIBLE_SOURCES:
                continue
            fields = _catalog_fields(record)
            if not _matches_query(request.query, fields):
                continue
            matches = []
            for find, profile in profiles:
                if not _category_compatible(profile, record):
                    continue
                terms, excluded = _intent_terms(find)
                if any(_match(word, fields) for word in excluded):
                    continue
                score, evidence = _profile_match(profile, fields)
                if not evidence:
                    continue
                reasons = [RecommendationReason(find_id=find.id, find_title=find.title,
                    text=f"Similar to the {reason.matched_value.lower()} in your find.", matched_value=reason.matched_value)
                    for reason in evidence[:3]]
                for term in terms:
                    match = _match(term, fields)
                    if match:
                        score += 5
                        reasons.insert(0, RecommendationReason(find_id=find.id, find_title=find.title,
                            text=f"Matches your interest in {term}.", matched_value=term))
                matches.append((score, reasons))
            if not matches:
                continue
            score, reasons = max(matches, key=lambda match: match[0])
            source_id = record["source_id"]
            source = SOURCES[source_id]
            # Prefer an available English source title without rewriting or
            # translating it into an invented product description.
            if str(record.get("provenance", {}).get("title_language") or "").startswith("en"):
                score += 1
            if _https_url(record.get("offer", {}).get("image_url")):
                score += 0.5
            # Same ASIN appears in different marketplaces in ABO. Show it once
            # while preserving the chosen source-scoped identity and attribution.
            product_identity = (source_id, record.get("provenance", {}).get("original_item_id") or record["source_record_id"])
            ranked.append((score, identity, product_identity, RecommendationItem(
                id=identity, title=record["title"], image_url=_https_url(record.get("offer", {}).get("image_url")),
                source_id=source_id, source_record_id=record["source_record_id"], source_name=source.name,
                source_url=_https_url(record.get("provenance", {}).get("source_url")) or SOURCE_URLS[source_id],
                license_url=source.license_url, attribution=source.attribution,
                reasons=reasons[:4], score=score)))
        ranked.sort(key=lambda entry: (-entry[0], entry[1]))
        # Retain representation from different actual saves: a richly analyzed
        # watch must not bury every phone result when both were saved. Within
        # each find, the best matching sourced products still come first.
        groups = {}
        for entry in ranked:
            groups.setdefault(entry[3].reasons[0].find_id, []).append(entry)
        while any(groups.values()) and len(result["items"]) < request.limit:
            for entries in groups.values():
                while entries:
                    _, _, product_identity, item = entries.pop(0)
                    if product_identity in seen_products:
                        continue
                    seen_products.add(product_identity)
                    result["items"].append(item)
                    break
                if len(result["items"]) >= request.limit:
                    break
        return RecommendationResult(status="ready" if result["items"] else "no_matches", **result)


class LocalRecommendationService:
    def __init__(self, factory=None, path=CATALOG_PATH):
        self.factory = factory
        self.path = Path(path)
        self.engine = None
        self.lock = threading.Lock()
        self.capacity = threading.BoundedSemaphore(4)

    def _factory(self):
        # A catalog downloaded while the relay is running becomes available on
        # the next request; no server reboot or app rebuild is necessary.
        with self.lock:
            if self.factory is None and self.path.is_file():
                uri = self.path.resolve().as_uri() + "?mode=ro"
                self.engine = create_engine("sqlite://", creator=lambda: sqlite3.connect(uri, uri=True, check_same_thread=False, timeout=5))
                self.factory = sessionmaker(self.engine, expire_on_commit=False)
            return self.factory

    def recommendations(self, request):
        if not self.capacity.acquire(blocking=False):
            return JSONResponse({"error": {"code": "recommendations_busy", "message": "Recommendations are busy. Try again shortly.", "retryable": True}},
                                status_code=503, headers={"Cache-Control": "no-store"})
        try:
            try:
                result = recommend(self._factory(), request)
            except (SQLAlchemyError, sqlite3.Error):
                result = RecommendationResult(status="catalog_unavailable", items=[], catalog_count=0,
                                              query=request.query, generated_at=time.time())
            return JSONResponse(result.model_dump(), headers={"Cache-Control": "no-store"})
        finally:
            self.capacity.release()


def register_recommendations(app: FastAPI, factory=None):
    service = LocalRecommendationService(factory)
    app.state.recommendation_service = service

    @app.post("/v1/recommendations", response_model=RecommendationResult)
    def recommendations(request: RecommendationRequest):
        return service.recommendations(request)
