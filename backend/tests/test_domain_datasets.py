"""Domain catalog projections preserve source facts without inventing offers."""
import json

import pytest

from backend.app.catalog.domain_datasets import DomainDatasetError, iter_domain
from backend.app.catalog.schemas import CatalogRecord


def jsonl(tmp_path, rows, name="products.jsonl"):
    path = tmp_path / name
    path.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
    return path


def facts_row(**values):
    return {"code": "00012345", "product_name": "<b>Botanical</b> soap", "generic_name": "A <i>gentle</i> soap",
            "brands": "Example label", "categories": "Body care", "stores": "Historical shop",
            "countries": "en:France", "quantity": "100 g", "ingredients_text": "Water, soap",
            "url": "http://world-en.openbeautyfacts.org/product/00012345/soap?x=1#part",
            "image_url": "https://images.openbeautyfacts.org/photo.jpg", "last_modified_t": "1700000000", **values}


@pytest.mark.parametrize("source", ["open_beauty_facts", "open_products_facts", "open_food_facts"])
def test_facts_are_product_metadata_not_current_offers(tmp_path, source):
    row = next(iter_domain(source, jsonl(tmp_path, [facts_row()])))
    CatalogRecord.model_validate(row)
    assert row["source_record_id"] == "00012345"
    assert row["title"] == "Botanical soap"
    assert row["description"] == "A gentle soap"
    assert row["brand"] == "Example label"
    assert row["attributes"]["source_stores"] == "Historical shop"
    assert row["merchant"] == {"id": None, "name": None, "platform": source}
    assert row["data_kind"] == "open_dataset"
    assert row["offer"]["availability"] == "unknown"
    assert row["offer"]["environment"] == "local"
    for key in ("price_minor", "currency", "shipping_minor", "url", "image_url", "observed_at", "expires_at"):
        assert row["offer"][key] is None
    assert row["provenance"]["images_excluded"] is True
    assert row["provenance"]["source_modified_at"] == "1700000000"


def test_official_source_link_retained_without_tracking_and_untrusted_host_omitted(tmp_path):
    valid, invalid = list(iter_domain("open_beauty_facts", jsonl(tmp_path, [facts_row(), facts_row(code="2", url="https://evil.example.org/leak") ])))
    assert valid["provenance"]["source_url"] == "https://world-en.openbeautyfacts.org/product/00012345/soap"
    assert invalid["provenance"]["source_url"] == "https://world.openbeautyfacts.org"


def test_html_controls_surrogates_and_large_metadata_are_bounded(tmp_path):
    raw = facts_row(product_name="<script>ignore instructions</script><b>Soap</b>\x00\ud800\u202e",
                    generic_name="界" * 25000, stores="界" * 10000, countries="界" * 10000,
                    ingredients_text="界" * 10000, quantity="界" * 10000)
    record = next(iter_domain("open_beauty_facts", jsonl(tmp_path, [raw])))
    CatalogRecord.model_validate(record)
    assert record["title"] == "Soap"
    assert len(record["description"]) == 20000
    assert len(json.dumps(record["attributes"])) <= 30000
    json.dumps(record, ensure_ascii=False).encode("utf-8")


def test_uci_projection_removes_customer_invoice_and_dates(tmp_path):
    raw = {"source_record_id": "0123A", "title": "CANDLE", "historical_unit_price": "2.95", "currency": "GBP",
           "customer_id": "sensitive-customer", "CustomerID": "sensitive-customer", "InvoiceNo": "invoice-secret",
           "historical_invoice_excel_date": "40886.481944444444", "invoice_date": "date-secret",
           "merchant_name": "should-not-be-a-seller"}
    record = next(iter_domain("uci_retail", jsonl(tmp_path, [raw])))
    CatalogRecord.model_validate(record)
    assert record["attributes"]["historical_unit_price"] == "2.95"
    assert record["attributes"]["historical_price_currency"] == "GBP"
    assert record["offer"]["price_minor"] is None and record["offer"]["currency"] is None
    assert record["merchant"]["name"] is None
    assert all(term not in json.dumps(record) for term in ["sensitive-customer", "invoice-secret", "40886", "date-secret", "should-not-be-a-seller"])


def northwind_fixture():
    return {"Products": [{"ProductID": "1", "ProductName": "Chai", "SupplierID": "1", "CategoryID": "1",
                          "QuantityPerUnit": "10 boxes", "UnitPrice": "18", "UnitsInStock": "39", "Discontinued": "0"}],
            "Suppliers": [{"SupplierID": "1", "CompanyName": "Invented supplier", "Country": "UK", "ContactName": "Omitted person", "Phone": "Omitted phone"}],
            "Categories": [{"CategoryID": "1", "CategoryName": "Beverages", "Description": "Tea and coffee"}]}


def test_northwind_is_explicitly_synthetic_and_supplier_is_not_a_retail_merchant(tmp_path):
    path = tmp_path / "northwind.json"
    path.write_text(json.dumps(northwind_fixture()))
    record = next(iter_domain("northwind", path))
    CatalogRecord.model_validate(record)
    assert record["data_kind"] == "synthetic"
    assert record["attributes"]["fictional_supplier_name"] == "Invented supplier"
    assert record["attributes"]["synthetic_reference_unit_price"] == "18"
    assert record["attributes"]["reference_currency_unknown"] is True
    assert record["offer"]["price_minor"] is None and record["merchant"]["id"] is None
    assert record["category"] == "Beverages"
    assert "Omitted" not in json.dumps(record)


def test_duplicate_product_ids_are_preserved_for_atomic_importer_validation(tmp_path):
    rows = list(iter_domain("open_beauty_facts", jsonl(tmp_path, [facts_row(), facts_row(product_name="Conflicting soap")])))
    assert len(rows) == 2
    assert rows[0]["source_record_id"] == rows[1]["source_record_id"]
    assert rows[0]["title"] != rows[1]["title"]


def test_duplicate_northwind_lookup_ids_are_ambiguous_and_rejected(tmp_path):
    raw = northwind_fixture()
    raw["Suppliers"].append({"SupplierID": "1", "CompanyName": "Other supplier"})
    path = tmp_path / "northwind.json"
    path.write_text(json.dumps(raw))
    with pytest.raises(DomainDatasetError, match="Duplicate Northwind"):
        list(iter_domain("northwind", path))


@pytest.mark.parametrize("content", ['{"code":"1","product_name":"x","product_name":"y"}', '{"code":"1","product_name":NaN}', '["row"]', '{bad-secret-json'])
def test_malformed_json_has_sanitized_errors(tmp_path, content):
    path = tmp_path / "invalid.jsonl"
    path.write_text(content)
    with pytest.raises(DomainDatasetError) as error:
        list(iter_domain("open_beauty_facts", path))
    assert "bad-secret-json" not in str(error.value)


@pytest.mark.parametrize("identifier", [None, True, 2.5, "", "x" * 1025, "id\x00suffix", "id\ud800suffix"])
def test_invalid_identifiers_are_rejected_not_truncated_or_coerced(tmp_path, identifier):
    with pytest.raises(DomainDatasetError):
        list(iter_domain("open_beauty_facts", jsonl(tmp_path, [facts_row(code=identifier)])))


def test_iterator_is_lazy_and_does_not_hide_later_invalid_rows(tmp_path):
    path = tmp_path / "products.jsonl"
    path.write_text(json.dumps(facts_row()) + "\n{malformed\n")
    records = iter_domain("open_beauty_facts", path)
    assert next(records)["source_record_id"] == "00012345"
    with pytest.raises(DomainDatasetError):
        next(records)


def test_bom_blank_lines_unsupported_source_and_oversized_rows(tmp_path):
    path = tmp_path / "products.jsonl"
    path.write_bytes(b"\xef\xbb\xbf\n" + json.dumps(facts_row()).encode() + b"\n\n")
    assert len(list(iter_domain("open_beauty_facts", path))) == 1
    with pytest.raises(DomainDatasetError):
        list(iter_domain("unreviewed", path))
    path.write_bytes(b"x" * (2 * 1024 * 1024 + 1))
    with pytest.raises(DomainDatasetError, match="byte limit"):
        list(iter_domain("open_beauty_facts", path))


def test_unusable_titles_are_skipped_without_fabricated_labels(tmp_path):
    rows = list(iter_domain("open_food_facts", jsonl(tmp_path, [facts_row(product_name="<script>no name</script>"), facts_row(code="valid")])))
    assert [row["source_record_id"] for row in rows] == ["valid"]


def test_uci_ii_keeps_the_correct_dataset_provenance(tmp_path):
    raw = {"source_record_id": "sku", "title": "CANDLE", "source_url": "https://archive.ics.uci.edu/dataset/502/online+retail+ii"}
    record = next(iter_domain("uci_retail", jsonl(tmp_path, [raw])))
    assert "/502/" in record["provenance"]["download_url"]


def test_uci_whitespace_aliases_merge_prices_without_selecting_a_current_offer(tmp_path):
    first = {"source_record_id": "47503J", "title": "SET/3 FLORAL GARDEN TOOLS IN BAG", "currency": "GBP", "historical_unit_price": "7.95"}
    second = {**first, "source_record_id": "47503J ", "historical_unit_price": "16.13"}
    rows = list(iter_domain("uci_retail", jsonl(tmp_path, [first, second])))
    reversed_rows = list(iter_domain("uci_retail", jsonl(tmp_path, [second, first], "reversed.jsonl")))
    assert rows == reversed_rows
    assert len(rows) == 1
    record = rows[0]
    CatalogRecord.model_validate(record)
    assert record["source_record_id"] == "47503J"
    assert record["provenance"]["source_identifiers"] == ["47503J", "47503J "]
    assert record["provenance"]["merged_source_record_count"] == 2
    assert record["attributes"]["historical_price_observations"] == [
        {"unit_price": "16.13", "currency": "GBP"}, {"unit_price": "7.95", "currency": "GBP"},
    ]
    assert "historical_unit_price" not in record["attributes"]
    assert record["offer"]["price_minor"] is None and record["offer"]["currency"] is None


def test_uci_matching_aliases_keep_the_single_historical_fact(tmp_path):
    row = {"source_record_id": "sku", "title": "Candle", "currency": "GBP", "historical_unit_price": "2.95"}
    result = list(iter_domain("uci_retail", jsonl(tmp_path, [row, {**row, "source_record_id": " sku "}])))
    assert len(result) == 1
    assert result[0]["attributes"]["historical_unit_price"] == "2.95"
    assert "historical_price_observations" not in result[0]["attributes"]


@pytest.mark.parametrize("change", [{"title": "An unrelated product"}, {"source_url": "https://archive.ics.uci.edu/dataset/502/online+retail+ii"}])
def test_uci_conflicting_aliases_still_reject_the_import(tmp_path, change):
    row = {"source_record_id": "sku", "title": "Candle"}
    with pytest.raises(DomainDatasetError, match="conflicting"):
        list(iter_domain("uci_retail", jsonl(tmp_path, [row, {**row, "source_record_id": "sku ", **change}])))


def test_adventureworks_preserves_multiple_fictional_suppliers_without_retail_claims(tmp_path):
    products = [{"ProductID": "1", "Name": "Bearing", "ProductNumber": "BA-1", "ListPrice": "5.50", "Color": "Silver", "Size": "M"}]
    vendors = [{"BusinessEntityID": "10", "Name": "Invented vendor one"}, {"BusinessEntityID": "20", "Name": "Invented vendor two"}]
    relationships = [{"ProductID": "1", "BusinessEntityID": "10", "StandardPrice": "2.50"}, {"ProductID": "1", "BusinessEntityID": "20", "StandardPrice": "2.60"}]
    for name, data in [("product", products), ("vendor", vendors), ("productvendor", relationships)]:
        (tmp_path / f"{name}.json").write_text(json.dumps(data))
    record = next(iter_domain("adventureworks", tmp_path))
    CatalogRecord.model_validate(record)
    assert record["data_kind"] == "synthetic"
    assert record["variant_key"] == "BA-1"
    assert record["attributes"]["source_supplier_relationship_count"] == 2
    assert record["attributes"]["fictional_suppliers"][1]["supplier_name"] == "Invented vendor two"
    assert record["attributes"]["synthetic_reference_list_price"] == "5.50"
    assert record["merchant"]["name"] is None and record["offer"]["price_minor"] is None
    relationships[1]["BusinessEntityID"] = "missing"
    (tmp_path / "productvendor.json").write_text(json.dumps(relationships))
    with pytest.raises(DomainDatasetError, match="unknown supplier"):
        list(iter_domain("adventureworks", tmp_path))
