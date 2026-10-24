"""Transparent fixture inference; no model or external service is called."""
import json
import re
import time
from pathlib import Path
from typing import Protocol

from sqlalchemy import select

from .db import Evidence, SavedItem, UserState

CATALOG = json.loads(Path(__file__).with_name("catalog.json").read_text())


class AnnotationProvider(Protocol):
    version: str

    def understand(self, title: str, text: str) -> dict: ...


def claims_in(text):
    value = text.lower()
    if any(word in value for word in ("just inspiration", "just saving", "looks nice")):
        return ["inspiration_only"]
    # Conservative demo semantics: contradictory/negative text never becomes positive intent.
    if re.search(r"\b(no|not|don't|dont|never|hate|dislike)\b", value):
        return ["needs_clarification"]
    claims = []
    if any(word in value for word in ("warm", "lighting", "atmosphere", "glow")):
        claims.append("warm_lighting")
    if any(word in value for word in ("small desk", "compact", "small space")):
        claims.append("compact_space")
    if any(word in value for word in ("less clutter", "uncluttered", "minimal")):
        claims.append("low_clutter")
    return claims or ["needs_clarification"]


class DemoAnnotationProvider:
    version = "demo-rules-v1"

    def understand(self, title, text):
        content = (title + " " + text).lower()
        desk = any(word in content for word in ("desk", "lamp", "lighting", "workspace"))
        suggestions = []
        if desk:
            suggestions = [
                {"kind": "attraction", "text": "I like the warm lighting", "claim": "warm_lighting"},
                {"kind": "constraint", "text": "This could fit my small desk", "claim": "compact_space"},
                {"kind": "attraction", "text": "I want less clutter", "claim": "low_clutter"},
            ]
        suggestions.append({"kind": "stage", "text": "Just inspiration, not shopping", "claim": "inspiration_only"})
        return {"features": {"desk_related": desk, "provenance": "captured title and selected text", "data_mode": "demo_rules"}, "suggestions": suggestions}


def context(db, user):
    state = db.get(UserState, user)
    evidence = db.scalars(select(Evidence).join(SavedItem).where(Evidence.user_id == user, Evidence.active.is_(True), SavedItem.deleted.is_(False))).all()
    relevant = [e for e in evidence if e.claim in {"warm_lighting", "compact_space", "low_clutter"}]
    opposing = [e for e in evidence if e.claim == "inspiration_only"]
    items = {item.id: item for item in db.scalars(select(SavedItem).where(SavedItem.user_id == user, SavedItem.deleted.is_(False)))}
    def group(item_id):
        item = items[item_id]
        return item.content_hash or item.canonical_url
    # Cap repeated annotations from one save; exact URL copies are canonicalized at capture.
    groups = {}
    for e in relevant:
        weight = 3 if e.origin == "explicit_statement" else 2
        decay = 0.5 ** ((time.time() - e.observed_at) / (60 * 86400))
        key = group(e.item_id)
        groups[key] = max(groups.get(key, 0), weight * decay)
    independent = len(groups)
    # A neutral interpretation blocks unsolicited shopping for its save.
    interested = set(groups) - {group(e.item_id) for e in opposing}
    suppressed = bool(state and (state.suppressed or state.cooldown_until > time.time()))
    eligible = len(interested) >= 2 and not suppressed
    claims = sorted({e.claim for e in relevant})
    evidence_view = [{"id": e.id, "item_id": e.item_id, "claim": e.claim, "text": e.text, "origin": e.origin, "relation": "opposes_readiness" if e.claim == "inspiration_only" else "supports" if e in relevant else "unresolved"} for e in evidence]
    return {
        "id": "desk-lighting", "goal": "A calmer, more personal desk",
        "support_score": round(sum(groups.values()), 2), "score_kind": "heuristic_not_probability",
        "independent_saves": independent, "readiness": "unknown", "confirmed_preferences": claims,
        "evidence": evidence_view, "context_version": state.version if state else 1,
        "status": "suppressed" if suppressed else "invitable" if eligible else "collecting",
        "decision": {"action_type": "invite" if eligible else "wait", "evidence_ids": [e.id for e in relevant], "missing_information": ["budget", "style priority"], "reason_codes": ["independent_confirmed_saves"] if eligible else ["dismissal_or_cooldown" if suppressed else "insufficient_independent_confirmed_interest"], "context_version": state.version if state else 1},
    }


def shortlist(preferences):
    budget = preferences.get("budget_minor")
    if budget is None:
        return []
    result = []
    for product in CATALOG:
        if product["currency"] != "SGD" or not product["in_stock"] or product["price_minor"] > budget:
            continue
        if product["variant_id"] in preferences.get("owned", []):
            continue
        if preferences.get("max_width_cm") is not None and product["width_cm"] > preferences["max_width_cm"]:
            continue
        if preferences.get("low_clutter") and not product["compact"]:
            continue
        score = int(product["style"] == preferences.get("direction")) * 2 + int(product["compact"] and preferences.get("low_clutter", False))
        result.append({**product, "fit_score": score, "explanation": f"Within your S${budget / 100:.0f} item-price budget. " + ("Matches your chosen direction. " if score >= 2 else "An alternative direction. ") + product["tradeoff"]})
    return sorted(result, key=lambda p: (-p["fit_score"], p["price_minor"]))[:3]
