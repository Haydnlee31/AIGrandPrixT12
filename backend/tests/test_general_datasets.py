import csv
import gzip
import json

import pytest

from backend.app.catalog.general_datasets import DatasetFormatError, iter_abo, iter_wands
from backend.app.catalog.schemas import CatalogRecord


def abo_row(**changes):
    return {"item_id": "SOURCE-ASIN", "domain_name": "amazon.sg", "item_name": [{"language_tag": "en_SG", "value": "Reading lamp"}],
            "brand": [{"language_tag": "en_SG", "value": "Source brand"}], "product_type": [{"value": "LAMP"}],
            "marketplace": "Amazon", "country": "SG", "main_image_id": "source-image", **changes}


def write_abo(tmp_path, rows):
    path = tmp_path / "listings_0.json.gz"
    with gzip.open(path, "wt") as file:
        for row in rows:
            file.write(json.dumps(row) + "\n")
    return tmp_path


def write_images(tmp_path, rows):
    path = tmp_path / "images.csv.gz"
    with gzip.open(path, "wt", newline="") as file:
        writer = csv.writer(file)
        writer.writerow(["image_id", "height", "width", "path"])
        writer.writerows(rows)
    return path


def test_abo_keeps_marketplace_identity_and_unknown_commerce(tmp_path):
    directory = write_abo(tmp_path, [abo_row(), abo_row(domain_name="amazon.com")])
    records = list(iter_abo(directory))
    assert records[0]["source_record_id"] != records[1]["source_record_id"]
    for row in records:
        CatalogRecord.model_validate(row)
        assert row["merchant"] == {"id": None, "name": None, "platform": "abo"}
        assert row["offer"]["price_minor"] is None and row["offer"]["url"] is None
        assert row["offer"]["availability"] == "unknown" and row["offer"]["observed_at"] is None
        assert row["data_kind"] == "open_dataset"


def test_abo_prefers_english_but_preserves_nonenglish_titles(tmp_path):
    write_abo(tmp_path, [abo_row(item_name=[{"language_tag": "ja_JP", "value": "読書灯"}, {"language_tag": "en_US", "value": "Desk lamp"}]),
                         abo_row(item_id="SECOND", item_name=[{"language_tag": "ja_JP", "value": "読書灯"}])])
    records = list(iter_abo(tmp_path))
    assert [r["title"] for r in records] == ["Desk lamp", "読書灯"]
    assert records[1]["provenance"]["title_language"] == "ja_JP"


def test_abo_strips_unsafe_html_controls_and_keeps_useful_dimensions(tmp_path):
    write_abo(tmp_path, [abo_row(item_name=[{"language_tag": "en_US", "value": "<script>bad()</script><b>Desk\x00lamp</b>"}],
                               product_description=[{"language_tag": "en_US", "value": "<p>Metal &amp; glass</p><style>hidden</style>"}],
                               item_dimensions={"width": {"normalized_value": {"unit": "cm", "value": 22.5}}})])
    row = next(iter_abo(tmp_path))
    assert row["title"] == "Desk lamp" and row["description"] == "Metal & glass"
    assert row["attributes"]["item_dimensions"]["width"]["normalized_value"]["value"] == 22.5


def test_abo_image_join_uses_only_documented_fixed_host(tmp_path):
    write_abo(tmp_path, [abo_row()])
    images = write_images(tmp_path, [["source-image", 100, 100, "ab/abcdef.jpg"]])
    row = next(iter_abo(tmp_path, images))
    CatalogRecord.model_validate(row)
    assert row["offer"]["image_url"] == "https://amazon-berkeley-objects.s3.us-east-1.amazonaws.com/images/small/ab/abcdef.jpg"


@pytest.mark.parametrize("path", ["../secret.jpg", "ab/../../secret.jpg", "https://evil.example/img.jpg", "ab/abcdef.jpg?token=x", "ab/abcdef.svg"])
def test_abo_rejects_unsafe_image_mapping(tmp_path, path):
    write_abo(tmp_path, [abo_row()])
    images = write_images(tmp_path, [["source-image", 1, 1, path]])
    with pytest.raises(DatasetFormatError, match="invalid or oversized"):
        list(iter_abo(tmp_path, images))


def test_abo_missing_valid_title_fails_instead_of_silently_losing_row(tmp_path):
    write_abo(tmp_path, [abo_row(item_name=[{"language_tag": "en_US", "value": "<script>private source text</script>"}])])
    with pytest.raises(DatasetFormatError) as error:
        list(iter_abo(tmp_path))
    assert error.value.code == "missing_product_title"
    assert "private source text" not in str(error.value)


def test_abo_missing_description_can_use_sourced_bullets(tmp_path):
    write_abo(tmp_path, [abo_row(bullet_point=[{"language_tag": "en_SG", "value": "Metal base"}, {"language_tag": "en_SG", "value": "Warm light"}, {"language_tag": "ja_JP", "value": "別の言語"}])])
    assert next(iter_abo(tmp_path))["description"] == "Metal base Warm light"


def test_wands_real_header_quoted_large_fields_and_plaintext(tmp_path):
    path = tmp_path / "product.csv"
    with path.open("w", newline="") as file:
        writer = csv.writer(file, delimiter="\t")
        writer.writerow(["product_id", "product_name", "category hierarchy", "product_description", "product_features", "average_rating"])
        writer.writerow(["42", "<b>Lamp</b>", "Home / Lighting", "<p>Long description</p>" + "x" * 150000, "Color:blue|Width:20cm\tCustom:yes", "4.5"])
    previous_limit = csv.field_size_limit()
    row = next(iter_wands(path))
    CatalogRecord.model_validate(row)
    assert row["title"] == "Lamp" and row["category"] == "Home / Lighting"
    assert len(row["description"]) == 20000 and row["source_record_id"] == "wands:42"
    assert row["attributes"]["average_rating"] == "4.5"
    assert row["offer"]["url"] is None and row["offer"]["image_url"] is None
    assert csv.field_size_limit() == previous_limit


def test_wands_missing_title_and_invalid_header_fail_safely(tmp_path):
    path = tmp_path / "product.tsv"
    path.write_text("product_id\tproduct_name\n1\t\n")
    with pytest.raises(DatasetFormatError) as error:
        list(iter_wands(path))
    assert error.value.code == "invalid_wands_identity"
    path.write_text("product_id\tproduct_id\n1\t2\n")
    with pytest.raises(DatasetFormatError) as error:
        list(iter_wands(path))
    assert error.value.code == "invalid_wands_header"


def test_abo_truncated_gzip_rejected(tmp_path):
    write_abo(tmp_path, [abo_row()])
    path = tmp_path / "listings_0.json.gz"
    path.write_bytes(path.read_bytes()[:-10])
    with pytest.raises(DatasetFormatError) as error:
        list(iter_abo(tmp_path))
    assert error.value.code == "invalid_abo_file"


def test_missing_abo_shards_and_large_attributes_are_bounded(tmp_path):
    with pytest.raises(DatasetFormatError):
        list(iter_abo(tmp_path))
    write_abo(tmp_path, [abo_row(node=[{"node_name": "字" * 5000}] * 20, item_keywords=[{"value": "word" * 10000}] * 10)])
    row = next(iter_abo(tmp_path))
    CatalogRecord.model_validate(row)
    assert len(json.dumps(row["attributes"])) < 32000
