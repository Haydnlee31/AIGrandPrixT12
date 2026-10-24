"""Make one explicit, billable Astra image request with backend credentials.

Uses a locally generated lamp illustration, never the user's Library. Run after
setting ASTRA_API_KEY or OPENAI_API_KEY in the server environment. No fallback.
"""
from __future__ import annotations

import base64
from io import BytesIO
import json
from pathlib import Path
import sys
import time

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from backend.app.predictive import AstraAnnotationProvider, ProviderError
from backend.app.worker import AnnotationInput, validate_annotation


def sample_image() -> str:
    image = Image.new("RGB", (256, 256), "#f6f3eb")
    draw = ImageDraw.Draw(image)
    draw.rectangle((26, 205, 230, 215), fill="#b58a62")
    draw.ellipse((71, 184, 185, 205), fill="#4b5867")
    draw.line((128, 190, 128, 112, 156, 80), fill="#4b5867", width=10)
    draw.polygon([(144, 52), (179, 77), (154, 123), (109, 91)], fill="#e9b95d")
    draw.ellipse((109, 89, 155, 124), fill="#ffe5a2")
    stream = BytesIO()
    image.save(stream, "PNG")
    return "data:image/png;base64," + base64.b64encode(stream.getvalue()).decode("ascii")


def main() -> int:
    provider = None
    started = time.monotonic()
    try:
        # Construct Astra directly so absent credentials can never report a
        # successful live check by silently selecting the no-key fallback.
        provider = AstraAnnotationProvider()
        capture = AnnotationInput(
            title="A desk lamp for my reading corner",
            selected_text="",
            note="I am collecting lighting ideas and might compare options later.",
            image_data_url=sample_image(),
            confirmed_preferences=(),
        )
        result = provider.understand_capture(capture)
        validated = validate_annotation(result, provider.version)
        print(json.dumps({
            "status": "passed",
            "model": provider.model,
            "elapsed_seconds": round(time.monotonic() - started, 2),
            "image_analyzed": validated["features"]["image_analyzed"],
            "actions": [suggestion["claim"] for suggestion in validated["suggestions"]],
        }))
        return 0
    except ProviderError as error:
        print(json.dumps({"status": "failed", "code": error.code, "retryable": error.retryable}), file=sys.stderr)
        return 1
    except Exception as error:
        # No raw HTTP bodies, user content, environment values or traceback.
        print(json.dumps({"status": "failed", "code": "smoke_check_failed", "error_type": type(error).__name__}), file=sys.stderr)
        return 1
    finally:
        if provider is not None:
            provider.close()


if __name__ == "__main__":
    raise SystemExit(main())
