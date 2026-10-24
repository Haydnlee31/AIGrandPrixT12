"""Private local-first recommendations from actual licensed catalog records.

The caller supplies the current saved-find context. It is neither written to the
catalog nor sent to a model. GPT capture analysis supplies the product facets;
retrieval and explanations are deterministic and retain exact source identities.
No fixture/synthetic product, current offer or price is fabricated as a fallback.
"""
from __future__ import annotations

from pathlib import Path
from collections import OrderedDict
from concurrent.futures import Future, TimeoutError as FutureTimeout
import hashlib
import json
import re
import sqlite3
import threading
import time
from typing import Annotated, Literal

from fastapi import FastAPI
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator
from sqlalchemy import create_engine, func, or_, select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import sessionmaker

from .catalog.registry import SOURCES
from .catalog.schemas import public_url
from .catalog.search_index import matching_product_ids
from .catalog.recommendation_index import category_product_ids
from .amazon_catalog_identity import AMAZON_MARKETS, amazon_asin, amazon_record_identity
from .db import CatalogFeed, CatalogImport, CatalogProduct
from .explore import Facet, Profile, _candidate_queries, _catalog_fields, _match, _profile_match, _tokens

ROOT = Path(__file__).resolve().parents[2]
CATALOG_PATH = ROOT / "local-data" / "recommendation-catalog.db"
ELIGIBLE_SOURCES = ("abo",)
SOURCE_URLS = {"abo": "https://registry.opendata.aws/amazon-berkeley-objects/", "wands": "https://github.com/wayfair/WANDS",
               "open_beauty_facts": "https://world.openbeautyfacts.org/", "open_products_facts": "https://world.openproductsfacts.org/",
               "open_food_facts": "https://world.openfoodfacts.org/", "uci_retail": "https://archive.ics.uci.edu/dataset/502/online+retail+ii"}
MAX_FINDS = 24
CACHE_TTL_SECONDS = 60
CACHE_MAX_ENTRIES = 64
SMALL_CATEGORY_LIMIT = 1000
_GENERIC = {"product", "item", "object", "accessory", "accessories", "fashion", "home", "garden", "electronic", "electronics", "goods", "other"}
_STOP = {"i", "my", "a", "an", "the", "this", "that", "it", "like", "love", "want", "need", "looking", "look", "for", "and", "or", "to", "of", "with", "would", "something", "similar", "one", "find", "save", "as", "is", "are", "me", "more", "prefer", "please", "color", "colour", "design", "style", "quality", "price"}
_NOUNS = {"smartwatch": "watch", "smartwatche": "watch", "wristwatch": "watch", "wristwatches": "watch", "watches": "watch", "smartphone": "phone", "smartphones": "phone", "mobilephone": "phone", "couch": "sofa", "couches": "sofa", "sneakers": "shoe", "sneaker": "shoe", "headphone": "headphone", "earbuds": "earbud"}
_COLORS = {"black", "white", "blue", "brown", "silver", "gold", "red", "green", "pink", "purple", "yellow", "orange", "beige", "cream", "grey", "gray", "navy", "rose", "rose gold"}
_MATERIALS = {"leather", "steel", "titanium", "nylon", "resin", "ceramic", "silicone", "linen", "cotton", "wood", "wooden", "glass", "metal", "suede", "stainless steel"}
_STYLES = {"analog", "digital", "mechanical", "automatic", "vintage", "classic", "retro", "minimalist", "sporty", "rectangular", "square", "compact"}
_LOW_SIGNAL = {"dial", "strap", "face", "case", "display", "band", "wear", "everyday", "gift", "present", "round", "detail", "time", "timeless", "collection"}
_PARTS = {"strap": r"(?:strap|band|bracelet)", "dial": r"(?:dial|face)",
          "stitching": r"(?:stitching|stitches)", "case": r"case", "hands": r"hands?",
          "numerals": r"(?:numerals?|markers?)"}
_PART_MODIFIERS = "|".join(sorted(_COLORS | _MATERIALS | {
    "tone", "textured", "matte", "glossy", "synthetic", "polished", "brushed", "sunray", "arabic", "luminous"
}, key=len, reverse=True))


def _preference_weight(term):
    if term in _COLORS or term in _MATERIALS:
        return 12
    if term in _STYLES:
        return 8
    return 0.25 if term in _LOW_SIGNAL else 3


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
    original_url: str | None = Field(default=None, max_length=4096)
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


class CatalogReadinessSource(Contract):
    source_id: str
    record_count: int = Field(ge=0)


class CatalogReadiness(Contract):
    status: Literal["ready", "catalog_unavailable"]
    catalog_count: int = Field(ge=0)
    sources: list[CatalogReadinessSource]


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
        # The primary product type is a gate. A finer subtype is useful but
        # must not double-count the same words enough to override explicit
        # color/material choices made by the person.
        anchors.append(Facet("category_path", categories[-1], "category_match", 4))
    facets = list(anchors)
    if analysis.brand and not any("brand flexible" in value.casefold() for value in find.intents):
        facets.append(Facet("brand", analysis.brand, "brand_match", 5))
    for style in analysis.style:
        # A multiword visual description can still provide an individual color
        # or shape match; each reason cites only the word actually present.
        for word in _tokens(style):
            if word not in _STOP and word not in _GENERIC and len(word) > 2:
                facets.append(Facet("style", word, "attribute_match", _preference_weight(word) / 3))
    return Profile(find.id, find.title, 1, tuple(anchors), tuple(facets))


def _intent_terms(find):
    text = "; ".join([find.note, *find.intents]).casefold()
    excluded = set()
    negative = r"\b(?:(?:don['’]?t|do not)\s+(?:want|like)|anything but|no|not|without|avoid|exclude)\s+([^,;.!?]+)"
    for match in re.finditer(negative, text):
        phrase = re.split(r"\b(?:but|instead|prefer)\b", match.group(1), maxsplit=1)[0]
        if re.match(r"(?:only|just)\b", phrase):
            continue
        words = [word for word in _tokens(phrase) if word not in _STOP and word not in _GENERIC and not word.isdigit()]
        # "No leather strap" excludes leather, not every watch with any strap.
        precise = [word for word in words if word not in _LOW_SIGNAL]
        excluded.update(precise or words)
    terms = [term for term in _tokens(text) if term not in _STOP and term not in _GENERIC
             and term not in excluded and term not in {"no", "not", "without", "avoid", "exclude", "don", "but", "anything", "instead"} and len(term) > 2 and not term.isdigit()]
    return sorted(dict.fromkeys(terms), key=lambda term: -_preference_weight(term))[:16], excluded


def _mentions_part(text, term, part):
    # Keep the relationship in "black leather strap" / "Dial Color: Silver".
    # Nearby black numerals are not evidence of a black strap. Only bounded
    # adjective sequences are allowed, never arbitrary text between attributes.
    attribute, component = re.escape(term), _PARTS[part]
    before = rf"\b{attribute}\b(?:[\s-]+(?:{_PART_MODIFIERS})){{0,3}}[\s-]+{component}\b"
    after = rf"\b{component}(?:\s+(?:color|colour|material))?\s*(?::|\bis\b|\bin\b|\bof\b)\s*{attribute}\b"
    return bool(re.search(before, text, re.IGNORECASE) or re.search(after, text, re.IGNORECASE))


def _preference_context(find, terms):
    text = "; ".join([find.note, *find.intents])
    return {term: parts for term in terms if term in _COLORS or term in _MATERIALS
            if (parts := tuple(part for part in _PARTS if _mentions_part(text, term, part)))}


def _matched_parts(term, parts, fields):
    matched = []
    for part in parts:
        for name, value, _ in fields:
            # Structured source attributes may separate the part from its
            # value; an unqualified color field cannot identify a watch part.
            label = name.removeprefix("attributes.").split(".")[0].replace("_", " ")
            text = f"{label}: {value}" if name.startswith("attributes.") else value
            if _mentions_part(text, term, part):
                matched.append(part)
                break
    return matched


def _reason_text(term, *, confirmed=False, kind="attribute_match"):
    value = term.lower()
    if kind == "brand_match":
        return f"From {term}, the brand in your saved find."
    if kind == "category_match":
        return f"A similar {value} to explore from your find."
    if value in _COLORS:
        return f"A {value} option for the color you liked." if confirmed else f"A {value} option, like your saved find."
    if value in _MATERIALS:
        return f"Its product details mention {value}, a detail you liked."
    if value in _STYLES:
        style = value + "-inspired" if value in {"vintage", "retro"} else value
        article = "An" if style[0] in "aeiou" else "A"
        return f"{article} {style} style that matches your preference." if confirmed else f"{article} {style} style, like your saved find."
    return f"Matches your interest in {value}." if confirmed else "Echoes details in your saved find."


def _fields(record):
    fields = _catalog_fields(record)
    # Keep exact source wording for evidence, but align category matching with
    # the existing phone gate and its FTS aliases. No unrelated noun expansion.
    fields = [(name, value, {"phone" if token in {"smartphone", "mobilephone"} else token for token in tokens})
              if name == "category" else (name, value, tokens) for name, value, tokens in fields]
    # ABO keeps some factual attributes in localized {value: ...} arrays. Read
    # only these bounded source values, preserving their original wording.
    for name in ("color", "material", "style", "finish_type", "item_shape", "display_type"):
        entries = record.get("attributes", {}).get(name)
        if isinstance(entries, dict):
            entries = [entries]
        if isinstance(entries, list):
            for index, entry in enumerate(entries[:16]):
                value = entry.get("value") if isinstance(entry, dict) else None
                if isinstance(value, str) and value.strip():
                    fields.append((f"attributes.{name}.{index}.value", value[:512], set(_tokens(value[:512]))))
    return fields


def _matches_query(query, fields):
    return not query or all(_match(token, fields, prefix=True) for token in _tokens(query))


def _requires_mobile_phone(find):
    analysis = find.analysis
    context = " ".join([find.title, *find.intents,
        analysis.product_name or "" if analysis else "", *(analysis.category_path if analysis else [])])
    return bool(re.search(r"\b(?:smart[\s-]?phones?|iphones?\d*|mobile(?:[\s-]?phones?)?|cell(?:ular)?[\s-]?phones?|android)\b", context, re.IGNORECASE))


def _requires_smartwatch(find):
    analysis = find.analysis
    context = " ".join([find.title, *find.intents, analysis.product_name or "" if analysis else "",
                        *(analysis.category_path if analysis else [])])
    return bool(re.search(r"\b(?:smart[\s-]?watch(?:es)?|apple\s+watch|galaxy\s+watch)\b", context, re.IGNORECASE))


def _requires_digital_watch(find):
    analysis = find.analysis
    context = " ".join([*find.intents, analysis.product_name or "" if analysis else "",
                        *(analysis.category_path if analysis else [])])
    return bool(re.search(r"\bdigital\b", context, re.IGNORECASE)) and not bool(re.search(r"\banalog\b", context, re.IGNORECASE))


def _category_compatible(profile, record, *, requires_mobile_phone=False, requires_smartwatch=False,
                         requires_digital_watch=False):
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
        if wanted == "watch" and requires_smartwatch and not re.search(r"\b(?:smart[\s-]?watch(?:es)?|apple\s+watch|galaxy\s+watch)\b", title + " " + (record.get("category") or "")):
            return False
        if wanted == "watch" and requires_digital_watch and not re.search(r"\b(?:digital|lcd|led\s+display)\b", title + " " + (record.get("description") or "")):
            return False
        if wanted == "phone" and set(_tokens(title)).intersection(accessories):
            return False
        if wanted == "phone" and requires_mobile_phone:
            # A PHONE category also includes DECT sets and answering machines.
            # Their available photos must never make them smartphone matches.
            product_kind = (title + " " + (record.get("category") or "")).replace("_", " ")
            if re.search(r"\b(?:dect|land[\s-]?lines?|corded|cordless|answering[\s-]*machines?|(?:home|office|desktop)[\s-]+(?:tele)?phones?)\b", product_kind, re.IGNORECASE):
                return False
            if not re.search(r"\b(?:smart\s*phone|iphone|galaxy|pixel|android|cellular\s+phone|mobile\s+phone)\b", product_kind, re.IGNORECASE):
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
    identities = db.scalars(select(CatalogProduct.id).join(CatalogFeed).where(
        CatalogFeed.source_id.in_(ELIGIBLE_SOURCES), CatalogFeed.enabled.is_(True), compatible
    ).limit(SMALL_CATEGORY_LIMIT + 1)).all()
    if len(identities) <= SMALL_CATEGORY_LIMIT:
        # Read a small category once. Intersecting a broad text FTS set (65k
        # phone-case hits) separately for every preference is much slower than
        # ranking the few hundred actual phones/watches already identified.
        if not identities:
            return {}
        rows = db.execute(select(CatalogProduct.id, CatalogProduct.record).where(CatalogProduct.id.in_(identities))).all()
        return {identity: record for identity, record in rows}
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


def _catalog_snapshot(factory):
    if factory is None:
        return ("unavailable", 0, False)
    with factory() as db:
        rows = db.execute(select(CatalogFeed.id, CatalogFeed.enabled, CatalogFeed.last_import_id,
                                 CatalogImport.digest, CatalogImport.row_count).outerjoin(
            CatalogImport, CatalogImport.id == CatalogFeed.last_import_id
        ).where(CatalogFeed.source_id.in_(ELIGIBLE_SOURCES)).order_by(CatalogFeed.id)).all()
    signature = hashlib.sha256(json.dumps([tuple(row) for row in rows], separators=(",", ":")).encode()).hexdigest()
    # Import row counts belong to the same atomic catalog snapshot. Counting six
    # metadata rows avoids walking all 263k products on every Explore refresh.
    return (signature, sum(row.row_count or 0 for row in rows if row.enabled), any(row.enabled for row in rows))


def recommend(factory, request: RecommendationRequest, now=None, *, catalog_snapshot=None) -> RecommendationResult:
    now = time.time() if now is None else now
    result = dict(items=[], catalog_count=0, query=request.query, generated_at=now)
    if not request.finds:
        return RecommendationResult(status="needs_saves", **result)
    if factory is None:
        return RecommendationResult(status="catalog_unavailable", **result)
    profiles = [(find, _profile(find)) for find in request.finds]
    profiles = [(find, profile) for find, profile in profiles if profile is not None]
    preferences = {find.id: _intent_terms(find) for find, _ in profiles}
    contexts = {find.id: _preference_context(find, preferences[find.id][0]) for find, _ in profiles}
    mobile_phone_required = {find.id: _requires_mobile_phone(find) for find, _ in profiles}
    smartwatch_required = {find.id: _requires_smartwatch(find) for find, _ in profiles}
    digital_watch_required = {find.id: _requires_digital_watch(find) for find, _ in profiles}
    exact_asins = {find.id: amazon_asin(find.original_url) for find, _ in profiles}
    _, catalog_count, configured = catalog_snapshot or _catalog_snapshot(factory)
    with factory() as db:
        if not configured:
            return RecommendationResult(status="catalog_unavailable", **result)
        result["catalog_count"] = catalog_count
        if not profiles:
            return RecommendationResult(status="needs_analysis", **result)
        queries, _ = _candidate_queries([profile for _, profile in profiles], "")
        # Put user's concrete current preferences in candidate retrieval too,
        # not only reranking an arbitrary slice of the broad product category.
        preference_queries = []
        for find, profile in profiles:
            terms, _ = preferences[find.id]
            for term in [word for word in terms if _preference_weight(word) >= 3][:4]:
                preference_queries.append(f"{profile.anchor[0].value} {term}"[:100])
        queries = list(dict.fromkeys([*preference_queries[:6], *queries]))[:16]
        if request.query:
            queries = [request.query]
        candidates = _candidates(db, [profile for _, profile in profiles], queries, now)
        # An exact saved ASIN must not fall outside a broad category's bounded
        # candidate window. Reproduce the importer's source-scoped lookup key;
        # the result still passes identity, image, category and exclusion gates.
        exact_ids = ["abo:" + hashlib.sha256(json.dumps([asin, domain], separators=(",", ":")).encode()).hexdigest()
                     for asin in set(exact_asins.values()) if asin for domain in AMAZON_MARKETS]
        if exact_ids:
            for row in db.scalars(_visible().where(CatalogProduct.source_record_id.in_(exact_ids))).all():
                candidates[row.id] = row.record
        ranked = []
        seen_products = set()
        for identity, record in candidates.items():
            if record.get("data_kind") != "open_dataset" or record.get("source_id") not in ELIGIBLE_SOURCES:
                continue
            amazon_identity = amazon_record_identity(record)
            if amazon_identity is None:
                continue
            asin, product_url, image_url = amazon_identity
            fields = _fields(record)
            if not _matches_query(request.query, fields):
                continue
            matches = []
            for find, profile in profiles:
                if not _category_compatible(profile, record, requires_mobile_phone=mobile_phone_required[find.id],
                                            requires_smartwatch=smartwatch_required[find.id],
                                            requires_digital_watch=digital_watch_required[find.id]):
                    continue
                if re.search(r"\b(?:automatic|self.winding|mechanical)\b", find.title + " " + " ".join(find.intents), re.I) and re.search(r"\bdigital\b", record.get("title", ""), re.I):
                    continue
                terms, excluded = preferences[find.id]
                if any(_match(word, fields) for word in excluded):
                    continue
                score, evidence = _profile_match(profile, fields)
                if not evidence:
                    continue
                exact_product = exact_asins[find.id] == asin
                if exact_product:
                    score += 1000  # Exact source identity precedes similar alternatives.
                reason_options = {}
                # Shared subtypes such as digital cannot satisfy a requested
                # appearance such as silver and fill the page with wrong colors.
                physical = {term for term in terms if term in _COLORS or term in _MATERIALS}
                distinctive = physical or {term for term in terms if _preference_weight(term) >= 8}
                matched_distinctive = set()
                for reason in evidence:
                    # Internal taxonomy paths stay internal; the fallback is
                    # one plain product noun, not multiple category-tag chips.
                    value = profile.anchor[0].value if reason.kind == "category_match" else reason.matched_value
                    priority = 0 if reason.kind == "category_match" else 5 if reason.kind == "brand_match" else _preference_weight(value.lower()) / 3
                    signature = tuple(_tokens(value))
                    reason_options[signature] = (priority, RecommendationReason(find_id=find.id, find_title=find.title,
                        text=_reason_text(value, kind=reason.kind), matched_value=value))
                for term in terms:
                    if term == profile.anchor[0].value:
                        continue  # The product type is already a gate, not a distinguishing preference.
                    match = _match(term, fields)
                    parts = contexts[find.id].get(term)
                    matched_parts = _matched_parts(term, parts, fields) if parts else []
                    if parts and not matched_parts:
                        continue
                    if match:
                        if term in distinctive:
                            matched_distinctive.add(term)
                        priority = _preference_weight(term)
                        score += priority
                        value = f"{term} {matched_parts[0]}" if matched_parts else term
                        text = f"The {value} matches a detail you liked." if matched_parts else _reason_text(term, confirmed=True)
                        reason_options[tuple(_tokens(term))] = (priority, RecommendationReason(find_id=find.id, find_title=find.title,
                            text=text, matched_value=value))
                # When someone specifies concrete colors/materials/styles,
                # the category alone is not enough to fill a results page.
                if distinctive and not matched_distinctive and not exact_product and not request.query:
                    continue
                meaningful = [entry for entry in reason_options.values() if entry[0] > 0.5]
                ordered = sorted(meaningful or list(reason_options.values()), key=lambda entry: -entry[0])
                reasons, seen_text = [], set()
                if exact_product:
                    reasons.append(RecommendationReason(find_id=find.id, find_title=find.title,
                        text="The same Amazon product you saved.", matched_value=asin))
                for _, reason in ordered:
                    if reason.text not in seen_text:
                        reasons.append(reason)
                        seen_text.add(reason.text)
                    if len(reasons) == 3:
                        break
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
            # Same ASIN appears in different marketplaces in ABO. Show it once
            # while preserving the chosen source-scoped identity and attribution.
            product_identity = (source_id, record.get("provenance", {}).get("original_item_id") or record["source_record_id"])
            ranked.append((score, identity, product_identity, RecommendationItem(
                id=identity, title=record["title"], image_url=image_url, product_url=product_url,
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
    def __init__(self, factory=None, path=CATALOG_PATH, *, clock=time.monotonic, image_enricher=None):
        self.factory = factory
        self.path = Path(path)
        self.engine = None
        self.lock = threading.Lock()
        self.capacity = threading.BoundedSemaphore(4)
        self.clock = clock
        self.image_enricher = image_enricher
        self.cache: OrderedDict[str, tuple[float, bytes]] = OrderedDict()
        self.inflight: dict[str, Future] = {}
        self.opened_identity = None

    def _factory(self):
        # A catalog downloaded while the relay is running becomes available on
        # the next request; no server reboot or app rebuild is necessary.
        with self.lock:
            if self.factory is not None and self.engine is None:
                return self.factory  # Explicit test/host database factory.
            identity = None
            try:
                stat = self.path.stat()
                identity = (stat.st_dev, stat.st_ino)
            except FileNotFoundError:
                pass
            if self.engine is not None and identity != self.opened_identity:
                self.engine.dispose()
                self.engine, self.factory = None, None
                self.cache.clear()
            if self.factory is None and self.path.is_file():
                uri = self.path.resolve().as_uri() + "?mode=ro"
                self.engine = create_engine("sqlite://", creator=lambda: sqlite3.connect(uri, uri=True, check_same_thread=False, timeout=5))
                self.factory = sessionmaker(self.engine, expire_on_commit=False)
                self.opened_identity = identity
            return self.factory

    def catalog_status(self):
        """Expose public catalog readiness without reading private saved finds.

        Counts come from the atomic import audit, not a scan of every product.
        An indexed existence check verifies that each reported snapshot still
        has product rows and that the product table can actually be queried.
        """
        unavailable = CatalogReadiness(status="catalog_unavailable", catalog_count=0, sources=[])
        try:
            factory = self._factory()
            if factory is None:
                return unavailable
            with factory() as db:
                has_products = select(CatalogProduct.id).where(
                    CatalogProduct.feed_id == CatalogFeed.id,
                    CatalogProduct.import_id == CatalogFeed.last_import_id,
                ).exists()
                rows = db.execute(select(CatalogFeed.source_id, CatalogImport.row_count).join(
                    CatalogImport,
                    (CatalogImport.id == CatalogFeed.last_import_id) & (CatalogImport.feed_id == CatalogFeed.id),
                ).where(CatalogFeed.source_id.in_(ELIGIBLE_SOURCES), CatalogFeed.enabled.is_(True),
                        has_products)).all()
            counts = {}
            for source_id, count in rows:
                if type(count) is not int or count < 0:
                    return unavailable
                if count:
                    counts[source_id] = counts.get(source_id, 0) + count
            sources = [CatalogReadinessSource(source_id=source, record_count=count)
                       for source, count in sorted(counts.items())]
            return CatalogReadiness(status="ready" if sources else "catalog_unavailable",
                                    catalog_count=sum(counts.values()), sources=sources)
        except (SQLAlchemyError, sqlite3.Error, OSError):
            # A fresh clone, interrupted setup or unreadable catalog remains an
            # explicit operational state; never serialize its local path/error.
            return unavailable

    @staticmethod
    def _response(body, status=200, *, cache="miss"):
        return Response(body, status_code=status, media_type="application/json",
                        headers={"Cache-Control": "no-store", "X-Mynah-Cache": cache})

    @staticmethod
    def _busy():
        return JSONResponse({"error": {"code": "recommendations_busy", "message": "Recommendations are busy. Try again shortly.", "retryable": True}},
                            status_code=503, headers={"Cache-Control": "no-store"})

    def recommendations(self, request):
        factory = self._factory()
        try:
            snapshot = _catalog_snapshot(factory)
        except (SQLAlchemyError, sqlite3.Error):
            snapshot = ("unavailable", 0, False)
        # IDs, titles, notes, all chosen intentions, analysis, search and limit
        # are included. A result from one find/user cannot leak through a cache
        # keyed only by a product name or generic search. Keys contain no text.
        fingerprint = hashlib.sha256(request.model_dump_json().encode()).hexdigest()
        key = hashlib.sha256((snapshot[0] + fingerprint).encode()).hexdigest()
        with self.lock:
            now = self.clock()
            for expired in [entry for entry, (until, _) in self.cache.items() if until <= now]:
                del self.cache[expired]
            cached = self.cache.get(key)
            if cached is not None:
                self.cache.move_to_end(key)
                return self._response(cached[1], cache="hit")
            future = self.inflight.get(key)
            owner = future is None
            if owner:
                future = Future()
                self.inflight[key] = future
        if not owner:
            try:
                body, status = future.result(timeout=30)
                return self._response(body, status, cache="coalesced")
            except FutureTimeout:
                return self._busy()
        acquired = self.capacity.acquire(blocking=False)
        try:
            if not acquired:
                response = self._busy()
                future.set_result((response.body, response.status_code))
                return response
            result = recommend(factory, request, catalog_snapshot=snapshot)
            current = _catalog_snapshot(factory)
            if current != snapshot:
                # A source was imported or revoked while ranking. Recompute
                # once against its new snapshot rather than caching old links.
                snapshot = current
                result = recommend(factory, request, catalog_snapshot=snapshot)
                if _catalog_snapshot(factory) != snapshot:
                    response = self._busy()
                    future.set_result((response.body, response.status_code))
                    return response
            # Every visible product already carries its own reviewed Amazon
            # image. Never replace it via another source or a photo-first sort.
            body = result.model_dump_json().encode()
            if result.status != "catalog_unavailable":
                final_key = hashlib.sha256((snapshot[0] + fingerprint).encode()).hexdigest()
                with self.lock:
                    self.cache[final_key] = (self.clock() + CACHE_TTL_SECONDS, body)
                    self.cache.move_to_end(final_key)
                    while len(self.cache) > CACHE_MAX_ENTRIES:
                        self.cache.popitem(last=False)
            future.set_result((body, 200))
            return self._response(body)
        except (SQLAlchemyError, sqlite3.Error):
            result = RecommendationResult(status="catalog_unavailable", items=[], catalog_count=0,
                                          query=request.query, generated_at=time.time())
            body = result.model_dump_json().encode()
            future.set_result((body, 200))
            return self._response(body)
        except BaseException as error:
            future.set_exception(error)
            raise
        finally:
            if acquired:
                self.capacity.release()
            with self.lock:
                self.inflight.pop(key, None)


def register_recommendations(app: FastAPI, factory=None, discovery=None):
    service = LocalRecommendationService(factory)
    app.state.recommendation_service = service

    @app.post("/v1/recommendations", response_model=RecommendationResult)
    async def recommendations(request: RecommendationRequest):
        import asyncio
        response = await asyncio.to_thread(service.recommendations, request)
        return await discovery.augment(request, response) if discovery else response

    @app.get("/v1/catalog/status", response_model=CatalogReadiness)
    def catalog_status():
        return JSONResponse(service.catalog_status().model_dump(), headers={"Cache-Control": "no-store"})
