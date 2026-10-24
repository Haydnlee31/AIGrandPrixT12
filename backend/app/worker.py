"""Database-backed jobs with leases, bounded retries and idempotent handlers."""
import json
import logging
import math
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass

from sqlalchemy import and_, delete, or_, select, update

from .db import Evidence, Job, Notification, Observation, SavedItem, Suggestion, UserState, Watch, make_database
from .predictive import ProviderError, get_annotation_provider
from .library import update_search_document

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class AnnotationInput:
    """Only captured data crosses the provider boundary; no live ORM objects."""
    title: str
    selected_text: str
    note: str = ""
    image_data_url: str | None = None
    confirmed_preferences: tuple[str, ...] = ()
    confirmed_annotations: tuple[str, ...] = ()


def preference_snapshot(db, user_id):
    # Only explicit, active evidence from this user's existing saves is eligible.
    rows = db.scalars(select(Evidence).join(SavedItem, SavedItem.id == Evidence.item_id).where(
        Evidence.user_id == user_id, SavedItem.user_id == user_id, Evidence.active.is_(True),
        SavedItem.deleted.is_(False), Evidence.origin.in_(["confirmed_annotation", "explicit_statement"])
    ).order_by(Evidence.observed_at.desc(), Evidence.id).limit(8)).all()
    return tuple((e.id, e.claim, e.text[:300]) for e in rows)


def annotation_snapshot(db, user_id, item_id):
    rows = db.scalars(select(Evidence).where(Evidence.user_id == user_id, Evidence.item_id == item_id,
        Evidence.active.is_(True), Evidence.origin.in_(["confirmed_annotation", "explicit_statement"]))
        .order_by(Evidence.observed_at.desc(), Evidence.id).limit(12)).all()
    return tuple((row.id, row.text[:500]) for row in rows)


class LostLease(Exception):
    pass


@contextmanager
def transaction(factory):
    with factory.begin() as db:
        # SQLite ignores FOR UPDATE. Reserve its writer lock before reading the
        # state that this short transaction will update, as the API does.
        if db.get_bind().dialect.name == "sqlite":
            db.connection().exec_driver_sql("BEGIN IMMEDIATE")
        yield db


def leased_job(db, job_id, token):
    job = db.scalar(select(Job).where(Job.id == job_id, Job.lease_token == token, Job.status == "running").with_for_update())
    # Check the clock after acquiring the lock, which may have involved a wait.
    if job and job.lease_until > time.time():
        return job
    return None


def enrichment_item(db, job):
    item = db.scalar(select(SavedItem).where(SavedItem.id == job.payload["item_id"], SavedItem.user_id == job.user_id).with_for_update())
    if item and not item.deleted and item.revision == job.payload["revision"] and item.status == "pending":
        return item
    return None


def finish_job(job):
    # A row lock prevents another claimant from changing the token, but time can
    # still expire while waiting for a saved-item/watch lock. Roll back in that
    # case, including any annotations, observations or alerts prepared below.
    if job.lease_until <= time.time():
        raise LostLease()
    job.status = "done"
    job.lease_token = None
    job.lease_until = 0
    job.error = None


def validate_annotation(result, model_version):
    """Bound provider-controlled JSON and copy only fields we can persist."""
    if type(result) is not dict or type(result.get("features")) is not dict:
        raise ValueError("invalid_provider_output")
    if type(model_version) is not str or not model_version.strip() or len(model_version) > 100:
        raise ValueError("invalid_provider_version")
    model_version.encode("utf-8")

    nodes = 0

    def check_json(value, depth=0):
        nonlocal nodes
        nodes += 1
        if nodes > 1024 or depth > 7:
            raise ValueError("invalid_provider_output")
        if type(value) is dict:
            if len(value) > 64:
                raise ValueError("invalid_provider_output")
            for key, child in value.items():
                if type(key) is not str or not 1 <= len(key) <= 100:
                    raise ValueError("invalid_provider_output")
                check_json(child, depth + 1)
        elif type(value) is list:
            if len(value) > 64:
                raise ValueError("invalid_provider_output")
            for child in value:
                check_json(child, depth + 1)
        elif type(value) is str:
            if len(value) > 2048:
                raise ValueError("invalid_provider_output")
        elif type(value) is float:
            if not math.isfinite(value):
                raise ValueError("invalid_provider_output")
        elif type(value) is int:
            if abs(value) > 2 ** 53 - 1:
                raise ValueError("invalid_provider_output")
        elif value is not None and type(value) is not bool:
            raise ValueError("invalid_provider_output")

    check_json(result["features"])
    serialized = json.dumps(result["features"], allow_nan=False, ensure_ascii=False)
    if len(serialized.encode("utf-8")) > 32768:
        raise ValueError("invalid_provider_output")
    suggestions = result.get("suggestions")
    if type(suggestions) is not list or not 1 <= len(suggestions) <= 5:
        raise ValueError("invalid_provider_output")
    allowed_claims = {"warm_lighting", "compact_space", "low_clutter", "inspiration_only", "needs_clarification",
                      "buy_intent", "track_discount", "remind_later", "save_inspiration", "compare_options"}
    unique = {}
    for suggestion in suggestions:
        if type(suggestion) is not dict or set(suggestion) != {"kind", "text", "claim"}:
            raise ValueError("invalid_provider_output")
        kind, text, claim = suggestion["kind"], suggestion["text"], suggestion["claim"]
        if type(kind) is not str or kind not in {"attraction", "constraint", "stage", "intent"}:
            raise ValueError("invalid_provider_output")
        if type(claim) is not str or claim not in allowed_claims:
            raise ValueError("invalid_provider_output")
        if (kind == "intent") != (claim in {"buy_intent", "track_discount", "remind_later", "save_inspiration", "compare_options"}):
            raise ValueError("invalid_provider_output")
        if type(text) is not str or not 1 <= len(text.strip()) <= 200 or len(text) > 200:
            raise ValueError("invalid_provider_output")
        text.encode("utf-8")
        unique[(kind, text.strip(), claim)] = {"kind": kind, "text": text.strip(), "claim": claim}
    return {"features": json.loads(serialized), "suggestions": list(unique.values())}


def enqueue(db, user, kind, payload):
    job = Job(user_id=user, kind=kind, payload=payload)
    db.add(job)
    db.flush()
    return job.id


def process_job(db, job, annotation=None, model_version=None):
    """Persist prepared work only. Provider/network calls must happen outside."""
    if job.kind == "enrich":
        item = enrichment_item(db, job)
        if not item:
            return
        if annotation is None:
            raise ValueError("missing_provider_output")
        # The adapter receives captured content as data, has no tools, and may only
        # suggest annotations. No provider output becomes user evidence.
        previous = {(s.kind, s.claim): s for s in db.scalars(select(Suggestion).where(Suggestion.user_id == job.user_id, Suggestion.item_id == item.id))}
        retained = set()
        for suggestion in annotation["suggestions"]:
            key = (suggestion["kind"], suggestion["claim"])
            if key in retained:
                continue
            retained.add(key)
            if key in previous:
                previous[key].text = suggestion["text"]
                previous[key].model_version = model_version
            else:
                # Stable identity survives manual reanalysis or a temporarily
                # omitted option; it is not derived from model wording/rank.
                identity = uuid.uuid5(uuid.NAMESPACE_URL, f"mymah:{item.id}:{key[0]}:{key[1]}").hex
                db.add(Suggestion(id=identity, user_id=job.user_id, item_id=item.id, model_version=model_version, **suggestion))
        for key, old in previous.items():
            if key not in retained:
                db.delete(old)
        item.features = annotation["features"]
        item.status = "ready"
        update_search_document(db, item)
        if isinstance(item.features.get("analysis"), dict):
            state = db.get(UserState, job.user_id)
            if state:
                state.version += 1
    elif job.kind == "price_check":
        data = job.payload
        watch = db.scalar(select(Watch).where(Watch.id == data["watch_id"], Watch.user_id == job.user_id).with_for_update())
        if not watch or not watch.enabled or watch.rule_version != data["rule_version"]:
            return
        if watch.variant_id != data["variant_id"] or watch.currency != data["currency"]:
            raise ValueError("observation_variant_or_currency_mismatch")
        if db.get(Observation, job.id):
            return
        observed_at = data["observed_at"]
        if watch.last_checked_at is not None and observed_at <= watch.last_checked_at:
            return
        observation = Observation(id=job.id, user_id=job.user_id, watch_id=watch.id, variant_id=data["variant_id"], currency=data["currency"], amount_minor=data["amount_minor"], observed_at=observed_at, data_mode="simulated")
        db.add(observation)
        db.flush()
        below = data["amount_minor"] <= watch.target_minor
        if below and not watch.below:
            watch.episode += 1
            dedupe = f"{watch.id}:{watch.rule_version}:{watch.episode}"
            db.add(Notification(user_id=job.user_id, watch_id=watch.id, observation_id=job.id, dedupe_key=dedupe, message=f"Simulated price alert: {watch.variant_id} is {watch.currency} {data['amount_minor'] / 100:.2f}, at or below your target."))
        watch.below = below
        watch.last_price_minor = data["amount_minor"]
        watch.last_checked_at = observed_at
    else:
        raise ValueError("unknown_job_kind")


def run_once(factory, provider=None, *, job_id=None):
    owned_provider = provider is None
    provider = provider if provider is not None else get_annotation_provider()
    try:
        return _run_once(factory, provider, job_id=job_id)
    finally:
        if owned_provider and hasattr(provider, "close"):
            provider.close()


def _run_once(factory, provider, *, job_id=None):
    now = time.time()
    eligible = or_(and_(Job.status == "pending", Job.due_at <= now), and_(Job.status == "running", Job.lease_until <= now))
    if job_id is not None:
        eligible = and_(eligible, Job.id == job_id)
    token = uuid.uuid4().hex
    with transaction(factory) as db:
        candidate = db.scalar(select(Job.id).where(eligible).order_by(Job.due_at, Job.id).limit(1))
        if candidate is None:
            return False
        claimed = db.execute(update(Job).where(Job.id == candidate, eligible).values(status="running", lease_until=now + 60, lease_token=token, attempts=Job.attempts + 1))
        if claimed.rowcount != 1:
            return False
    try:
        with transaction(factory) as db:
            job = leased_job(db, candidate, token)
            if not job:
                return True
            if job.kind != "enrich":
                process_job(db, job)
                finish_job(job)
                return True
            item = enrichment_item(db, job)
            if not item:
                finish_job(job)
                return True
            contextual = hasattr(provider, "understand_capture")
            preferences = preference_snapshot(db, job.user_id) if contextual else ()
            current_notes = annotation_snapshot(db, job.user_id, item.id) if contextual else ()
            snapshot = AnnotationInput(title=item.title, selected_text=item.selected_text, note=item.note,
                image_data_url=item.image_data_url, confirmed_preferences=tuple(f"{claim}: {text}" for _, claim, text in preferences),
                confirmed_annotations=tuple(dict.fromkeys(note for _, note in current_notes)))

        # No session, transaction, connection or row lock survives this boundary.
        result = provider.understand_capture(snapshot) if contextual else provider.understand(snapshot.title, snapshot.selected_text)
        model_version = provider.version
        annotation = validate_annotation(result, model_version)
        annotation["features"]["suggestion_order"] = [suggestion["claim"] for suggestion in annotation["suggestions"]]
        if contextual:
            annotation["features"]["context_evidence_ids"] = list(dict.fromkeys([entry[0] for entry in preferences] + [entry[0] for entry in current_notes]))

        with transaction(factory) as db:
            if contextual:
                # API mutations take this same lock. Keep preference revocation
                # and prediction publication ordered on PostgreSQL as on SQLite.
                db.scalar(select(UserState).where(UserState.user_id == job.user_id).with_for_update())
            job = leased_job(db, candidate, token)
            if not job:
                return True
            if contextual and (preference_snapshot(db, job.user_id) != preferences or annotation_snapshot(db, job.user_id, job.payload["item_id"]) != current_notes):
                # Recompute from current evidence after deletion, rejection or a
                # concurrent edit; never publish from a revoked preference.
                raise ProviderError("context_changed", retryable=True)
            process_job(db, job, annotation, model_version)
            finish_job(job)
    except LostLease:
        # Leave the expired job recoverable; an old worker owns no writes.
        return True
    except Exception as error:
        # No raw input, URLs, notes or provider response in logs.
        logger.warning("job_failed id=%s error_type=%s", candidate, type(error).__name__)
        with transaction(factory) as db:
            job = leased_job(db, candidate, token)
            if job:
                item = enrichment_item(db, job) if job.kind == "enrich" else None
                if job.lease_until <= time.time():
                    return True
                if job.kind == "enrich" and item is None:
                    finish_job(job)
                    return True
                job.error = error.code if isinstance(error, ProviderError) else type(error).__name__
                job.status = "failed" if job.attempts >= 3 or isinstance(error, ProviderError) and not error.retryable else "pending"
                job.due_at = time.time() + 2 ** job.attempts
                job.lease_token = None
                job.lease_until = 0
                if job.status == "failed" and item:
                    item.status = "enrichment_failed"
    return True


def run_forever(factory, stop=None, provider=None):
    provider = provider if provider is not None else get_annotation_provider()
    try:
        while stop is None or not stop.is_set():
            try:
                worked = run_once(factory, provider)
            except Exception as error:
                logger.error("worker_iteration_failed error_type=%s", type(error).__name__)
                worked = False
            if not worked:
                if stop:
                    stop.wait(0.5)
                else:
                    time.sleep(0.5)
    finally:
        if hasattr(provider, "close"):
            provider.close()


if __name__ == "__main__":
    _, factory = make_database()
    run_forever(factory)
