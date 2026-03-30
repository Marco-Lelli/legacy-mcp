"""Tests for collector JSON format -- _metadata.collection_summary (v1.5+)."""

import json
import pytest
from pathlib import Path

from legacy_mcp.storage.loader import JsonLoader
from legacy_mcp.storage.queries import QueryEngine


COLLECTION_SUMMARY_FIELDS = {"sections_ok", "sections_warn", "sections_error", "log_file"}


@pytest.fixture
def json_with_summary(tmp_path: Path) -> Path:
    data = {
        "_metadata": {
            "module": "ad-core",
            "version": "1.0",
            "forest": "contoso.local",
            "collected_at": "2026-03-30T14:23:11Z",
            "collector_version": "1.5",
            "collected_by": "CONTOSO\\svc-collector",
            "collection_summary": {
                "sections_ok": 25,
                "sections_warn": 1,
                "sections_error": 1,
                "log_file": "C:\\output\\contoso.local_ad-data.log",
            },
        },
        "forest": {"Name": "contoso.local", "ForestMode": "Windows2016Forest"},
        "users": [
            {"SamAccountName": "alice", "Enabled": "True"},
        ],
    }
    p = tmp_path / "contoso.local_ad-data.json"
    p.write_text(json.dumps(data))
    return p


def test_metadata_collection_summary_exists(json_with_summary: Path) -> None:
    """_metadata must contain a collection_summary block."""
    with json_with_summary.open() as fh:
        data = json.load(fh)
    assert "collection_summary" in data["_metadata"]


def test_metadata_collection_summary_fields(json_with_summary: Path) -> None:
    """collection_summary must contain exactly the four expected fields."""
    with json_with_summary.open() as fh:
        data = json.load(fh)
    summary = data["_metadata"]["collection_summary"]
    assert set(summary.keys()) >= COLLECTION_SUMMARY_FIELDS


def test_metadata_collection_summary_types(json_with_summary: Path) -> None:
    """sections_ok/warn/error must be integers; log_file must be a non-empty string."""
    with json_with_summary.open() as fh:
        data = json.load(fh)
    summary = data["_metadata"]["collection_summary"]
    assert isinstance(summary["sections_ok"], int)
    assert isinstance(summary["sections_warn"], int)
    assert isinstance(summary["sections_error"], int)
    assert isinstance(summary["log_file"], str) and summary["log_file"]


def test_loader_accepts_json_with_collection_summary(json_with_summary: Path) -> None:
    """Loader must handle JSON with _metadata.collection_summary without errors."""
    db = JsonLoader(json_with_summary).load()
    engine = QueryEngine(db, source="contoso.local")
    assert "forest" in engine.tables()
    assert "users" in engine.tables()


def test_log_file_path_is_absolute(json_with_summary: Path) -> None:
    """log_file in collection_summary must be an absolute path.

    The collector uses Join-Path + GetFullPath to resolve the default output
    path relative to the script directory (not the process working directory).
    The resulting log_file written into _metadata must therefore be absolute,
    ensuring the server can locate it regardless of where the JSON is loaded from.
    """
    with json_with_summary.open() as fh:
        data = json.load(fh)
    log_file = data["_metadata"]["collection_summary"]["log_file"]
    assert Path(log_file).is_absolute(), (
        f"log_file must be an absolute path, got: {log_file!r}"
    )
