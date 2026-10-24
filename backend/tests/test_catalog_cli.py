"""Exercise the operator CLI with invented local exports; no account access."""
import csv
from datetime import datetime, timezone
import json
import time

import httpx
import pytest
from sqlalchemy import func, select

from backend.app.catalog.cli import main
from backend.app.db import Base, CatalogFeed, CatalogImport, CatalogMerchant, CatalogOffer, CatalogProduct, make_database


RAW_MARKER = "PRIVATE-EXPORT-CONTENT-DO-NOT-LOG"


@pytest.fixture
def catalog_database(tmp_path, monkeypatch):
    database_url = f"sqlite:///{tmp_path / 'cli.db'}"
    monkeypatch.setenv("DATABASE_URL", database_url)
    engine, factory = make_database(database_url)
    Base.metadata.create_all(engine)

    def unexpected_network(*_, **__):
        pytest.fail("The import/revoke CLI must not perform network requests")

    monkeypatch.setattr(httpx.Client, "send", unexpected_network)
    yield factory
    engine.dispose()


def write_export(tmp_path, source, *, malformed=False, invalid_contract=False):
    path = tmp_path / f"{source}-export.{ 'csv' if source == 'impact' else 'json'}"
    link = "https://merchant.example.com/items/invented?affiliate=preserve%2Fthis"
    if invalid_contract:
        link = f"https://reserved.test/{RAW_MARKER}"
    if source == "impact":
        row = {
            "Unique Merchant SKU": "invented-sku", "Product Name": "Invented reading lamp",
            "Product Description": RAW_MARKER, "Current Price": RAW_MARKER if malformed else "19.99",
            "Currency": "SGD", "Product URL": link, "Stock Availability": "In Stock",
        }
        with path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(row))
            writer.writeheader()
            writer.writerow(row)
    else:
        row = {"id": "invented-sku", "catalogId": "invented-catalog", "advertiserId": "invented-merchant",
               "title": "Invented reading lamp", "description": RAW_MARKER,
               "price": {"amount": "19.99", "currency": "SGD"}, "linkCode": {"clickUrl": link}}
        body = {"data": {"products": {"resultList": [row]}}}
        if malformed:
            body["errors"] = [{"message": RAW_MARKER}]
        path.write_text(json.dumps(body), encoding="utf-8")
    return path


def import_args(path, source, observed_at):
    return [
        "import", "--source", source, "--catalog-id", "invented-catalog", "--file", str(path),
        "--merchant-id", "invented-merchant", "--merchant-name", "Invented Merchant",
        "--approval-reference", "invented-merchant-approval", "--freshness-seconds", "3600",
        "--source-observed-at", datetime.fromtimestamp(observed_at, timezone.utc).isoformat(),
    ]


def run_cli(args, capsys, expected_code=0):
    assert main(args) == expected_code
    captured = capsys.readouterr()
    assert RAW_MARKER not in captured.out + captured.err
    if expected_code == 0:
        assert captured.err == ""
        return json.loads(captured.out)
    assert captured.out == ""
    return json.loads(captured.err)


def database_state(factory):
    with factory() as db:
        counts = tuple(db.scalar(select(func.count()).select_from(model)) for model in
                       (CatalogFeed, CatalogImport, CatalogMerchant, CatalogProduct, CatalogOffer))
        records = [row.record for row in db.scalars(select(CatalogProduct).order_by(CatalogProduct.id))]
        return counts, records


@pytest.mark.parametrize("source", ["impact", "cj"])
def test_real_export_import_replay_revoke_and_new_snapshot_reactivation(catalog_database, tmp_path, capsys, source):
    factory = catalog_database
    observed = time.time() - 5
    path = write_export(tmp_path, source)
    args = import_args(path, source, observed)
    first = run_cli(args, capsys)
    assert first["row_count"] == 1 and first["unchanged"] is False
    assert first["expires_at"] == pytest.approx(observed + 3600, abs=0.001)
    counts, records = database_state(factory)
    assert counts == (1, 1, 1, 1, 1)
    assert records[0]["source_id"] == source
    assert records[0]["merchant"] == {"id": "invented-merchant", "name": "Invented Merchant", "platform": source}
    assert records[0]["offer"]["price_minor"] == 1999
    assert records[0]["offer"]["url"].endswith("?affiliate=preserve%2Fthis")
    assert records[0]["description"] == RAW_MARKER

    replay = run_cli(args, capsys)
    assert replay == {**first, "unchanged": True}
    assert database_state(factory) == (counts, records)

    revoked = run_cli(["revoke", "--source", source, "--catalog-id", "invented-catalog"], capsys)
    assert revoked == {"revoked": True, "source_id": source, "catalog_id": "invented-catalog"}
    assert database_state(factory) == ((1, 1, 0, 0, 0), [])
    with factory() as db:
        assert db.scalar(select(CatalogFeed)).enabled is False
    error = run_cli(args, capsys, expected_code=1)
    assert error["error"]["code"] == "feed_revoked"
    assert database_state(factory) == ((1, 1, 0, 0, 0), [])

    fresh = run_cli(import_args(path, source, time.time() - 1), capsys)
    assert fresh["import_id"] != first["import_id"] and fresh["unchanged"] is False
    assert database_state(factory)[0] == (1, 2, 1, 1, 1)


@pytest.mark.parametrize("source", ["impact", "cj"])
def test_expired_or_malformed_exports_preserve_current_catalog_and_sanitize_errors(catalog_database, tmp_path, capsys, source):
    factory = catalog_database
    observed = time.time() - 5
    path = write_export(tmp_path, source)
    run_cli(import_args(path, source, observed), capsys)
    previous = database_state(factory)

    expired = run_cli(import_args(path, source, observed - 86400), capsys, expected_code=1)
    assert expired["error"]["code"] == "expired_feed"
    assert database_state(factory) == previous

    write_export(tmp_path, source, malformed=True)
    malformed = run_cli(import_args(path, source, time.time() - 1), capsys, expected_code=1)
    assert malformed["error"]["code"] == ("invalid_price" if source == "impact" else "upstream_error")
    assert database_state(factory) == previous


@pytest.mark.parametrize("source", ["impact", "cj"])
def test_normalized_contract_failure_never_echoes_raw_source_content(catalog_database, tmp_path, capsys, source):
    path = write_export(tmp_path, source, invalid_contract=True)
    error = run_cli(import_args(path, source, time.time() - 1), capsys, expected_code=1)
    assert error["error"]["code"] == "invalid_record"
    assert database_state(catalog_database) == ((0, 0, 0, 0, 0), [])


def test_missing_file_failure_does_not_echo_its_path(catalog_database, tmp_path, capsys):
    path = tmp_path / f"{RAW_MARKER}.csv"
    error = run_cli(import_args(path, "impact", time.time() - 1), capsys, expected_code=1)
    assert error["error"]["code"] == "invalid_file"
    assert database_state(catalog_database) == ((0, 0, 0, 0, 0), [])


def test_source_timestamp_without_timezone_is_rejected_before_database_work(catalog_database, tmp_path, capsys):
    args = import_args(write_export(tmp_path, "impact"), "impact", time.time() - 1)
    args[-1] = "2026-10-25T12:00:00"
    with pytest.raises(SystemExit) as caught:
        main(args)
    assert caught.value.code == 2
    captured = capsys.readouterr()
    assert "timezone" in captured.err and RAW_MARKER not in captured.out + captured.err
    assert database_state(catalog_database) == ((0, 0, 0, 0, 0), [])
