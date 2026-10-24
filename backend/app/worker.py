"""Database-backed jobs with leases, bounded retries and idempotent handlers."""
import logging
import time
import uuid

from sqlalchemy import and_, or_, select, update

from .db import Job, Notification, Observation, SavedItem, Suggestion, Watch, make_database
from .intelligence import DemoAnnotationProvider

logger = logging.getLogger(__name__)


def enqueue(db, user, kind, payload):
    job = Job(user_id=user, kind=kind, payload=payload)
    db.add(job)
    db.flush()
    return job.id


def process_job(db, job, provider):
    if job.kind == "enrich":
        item = db.scalar(select(SavedItem).where(SavedItem.id == job.payload["item_id"], SavedItem.user_id == job.user_id).with_for_update())
        if not item or item.deleted or item.revision != job.payload["revision"] or item.status == "ready":
            return
        result = provider.understand(item.title, item.selected_text)
        # The adapter receives captured content as data, has no tools, and may only
        # suggest annotations. No provider output becomes user evidence.
        if not isinstance(result.get("features"), dict) or not 1 <= len(result.get("suggestions", [])) <= 5:
            raise ValueError("invalid_provider_output")
        allowed_claims = {"warm_lighting", "compact_space", "low_clutter", "inspiration_only", "needs_clarification"}
        for suggestion in result["suggestions"]:
            if suggestion.get("claim") not in allowed_claims or not isinstance(suggestion.get("text"), str) or not 1 <= len(suggestion["text"]) <= 200:
                raise ValueError("invalid_provider_output")
            if suggestion.get("kind") not in {"attraction", "constraint", "stage"}:
                raise ValueError("invalid_provider_output")
            db.add(Suggestion(user_id=job.user_id, item_id=item.id, model_version=provider.version, **suggestion))
        item.features = result["features"]
        item.status = "ready"
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


def run_once(factory, provider=None):
    provider = provider or DemoAnnotationProvider()
    now = time.time()
    eligible = or_(and_(Job.status == "pending", Job.due_at <= now), and_(Job.status == "running", Job.lease_until < now))
    token = uuid.uuid4().hex
    with factory.begin() as db:
        candidate = db.scalar(select(Job.id).where(eligible).order_by(Job.due_at, Job.id).limit(1))
        if candidate is None:
            return False
        claimed = db.execute(update(Job).where(Job.id == candidate, eligible).values(status="running", lease_until=now + 60, lease_token=token, attempts=Job.attempts + 1))
        if claimed.rowcount != 1:
            return False
    try:
        with factory.begin() as db:
            job = db.scalar(select(Job).where(Job.id == candidate, Job.lease_token == token).with_for_update())
            if not job:
                return True
            process_job(db, job, provider)
            job.status = "done"
            job.lease_token = None
    except Exception as error:
        # No raw input, URLs, notes or provider response in logs.
        logger.warning("job_failed id=%s error_type=%s", candidate, type(error).__name__)
        with factory.begin() as db:
            job = db.scalar(select(Job).where(Job.id == candidate, Job.lease_token == token).with_for_update())
            if job:
                job.error = type(error).__name__
                job.status = "failed" if job.attempts >= 3 else "pending"
                job.due_at = time.time() + 2 ** job.attempts
                job.lease_token = None
                if job.status == "failed" and job.kind == "enrich":
                    item = db.get(SavedItem, job.payload["item_id"])
                    if item and item.user_id == job.user_id and not item.deleted:
                        item.status = "enrichment_failed"
    return True


def run_forever(factory, stop=None):
    while stop is None or not stop.is_set():
        try:
            worked = run_once(factory)
        except Exception:
            logger.exception("worker_iteration_failed")
            worked = False
        if not worked:
            if stop:
                stop.wait(0.5)
            else:
                time.sleep(0.5)


if __name__ == "__main__":
    _, factory = make_database()
    run_forever(factory)
