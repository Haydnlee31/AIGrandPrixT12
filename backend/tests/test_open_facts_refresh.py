"""Full export acquisition cannot publish incomplete or conflicting snapshots."""
import gzip
import json
from pathlib import Path

import httpx
import pytest

from backend.app.catalog.open_facts_refresh import EXPORTS, RefreshError, refresh_source, validate_acquisition
from backend.app.catalog.datasets import normalized_rows
from scripts.refresh_open_facts import main


def archive(rows="001\t<b>Soap</b>\tExample\tReported store\n", header="code\tproduct_name\tbrands\tstores\n"):
    return gzip.compress((header + rows).encode())


class Body(httpx.SyncByteStream):
    def __init__(self, data):
        self.data = data

    def __iter__(self):
        yield self.data


def client_for(data, *, status=200, headers=None):
    def handle(request):
        assert str(request.url) == EXPORTS["open_products_facts"]
        assert request.headers["accept-encoding"] == "identity"
        assert "MymahFinds" in request.headers["user-agent"]
        return httpx.Response(status, stream=Body(data), headers={"content-length": str(len(data)), **(headers or {})})
    return httpx.Client(transport=httpx.MockTransport(handle))


def test_complete_export_normalizes_preserving_unknown_commerce_and_leading_zero(tmp_path):
    raw = archive(rows="001\t<b>Soap</b>\tExample\tReported store\n002\t\t\t\n001\t<b>Soap</b>\tExample\tReported store\n")
    with client_for(raw) as client:
        result = refresh_source("open_products_facts", tmp_path, client=client)
    assert result["complete_export"] is True
    assert result["raw_rows"] == 3
    assert result["unnamed_rows"] == result["duplicate_rows"] == result["row_count"] == 1
    root = Path(result["directory"])
    assert validate_acquisition(root)["normalized_sha256"] == result["normalized_sha256"]
    record, = list(normalized_rows(root / "catalog.jsonl"))
    assert record["source_record_id"] == "001" and record["title"] == "Soap"
    assert record["attributes"]["source_stores"] == "Reported store"
    assert record["merchant"]["name"] is None
    assert record["offer"]["price_minor"] is None
    assert record["offer"]["url"] is None
    assert record["offer"]["image_url"] is None
    assert record["offer"]["availability"] == "unknown"
    assert result["license_id"] == "ODbL-1.0"


@pytest.mark.parametrize("data,headers,expected", [
    (archive()[:-5], None, "invalid_export"),
    (archive(), {"content-length": "999"}, "incomplete_download"),
    (archive(header="code\tother\n", rows="1\tvalue\n"), None, "invalid_export_schema"),
    (archive(rows="1\tSoap\n"), None, "invalid_export_row"),
    (archive(rows="1\tSoap\t\t\n1\tDifferent\t\t\n"), None, "conflicting_identity"),
    (archive(rows="1\t\t\t\n"), None, "insufficient_records"),
    (b"<html>not gzip</html>", None, "invalid_export"),
])
def test_failed_acquisition_never_replaces_previous_snapshot(tmp_path, data, headers, expected):
    previous = tmp_path / "open_products_facts" / "prior" / "manifest.json"
    previous.parent.mkdir(parents=True)
    previous.write_text("preserved")
    with client_for(data, headers=headers) as client, pytest.raises(RefreshError) as error:
        refresh_source("open_products_facts", tmp_path, client=client)
    assert error.value.code == expected
    assert previous.read_text() == "preserved"
    assert list(previous.parent.parent.iterdir()) == [previous.parent]


@pytest.mark.parametrize("limits", [
    {"max_compressed_bytes": 10},
    {"max_uncompressed_bytes": 10},
    {"minimum_records": 2},
    {"timeout_seconds": -1},
])
def test_size_count_and_deadline_bounds_leave_no_partial_artifact(tmp_path, limits):
    with client_for(archive()) as client, pytest.raises(RefreshError):
        refresh_source("open_products_facts", tmp_path, client=client, **limits)
    assert list((tmp_path / "open_products_facts").iterdir()) == []


@pytest.mark.parametrize("status", [206, 302, 429, 503])
def test_no_partial_or_redirected_downloads_are_accepted(tmp_path, status):
    with client_for(archive(), status=status) as client, pytest.raises(RefreshError, match="HTTP 200"):
        refresh_source("open_products_facts", tmp_path, client=client)
    assert list((tmp_path / "open_products_facts").iterdir()) == []


def test_published_snapshots_are_distinct_and_audit_detects_corruption(tmp_path):
    with client_for(archive()) as client:
        first = refresh_source("open_products_facts", tmp_path, client=client)
        second = refresh_source("open_products_facts", tmp_path, client=client)
    assert first["directory"] != second["directory"]
    assert first["normalized_sha256"] == second["normalized_sha256"]
    assert validate_acquisition(first["directory"])["complete_export"]
    (Path(second["directory"]) / "catalog.jsonl").write_text("changed")
    with pytest.raises(RefreshError, match="changed"):
        validate_acquisition(second["directory"])


def test_food_facts_partial_sample_cannot_enter_full_export_refresh(tmp_path):
    with pytest.raises(RefreshError, match="Products Facts or Open Beauty"):
        refresh_source("open_food_facts", tmp_path)
    assert not list(tmp_path.iterdir())


@pytest.mark.parametrize("manifest", [[], {"source_id": []}, {"complete_export": False}])
def test_invalid_manifests_are_rejected_before_any_import(tmp_path, manifest):
    (tmp_path / "manifest.json").write_text(json.dumps(manifest))
    with pytest.raises(RefreshError, match="manifest"):
        validate_acquisition(tmp_path)


def test_dry_run_creates_no_files_or_network_calls(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(httpx.Client, "__init__", lambda *a, **kw: pytest.fail("Unexpected network client"))
    target = tmp_path / "does-not-exist"
    assert main(["--dry-run", "--output-dir", str(target)]) == 0
    result = json.loads(capsys.readouterr().out)
    assert result["modifies_database"] is False
    assert result["food_facts_sample"] == "preserved"
    assert len(result["sources"]) == 2
    assert not target.exists()
