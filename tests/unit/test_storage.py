"""Unit tests for JSON → SQLite storage layer."""

import json
import pytest
from pathlib import Path

from legacy_mcp.storage.loader import JsonLoader, _strip_ps_artefacts
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


# ---------------------------------------------------------------------------
# PS artefact stripping
# ---------------------------------------------------------------------------

_PS_FIELDS = ["PSComputerName", "PSShowComputerName", "RunspaceId"]


class TestStripPsArtefacts:
    """Unit tests for _strip_ps_artefacts() and its integration in JsonLoader."""

    def _make_dc_row(self, nested_key: str, extra_fields: dict) -> dict:
        item = {"name": "AD-Domain-Services"}
        item.update(extra_fields)
        return {"DC": "dc01.contoso.local", "Status": "OK", nested_key: [item]}

    def test_features_ps_fields_removed(self) -> None:
        rows = [self._make_dc_row("Features", {f: "val" for f in _PS_FIELDS})]
        _strip_ps_artefacts("dc_windows_features", rows)
        for field in _PS_FIELDS:
            assert field not in rows[0]["Features"][0]

    def test_services_ps_fields_removed(self) -> None:
        item = {"name": "NTDS", "PSComputerName": "dc01", "RunspaceId": "abc"}
        rows = [{"DC": "dc01.contoso.local", "Status": "OK", "Services": [item]}]
        _strip_ps_artefacts("dc_services", rows)
        assert "PSComputerName" not in rows[0]["Services"][0]
        assert "RunspaceId" not in rows[0]["Services"][0]
        assert rows[0]["Services"][0]["name"] == "NTDS"

    def test_software_ps_fields_removed(self) -> None:
        item = {"name": "7-Zip", "PSShowComputerName": True, "RunspaceId": "xyz"}
        rows = [{"DC": "dc01.contoso.local", "Status": "OK", "Software": [item]}]
        _strip_ps_artefacts("dc_installed_software", rows)
        assert "PSShowComputerName" not in rows[0]["Software"][0]
        assert rows[0]["Software"][0]["name"] == "7-Zip"

    def test_no_exception_when_fields_absent(self) -> None:
        rows = [{"DC": "dc01.contoso.local", "Status": "OK", "Features": [{"name": "AD-DS"}]}]
        _strip_ps_artefacts("dc_windows_features", rows)  # must not raise
        assert rows[0]["Features"][0]["name"] == "AD-DS"

    def test_non_dc_inventory_section_unaffected(self) -> None:
        rows = [{"SamAccountName": "alice", "PSComputerName": "dc01"}]
        _strip_ps_artefacts("users", rows)
        # users section is not in the target list — field must remain untouched
        assert rows[0]["PSComputerName"] == "dc01"

    def test_loader_strips_ps_fields_on_load(self, tmp_path: Path) -> None:
        """End-to-end: PS* fields in a JSON fixture are absent after loading."""
        data = {
            "dc_windows_features": [
                {
                    "DC": "dc01.contoso.local",
                    "Status": "OK",
                    "Features": [
                        {
                            "name": "AD-Domain-Services",
                            "display_name": "Active Directory Domain Services",
                            "PSComputerName": "dc01.contoso.local",
                            "PSShowComputerName": False,
                            "RunspaceId": "a1b2c3d4-0000-0000-0000-000000000000",
                        }
                    ],
                }
            ]
        }
        p = tmp_path / "ps-artefact-test.json"
        p.write_text(json.dumps(data))

        db = JsonLoader(p).load()
        engine = QueryEngine(db, source="test")
        rows = engine.query("dc_windows_features")
        assert len(rows) == 1
        # QueryEngine deserializes JSON columns — Features is already a list.
        features = rows[0]["Features"]
        if isinstance(features, str):
            features = json.loads(features)
        assert len(features) == 1
        feat = features[0]
        assert feat["name"] == "AD-Domain-Services"
        for ps_field in _PS_FIELDS:
            assert ps_field not in feat, f"PS artefact field {ps_field!r} was not stripped"
