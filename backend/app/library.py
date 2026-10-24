"""Private library search over captured text, product observations and confirmed notes."""
import base64
from pydantic import ValidationError
from sqlalchemy import func, select

from .db import Evidence, SavedItem
from .understanding import ProductAnalysis, analysis_terms, normalized_text


def category_key(value):
    return base64.urlsafe_b64encode(normalized_text(value).encode()).decode()


def product_analysis(item):
    raw = item.features.get("analysis")
    if not isinstance(raw, dict) or item.status != "ready":
        return None
    try:
        return ProductAnalysis.model_validate(raw)
    except ValidationError:
        return None


def update_search_document(db, item):
    if item.deleted:
        item.search_text = item.category_text = ""
        return
    parts = [item.title, item.selected_text, item.note, item.original_url, item.source]
    # Only user-confirmed meaning is indexed; unselected prompt text is not.
    notes = db.scalars(select(Evidence.text).where(Evidence.item_id == item.id,
        Evidence.user_id == item.user_id, Evidence.active.is_(True),
        Evidence.origin.in_(["confirmed_annotation", "explicit_statement"]))).all()
    parts.extend(dict.fromkeys(notes))
    analysis = product_analysis(item)
    categories = []
    if analysis:
        parts.extend([analysis.summary, *analysis_terms(analysis)])
        parts.extend(analysis.intent_context)
        categories = list(dict.fromkeys(normalized_text(category) for product in analysis.products for category in product.category_path))
    item.search_text = normalized_text(" ".join(str(part or "") for part in parts))[:64000]
    item.category_text = "|" + "|".join(category_key(value) for value in categories) + "|" if categories else ""


def search_library(db, user_id, query="", category=None, limit=20, offset=0):
    selection = select(SavedItem).where(SavedItem.user_id == user_id, SavedItem.deleted.is_(False))
    for term in normalized_text(query).split():
        selection = selection.where(SavedItem.search_text.contains(term, autoescape=True))
    if category:
        selection = selection.where(SavedItem.category_text.contains("|" + category_key(category) + "|", autoescape=True))
    total = db.scalar(select(func.count()).select_from(selection.subquery()))
    rows = db.scalars(selection.order_by(SavedItem.captured_at.desc(), SavedItem.id).offset(offset).limit(limit)).all()
    return rows, total, offset + limit if offset + limit < total else None
