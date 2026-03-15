"""Unit tests for JSON → SQLite storage layer."""

import json
import pytest
from pathlib import Path

from legacy_mcp.storage.loader import JsonLoader
from legacy_mcp.storage.queries import QueryEngine


@pytest.fixture
def sample_json(tmp_path: Path) -> Path:
    data = {
        "forest": {"Name": "contoso.local", "ForestMode": "Windows2016Forest"},
        "users": [
            {"SamAccountName": "alice", "Enabled": "True", "PasswordNeverExpires": "False"},
            {"SamAccountName": "bob",   "Enabled": "False", "PasswordNeverExpires": "True"},
        ],
        "dcs": [
            {"Name": "DC01", "HostName": "dc01.contoso.local", "IsGlobalCatalog": "True"},
        ],
    }
    p = tmp_path / "ad-data.json"
    p.write_text(json.dumps(data))
    return p


def test_loader_creates_tables(sample_json: Path) -> None:
    loader = JsonLoader(sample_json)
    db = loader.load()
    engine = QueryEngine(db, source="contoso.local")
    assert "users" in engine.tables()
    assert "dcs" in engine.tables()


def test_query_returns_rows(sample_json: Path) -> None:
    db = JsonLoader(sample_json).load()
    engine = QueryEngine(db, source="contoso.local")
    users = engine.query("users")
    assert len(users) == 2


def test_query_with_filter(sample_json: Path) -> None:
    db = JsonLoader(sample_json).load()
    engine = QueryEngine(db, source="contoso.local")
    enabled = engine.query("users", Enabled="True")
    assert len(enabled) == 1
    assert enabled[0]["SamAccountName"] == "alice"


def test_count(sample_json: Path) -> None:
    db = JsonLoader(sample_json).load()
    engine = QueryEngine(db, source="contoso.local")
    assert engine.count("users") == 2
    assert engine.count("nonexistent") == 0


def test_scalar_dict_section(sample_json: Path) -> None:
    db = JsonLoader(sample_json).load()
    engine = QueryEngine(db, source="contoso.local")
    forest = engine.query("forest")
    assert len(forest) == 1
    assert forest[0]["Name"] == "contoso.local"
