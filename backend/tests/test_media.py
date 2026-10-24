import base64
from io import BytesIO
import struct
import zlib

from PIL import Image, PngImagePlugin
import pytest

from backend.app.media import MAX_IMAGE_BYTES, validate_image_data_url


def data_url(raw, mime="image/png"):
    return f"data:{mime};base64," + base64.b64encode(raw).decode("ascii")


def picture(fmt="PNG", size=(24, 16), **options):
    buffer = BytesIO()
    Image.new("RGB", size, "red").save(buffer, format=fmt, **options)
    return buffer.getvalue()


def decode(value):
    return Image.open(BytesIO(base64.b64decode(value.split(",", 1)[1])))


@pytest.mark.parametrize("fmt,mime", [("PNG", "image/png"), ("JPEG", "image/jpeg"), ("WEBP", "image/webp")])
def test_supported_images_are_reencoded(fmt, mime):
    value = validate_image_data_url(data_url(picture(fmt), mime))
    image = decode(value)
    image.load()
    assert image.size == (24, 16)
    assert image.format in {"JPEG", "PNG"}


def test_pixels_preserved_but_metadata_and_trailing_data_removed():
    info = PngImagePlugin.PngInfo()
    info.add_text("secret", "private location")
    source = picture(pnginfo=info) + b"trailing-private-data"
    result = validate_image_data_url(data_url(source))
    image = decode(result)
    assert image.getpixel((0, 0)) == (255, 0, 0)
    assert not image.info
    assert b"private" not in base64.b64decode(result.split(",", 1)[1])


def test_exif_orientation_applied_and_gps_removed():
    exif = Image.Exif()
    exif[274] = 6
    exif[270] = "private camera description"
    result = validate_image_data_url(data_url(picture("JPEG", exif=exif), "image/jpeg"))
    image = decode(result)
    assert image.size == (16, 24)
    assert not image.getexif()


def test_image_downsized_and_transparency_preserved():
    buffer = BytesIO()
    Image.new("RGBA", (2400, 1200), (200, 100, 50, 120)).save(buffer, format="PNG")
    image = decode(validate_image_data_url(data_url(buffer.getvalue())))
    assert image.size == (1600, 800)
    assert image.mode == "RGBA"
    assert image.getpixel((0, 0))[3] == 120


@pytest.mark.parametrize("value", [
    "https://example.com/image.png", "data:image/svg+xml;base64,PHN2Zz4=",
    "data:image/png;charset=utf-8;base64,AAAA", "data:image/png;base64,%%%",
    "data:image/png;base64,", "data:image/png;base64,AAAA\n", "data:image/png;base64,é",
])
def test_invalid_or_unsupported_data_urls_rejected(value):
    with pytest.raises(ValueError):
        validate_image_data_url(value)


def test_mime_mismatch_and_truncated_images_rejected():
    with pytest.raises(ValueError, match="media type"):
        validate_image_data_url(data_url(picture("JPEG")))
    with pytest.raises(ValueError):
        validate_image_data_url(data_url(picture()[:40]))


def test_input_byte_limit():
    with pytest.raises(ValueError, match="4 MiB"):
        validate_image_data_url(data_url(b"x" * (MAX_IMAGE_BYTES + 1)))


def test_dimension_and_pixel_limits():
    for size in [(4097, 1), (4001, 4000)]:
        with pytest.raises(ValueError, match="dimensions"):
            validate_image_data_url(data_url(picture(size=size)))


def test_decompression_bomb_header_rejected_before_load():
    raw = bytearray(picture())
    raw[16:24] = struct.pack(">II", 100_000, 100_000)
    raw[29:33] = struct.pack(">I", zlib.crc32(raw[12:29]))
    with pytest.raises(ValueError, match="dimensions"):
        validate_image_data_url(data_url(raw))


def test_animated_png_rejected():
    buffer = BytesIO()
    Image.new("RGB", (8, 8), "red").save(
        buffer, format="PNG", save_all=True, append_images=[Image.new("RGB", (8, 8), "blue")], duration=100)
    with pytest.raises(ValueError, match="static"):
        validate_image_data_url(data_url(buffer.getvalue()))
