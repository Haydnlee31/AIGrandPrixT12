"""Vercel's shared API entrypoint. Secrets are supplied by the project environment."""
import os

from scripts.run_shared import configure

configure(os.environ)
if len(os.getenv("CRON_SECRET", "")) < 32:
    raise RuntimeError("Configure a random CRON_SECRET of at least 32 characters.")
os.environ["EMBEDDED_WORKER"] = "false"
os.environ["CAPTURE_IMAGE_BYTES"] = str(3 * 1024 * 1024)

from backend.app.main import app
from backend.app.vercel_jobs import dispatch

app.state.job_dispatcher = dispatch
