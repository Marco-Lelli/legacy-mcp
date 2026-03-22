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


class TestQueryPage:
    """Tests for the paginated query_page() method."""

    @pytest.fixture
    def engine(self, sample_json: Path) -> QueryEngine:
        db = JsonLoader(sample_json).load()
        return QueryEngine(db, source="contoso.local")

    def test_returns_dict_contract(self, engine: QueryEngine) -> None:
        result = engine.query_page("users")
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_total_matches_all_rows(self, engine: QueryEngine) -> None:
        result = engine.query_page("users")
        assert result["total"] == 2

    def test_items_are_list(self, engine: QueryEngine) -> None:
        result = engine.query_page("users")
        assert isinstance(result["items"], list)
        assert len(result["items"]) == 2

    def test_default_offset_and_limit(self, engine: QueryEngine) -> None:
        result = engine.query_page("users")
        assert result["offset"] == 0
        assert result["limit"] == 200

    def test_has_more_false_when_all_fit(self, engine: QueryEngine) -> None:
        result = engine.query_page("users")
        assert result["has_more"] is False

    def test_pagination_limit_one(self, engine: QueryEngine) -> None:
        first  = engine.query_page("users", offset=0, limit=1)
        second = engine.query_page("users", offset=1, limit=1)
        assert len(first["items"]) == 1
        assert len(second["items"]) == 1
        assert first["has_more"] is True
        assert second["has_more"] is False
        assert first["total"] == second["total"] == 2

    def test_filter_applied_before_pagination(self, engine: QueryEngine) -> None:
        result = engine.query_page("users", Enabled="True")
        assert result["total"] == 1
        assert result["items"][0]["SamAccountName"] == "alice"
        assert result["has_more"] is False

    def test_offset_beyond_total(self, engine: QueryEngine) -> None:
        result = engine.query_page("users", offset=999)
        assert result["items"] == []
        assert result["total"] == 2
        assert result["has_more"] is False

    def test_missing_section_returns_empty(self, engine: QueryEngine) -> None:
        result = engine.query_page("nonexistent")
        assert result == {
            "items": [], "total": 0, "offset": 0, "limit": 200, "has_more": False
        }
