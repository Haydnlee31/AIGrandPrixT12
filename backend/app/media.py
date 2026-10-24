"""Bounded, metadata-free images for private multimodal annotation input."""
from __future__ import annotations

import base64
import binascii
import os
from io import BytesIO
import warnings

from PIL import Image, ImageOps, UnidentifiedImageError


MAX_IMAGE_BYTES = 4 * 1024 * 1024
MAX_IMAGE_DIMENSION = 4096
MAX_IMAGE_PIXELS = 16_000_000
OUTPUT_IMAGE_DIMENSION = 1600
MAX_IMAGE_DATA_URL_LENGTH = len("data:image/jpeg;base64,") + 4 * ((MAX_IMAGE_BYTES + 2) // 3)
_FORMATS = {"image/jpeg": "JPEG", "image/png": "PNG", "image/webp": "WEBP"}


def deployment_asset_bytes():
    """Leave enough base64/JSON headroom for the deployment's request limit."""
    return min(MAX_IMAGE_BYTES, max(64 * 1024, int(os.getenv("CAPTURE_IMAGE_BYTES", str(MAX_IMAGE_BYTES)))))


class _ImageInputError(ValueError):
    """Validation messages that are safe to return to the caller."""


def validate_image_data_url(value: str) -> str:
    """Decode, verify and re-encode a static JPEG, PNG or WebP data URL.

    No URL is ever fetched. Source metadata and ancillary/trailing data are
    discarded. Both input and output are bounded, and output pixels have a
    maximum edge of 1600 to bound subsequent inference cost.
    """
    if not isinstance(value, str) or len(value) > MAX_IMAGE_DATA_URL_LENGTH:
        raise ValueError("Image must be a data URL of at most 4 MiB")
    header, separator, encoded = value.partition(",")
    mime = header[5:-7] if header.startswith("data:") and header.endswith(";base64") else ""
    if not separator or mime not in _FORMATS or header != f"data:{mime};base64":
        raise ValueError("Use a base64 JPEG, PNG or WebP image")
    try:
        raw = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise ValueError("Image base64 is invalid") from None
    if not raw or len(raw) > deployment_asset_bytes():
        raise ValueError(f"Image must contain at most {deployment_asset_bytes() / (1024 * 1024):g} MiB")

    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(BytesIO(raw)) as candidate:
                if candidate.format != _FORMATS[mime]:
                    raise _ImageInputError("Image content does not match its media type")
                width, height = candidate.size
                if (not 0 < width <= MAX_IMAGE_DIMENSION or not 0 < height <= MAX_IMAGE_DIMENSION
                        or width * height > MAX_IMAGE_PIXELS):
                    raise _ImageInputError("Image dimensions must be at most 4096 and 16 million pixels")
                if getattr(candidate, "is_animated", False):
                    raise _ImageInputError("Use a single, static image")
                candidate.verify()
            with Image.open(BytesIO(raw)) as source:
                source.load()
                oriented = ImageOps.exif_transpose(source)
                has_alpha = "A" in oriented.getbands() or "transparency" in oriented.info
                converted = oriented.convert("RGBA" if has_alpha else "RGB")
                converted.thumbnail((OUTPUT_IMAGE_DIMENSION, OUTPUT_IMAGE_DIMENSION), Image.Resampling.LANCZOS)
                # Copy only pixels; copying source.info could retain EXIF/XMP/GPS.
                clean = Image.new(converted.mode, converted.size)
                clean.paste(converted)
    except (Image.DecompressionBombWarning, Image.DecompressionBombError):
        raise ValueError("Image dimensions exceed the supported limit") from None
    except _ImageInputError:
        raise
    except (UnidentifiedImageError, OSError, SyntaxError, EOFError, ValueError):
        raise ValueError("Image content is invalid or incomplete") from None

    output_format = "PNG" if mime == "image/png" or has_alpha else "JPEG"
    while True:
        buffer = BytesIO()
        clean.save(buffer, format=output_format, **({"quality": 85} if output_format == "JPEG" else {}))
        normalized = buffer.getvalue()
        if len(normalized) <= deployment_asset_bytes():
            break
        # Paletted or heavily optimized inputs can grow when converted to RGB.
        clean = clean.resize((max(1, clean.width * 4 // 5), max(1, clean.height * 4 // 5)), Image.Resampling.LANCZOS)
    output_mime = "image/png" if output_format == "PNG" else "image/jpeg"
    return f"data:{output_mime};base64," + base64.b64encode(normalized).decode("ascii")
