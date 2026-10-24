"""Vercel delivery adapter; PostgreSQL retains job state and publication guards."""
import asyncio
import os
import time

from sqlalchemy import and_, or_, select
from vercel.queue import Message, subscribe
from vercel.queue.sync import QueueClient

from .db import Job, make_database
from .worker import run_once

TOPIC = "mynah-analysis"


def dispatch(factory, *, user_id=None):
    now = time.time()
    eligible = or_(and_(Job.status == "pending", Job.due_at <= now),
                   and_(Job.status == "running", Job.lease_until <= now))
    with factory() as db:
        query = select(Job.id).where(eligible).order_by(Job.due_at, Job.id).limit(20)
        if user_id is not None:
            query = query.where(Job.user_id == user_id)
        ids = list(db.scalars(query))
    queue = QueueClient(timeout=2)
    for job_id in ids:
        # Hourly keys also recover jobs after an old delivery expires or a
        # deployment is replaced. Duplicate deliveries remain lease/idempotency safe.
        queue.send(TOPIC, {"job_id": job_id}, retention=86400,
                   idempotency_key=f"{job_id}:{int(now // 3600)}")
    return len(ids)


def process(factory, job_id):
    run_once(factory, job_id=job_id)
    with factory() as db:
        job = db.get(Job, job_id)
        if job is not None and job.status in {"pending", "running"}:
            # Preserve the worker's retry budget and backoff, including lost leases.
            raise RuntimeError("job_not_finished")


@subscribe(topic=TOPIC, consumer_group="mynah-analysis", retry_after=10,
           max_concurrency=2, max_attempts=32)
async def analyze(message: Message[dict[str, str]]):
    from scripts.run_shared import configure
    configure(os.environ)
    engine, factory = make_database()
    try:
        await asyncio.to_thread(process, factory, message.payload["job_id"])
    finally:
        engine.dispose()
