"""Licensed bundle isolation, attribution, reproducibility and publication checks."""
from copy import deepcopy
import gzip
import hashlib
import json
from pathlib import Path
import time
from zipfile import ZipFile

import pytest

from backend.app.catalog import service
from backend.app.catalog.registry import DATASET_SOURCES
from backend.app.catalog.synthetic import iter_synthetic
from backend.app.db import Base, CatalogImport, CatalogProduct, SavedItem, make_database
from scripts.import_catalog_bundle import CatalogBundleImportError, import_catalog_bundle
from scripts.package_catalogs import BUNDLE_NAME, LICENSES, CatalogBundleError, build_catalog_bundle


@pytest.fixture
def factory(tmp_path):
    engine, factory = make_database(f"sqlite:///{tmp_path/'bundle.db'}")
    Base.metadata.create_all(engine)
    yield factory
    engine.dispose()


@pytest.fixture
def restore_factory(tmp_path):
    engine, restore_factory = make_database(f"sqlite:///{tmp_path/'restore.db'}")
    Base.metadata.create_all(engine)
    yield restore_factory
    engine.dispose()


def record(source, identifier="one"):
    row = next(iter_synthetic(1))
    row.update(source_id=source, source_record_id=identifier, data_kind=DATASET_SOURCES[source].kind)
    row["merchant"]["platform"] = source
    row["offer"]["id"] = identifier
    if row["data_kind"] == "open_dataset":
        row["merchant"].update(id=None, name=None)
        row["offer"].update(price_minor=None, currency=None, shipping_minor=None, availability="unknown")
    return row


def ingest(factory, source="wands", count=1, version="fixture-v1", checksum="a"*64):
    return service.import_dataset(factory, source, [record(source, str(i)) for i in range(count)], version=version, checksum=checksum)


def test_bundle_is_source_separated_deterministic_and_excludes_private_and_affiliate_data(factory, tmp_path):
    for source, count in [("wands", 2), ("open_beauty_facts", 1), ("northwind", 1), ("synthetic", 3)]:
        ingest(factory, source, count)
    with factory.begin() as db:
        db.add(SavedItem(id="private-save", user_id="private-account", original_url="https://example.org/private",
                         canonical_url="https://example.org/private", title="PRIVATE_LIBRARY_SENTINEL", source="article",
                         note="PRIVATE_CUSTOMER_DATA_SENTINEL"))
    affiliate = deepcopy(next(iter_synthetic(1)))
    affiliate.update(source_id="impact", data_kind="merchant_feed", title="PRIVATE_AFFILIATE_SENTINEL")
    affiliate["merchant"]["platform"] = "impact"
    affiliate["offer"].update(environment="production", url="https://example.com/approved-product")
    affiliate["provenance"]["catalog_id"] = "approved-feed"
    service.import_snapshot(factory, "impact", "approved-feed", [affiliate], approval_reference="PRIVATE_APPROVAL_SENTINEL",
                            source_observed_at=time.time()-1, freshness_seconds=600)

    first = build_catalog_bundle(factory, output_directory=tmp_path/"dist")
    original_zip = first["archive"].read_bytes()
    second = build_catalog_bundle(factory, output_directory=tmp_path/"dist")
    assert second["archive"].read_bytes() == original_zip
    manifest = first["manifest"]
    assert manifest["total_records"] == 7
    assert {entry["source_id"] for entry in manifest["sources"]} == {"wands", "open_beauty_facts", "northwind", "synthetic"}

    with ZipFile(first["archive"]) as archive:
        names = archive.namelist()
        assert all(name.startswith(BUNDLE_NAME+"/") for name in names)
        assert not any("impact" in name or "cj." in name or ".db" in name or ".env" in name for name in names)
        for entry in manifest["sources"]:
            source = DATASET_SOURCES[entry["source_id"]]
            assert (entry["license_id"], entry["license_url"], entry["attribution"]) == (source.license_id, source.license_url, source.attribution)
            zipped = archive.read(f'{BUNDLE_NAME}/{entry["file"]}')
            assert zipped[4:8] == b"\0\0\0\0"  # gzip timestamp is deterministic.
            assert hashlib.sha256(zipped).hexdigest() == entry["sha256"]
            plain = gzip.decompress(zipped)
            assert hashlib.sha256(plain).hexdigest() == entry["uncompressed_sha256"]
            rows = [json.loads(line) for line in plain.splitlines()]
            assert len(rows) == entry["row_count"]
            assert all(row["source_id"] == entry["source_id"] for row in rows)
            assert all(row["provenance"]["attribution"] == source.attribution for row in rows)
            assert entry["version"] == "fixture-v1" and entry["source_checksum"] == "a"*64
            assert b"PRIVATE_" not in plain
        assert archive.read(f"{BUNDLE_NAME}/LICENSES/WANDS-MIT.txt") == (LICENSES/"WANDS-MIT.txt").read_bytes()
        assert b"Copyright (c) 2021 ecir2022" in archive.read(f"{BUNDLE_NAME}/LICENSES/WANDS-MIT.txt")
        assert b"Copyright (c) Microsoft Corporation" in archive.read(f"{BUNDLE_NAME}/LICENSES/Microsoft-MIT.txt")
        assert b"Open Database License" in archive.read(f"{BUNDLE_NAME}/LICENSES/ODbL-1.0.txt")
        for notice in manifest["licenses"]:
            data = archive.read(f'{BUNDLE_NAME}/{notice["file"]}')
            assert hashlib.sha256(data).hexdigest() == notice["sha256"]
    assert not list((tmp_path/"dist").glob(".catalog-bundle-*"))


def test_missing_license_does_not_replace_previous_handoff(factory, tmp_path):
    ingest(factory)
    result = build_catalog_bundle(factory, output_directory=tmp_path/"dist")
    previous = result["archive"].read_bytes()
    with pytest.raises(CatalogBundleError, match="Missing reviewed license"):
        build_catalog_bundle(factory, output_directory=tmp_path/"dist", license_directory=tmp_path/"absent")
    assert result["archive"].read_bytes() == previous


def test_changed_source_during_export_aborts_publication(factory, tmp_path, monkeypatch):
    ingest(factory)
    original_export = service.export_dataset
    def changed_export(active_factory, source_id):
        for line in original_export(active_factory, source_id):
            yield line
            ingest(factory, source_id, version="fixture-v2", checksum="b"*64)
    monkeypatch.setattr(service, "export_dataset", changed_export)
    with pytest.raises(CatalogBundleError, match="changed while exporting"):
        build_catalog_bundle(factory, output_directory=tmp_path/"dist")
    assert not (tmp_path/"dist"/f"{BUNDLE_NAME}.zip").exists()


def test_mismatched_rights_in_database_are_not_silently_packaged(factory, tmp_path):
    ingest(factory)
    with factory.begin() as db:
        product = db.query(CatalogProduct).one()
        altered = deepcopy(product.record)
        altered["provenance"]["license_id"] = "invented-license"
        product.record = altered
    with pytest.raises(CatalogBundleError, match="rights metadata"):
        build_catalog_bundle(factory, output_directory=tmp_path/"dist")


def test_unconfigured_or_revoked_datasets_are_not_exported(factory, tmp_path):
    with pytest.raises(CatalogBundleError, match="Import at least one"):
        build_catalog_bundle(factory, output_directory=tmp_path/"dist")
    ingest(factory)
    service.revoke_feed(factory, "wands", "local-dataset")
    with pytest.raises(CatalogBundleError, match="Import at least one"):
        build_catalog_bundle(factory, output_directory=tmp_path/"dist")


def test_abo_includes_dataset_builder_credits_and_full_cc_by_license(factory, tmp_path):
    ingest(factory, source="abo")
    result = build_catalog_bundle(factory, output_directory=tmp_path/"dist")
    source = result["manifest"]["sources"][0]
    assert source["license_files"] == ["LICENSES/ABO-NOTICE.txt", "LICENSES/CC-BY-4.0.txt"]
    with ZipFile(result["archive"]) as archive:
        notice = archive.read(f"{BUNDLE_NAME}/LICENSES/ABO-NOTICE.txt").decode()
        for credit in ["Amazon.com", "Matthieu Guillaumin (Amazon.com)", "Thomas Dideriksen (Amazon.com)",
                       "Kenan Deng (Amazon.com)", "Himanshu Arora (Amazon.com)",
                       "Jasmine Collins (UC Berkeley)", "Jitendra Malik (UC Berkeley)"]:
            assert credit in notice
        assert "https://creativecommons.org/licenses/by/4.0/" in notice
        assert "Changes made by Mymah Finds" in notice
        assert archive.read(f"{BUNDLE_NAME}/LICENSES/CC-BY-4.0.txt") == (LICENSES/"CC-BY-4.0.txt").read_bytes()


@pytest.mark.parametrize("source_id", ["open_beauty_facts", "open_products_facts", "open_food_facts"])
def test_open_facts_retains_database_and_contents_license_notices(factory, tmp_path, source_id):
    ingest(factory, source=source_id)
    result = build_catalog_bundle(factory, output_directory=tmp_path/"dist")
    source = result["manifest"]["sources"][0]
    assert source["license_id"] == "ODbL-1.0"
    assert source["contents_license_id"] == "DbCL-1.0"
    assert source["contents_license_url"] == "https://opendatacommons.org/licenses/dbcl/1.0/"
    assert source["license_files"] == ["LICENSES/ODbL-1.0.txt", "LICENSES/DbCL-1.0.txt"]
    with ZipFile(result["archive"]) as archive:
        notice = archive.read(f"{BUNDLE_NAME}/LICENSES/DbCL-1.0.txt")
        assert notice == (LICENSES/"DbCL-1.0.txt").read_bytes()
        assert b"2.2 Conditions of Use. You must comply with the ODbL." in notice


def test_bundle_restores_sources_without_touching_private_library(factory, restore_factory, tmp_path):
    ingest(factory, source="wands", count=2)
    ingest(factory, source="synthetic", count=3)
    result = build_catalog_bundle(factory, output_directory=tmp_path/"dist")
    with restore_factory.begin() as db:
        db.add(SavedItem(id="private-save", user_id="private-account", original_url="https://example.org/private",
                         canonical_url="https://example.org/private", title="My saved content", source="article",
                         note="Preserve my note"))
    summaries = import_catalog_bundle(restore_factory, result["directory"])
    assert summaries == [{"source_id": "synthetic", "row_count": 3, "unchanged": False},
                         {"source_id": "wands", "row_count": 2, "unchanged": False}]
    with restore_factory() as db:
        assert db.query(CatalogProduct).count() == 5
        saved = db.get(SavedItem, "private-save")
        assert (saved.user_id, saved.title, saved.note) == ("private-account", "My saved content", "Preserve my note")
        for row in db.query(CatalogProduct).all():
            assert row.record["provenance"]["attribution"] == DATASET_SOURCES[row.record["source_id"]].attribution
    assert all(item["unchanged"] for item in import_catalog_bundle(restore_factory, result["directory"]))


@pytest.mark.parametrize("tamper", [
    "format", "schema", "duplicate_source", "too_many_sources", "unknown_source", "affiliate_source",
    "traversal", "absolute_path", "wrong_filename", "invalid_sha", "empty_version", "long_version",
    "control_version", "zero_rows", "too_many_rows", "bool_rows", "rights", "oversized_manifest",
    "duplicate_json_key", "symlink_manifest", "symlink_source", "corrupt_last_source",
])
def test_bundle_restore_rejects_tampering_before_any_database_writes(factory, restore_factory, tmp_path, tamper):
    ingest(factory, source="synthetic")
    ingest(factory, source="wands")
    bundle = build_catalog_bundle(factory, output_directory=tmp_path/"dist")
    directory, manifest = bundle["directory"], deepcopy(bundle["manifest"])
    entry = manifest["sources"][-1]
    mutations = {
        "format": lambda: manifest.update(format_version=True),
        "schema": lambda: manifest.update(record_schema="execute-sql"),
        "duplicate_source": lambda: manifest["sources"].append(deepcopy(entry)),
        "too_many_sources": lambda: manifest.update(sources=[entry]*21),
        "unknown_source": lambda: entry.update(source_id="unknown"),
        "affiliate_source": lambda: entry.update(source_id="impact"),
        "traversal": lambda: entry.update(file="../wands.jsonl.gz"),
        "absolute_path": lambda: entry.update(file=str(directory/"wands.jsonl.gz")),
        "wrong_filename": lambda: entry.update(file="synthetic.jsonl.gz"),
        "invalid_sha": lambda: entry.update(sha256="f"*63),
        "empty_version": lambda: entry.update(version=""),
        "long_version": lambda: entry.update(version="x"*201),
        "control_version": lambda: entry.update(version="v1\n"),
        "zero_rows": lambda: entry.update(row_count=0),
        "too_many_rows": lambda: entry.update(row_count=1000001),
        "bool_rows": lambda: entry.update(row_count=True),
        "rights": lambda: entry.update(license_id="invented"),
    }
    if tamper in mutations:
        mutations[tamper]()
    manifest_path = directory/"manifest.json"
    manifest_path.write_text(json.dumps(manifest))
    if tamper == "oversized_manifest":
        manifest_path.write_text(" "*(256*1024+1))
    elif tamper == "duplicate_json_key":
        manifest_path.write_text('{"format_version":1,"format_version":1}')
    elif tamper in {"symlink_manifest", "symlink_source"}:
        path = manifest_path if tamper == "symlink_manifest" else directory/entry["file"]
        target = tmp_path/"outside-file"
        path.rename(target)
        path.symlink_to(target)
    elif tamper == "corrupt_last_source":
        with (directory/entry["file"]).open("ab") as handle:
            handle.write(b"tampered")
    with pytest.raises((CatalogBundleImportError, OSError)):
        import_catalog_bundle(restore_factory, directory)
    with restore_factory() as db:
        assert db.query(CatalogProduct).count() == 0
        assert db.query(CatalogImport).count() == 0


def test_bundle_count_mismatch_rolls_back_only_failing_source(factory, restore_factory, tmp_path):
    ingest(factory, source="synthetic", count=3)
    ingest(factory, source="wands", count=2)
    ingest(restore_factory, source="wands", count=1, version="prior-version")
    with restore_factory() as db:
        original = [(row.id, deepcopy(row.record)) for row in db.query(CatalogProduct).all()]
    bundle = build_catalog_bundle(factory, output_directory=tmp_path/"dist")
    manifest = deepcopy(bundle["manifest"])
    manifest["sources"][-1]["row_count"] += 1
    (bundle["directory"]/"manifest.json").write_text(json.dumps(manifest))
    completed = []
    with pytest.raises(service.CatalogError) as error:
        import_catalog_bundle(restore_factory, bundle["directory"], on_result=completed.append)
    assert error.value.code == "dataset_count_mismatch"
    assert completed == [{"source_id": "synthetic", "row_count": 3, "unchanged": False}]
    with restore_factory() as db:
        retained = [(row.id, row.record) for row in db.query(CatalogProduct).all() if row.record["source_id"] == "wands"]
        assert retained == original
        assert db.query(CatalogProduct).count() == 4
        assert db.query(CatalogImport).count() == 2
