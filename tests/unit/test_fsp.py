"""Unit tests for the get_fsp MCP tool."""

from __future__ import annotations

from pathlib import Path

from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, Workspace, WorkspaceMode
from legacy_mcp.tools import fsp as fsp_module

FIXTURE_PATH = Path(__file__).resolve().parents[1] / "fixtures" / "contoso-sample.json"


class _MockMCP:
    def tool(self):
        def decorator(fn):
            setattr(self, fn.__name__, fn)
            return fn
        return decorator


import pytest


@pytest.fixture(scope="module")
def workspace() -> Workspace:
    forest = ForestConfig(
        name="contoso.local",
        relation=ForestRelation.STANDALONE,
        file=str(FIXTURE_PATH),
    )
    ws = Workspace(mode=WorkspaceMode.OFFLINE, forests=[forest])
    ws._init_connectors()
    return ws


@pytest.fixture(scope="module")
def tools(workspace: Workspace) -> _MockMCP:
    mcp = _MockMCP()
    fsp_module.register(mcp, workspace)
    return mcp


# ---------------------------------------------------------------------------
# get_fsp -- contract and defaults
# ---------------------------------------------------------------------------

class TestGetFspContract:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_fsp()
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_default_returns_all(self, tools: _MockMCP) -> None:
        result = tools.get_fsp()
        assert result["total"] == 2

    def test_default_limit_and_offset(self, tools: _MockMCP) -> None:
        result = tools.get_fsp()
        assert result["limit"] == 200
        assert result["offset"] == 0
        assert result["has_more"] is False

    def test_items_have_expected_fields(self, tools: _MockMCP) -> None:
        result = tools.get_fsp()
        for item in result["items"]:
            assert "Name" in item
            assert "IsOrphaned" in item


# ---------------------------------------------------------------------------
# get_fsp -- orphaned_only filter
# ---------------------------------------------------------------------------

class TestGetFspOrphanedFilter:

    def test_orphaned_only_returns_one(self, tools: _MockMCP) -> None:
        result = tools.get_fsp(orphaned_only=True)
        assert result["total"] == 1

    def test_orphaned_only_correct_record(self, tools: _MockMCP) -> None:
        result = tools.get_fsp(orphaned_only=True)
        item = result["items"][0]
        assert item["IsOrphaned"] == "True"
        assert item["ResolvedName"] is None

    def test_orphaned_only_all_items_are_orphaned(self, tools: _MockMCP) -> None:
        result = tools.get_fsp(orphaned_only=True)
        for item in result["items"]:
            assert item["IsOrphaned"] == "True"

    def test_non_orphaned_present_in_full_result(self, tools: _MockMCP) -> None:
        result = tools.get_fsp(orphaned_only=False)
        orphaned_values = {item["IsOrphaned"] for item in result["items"]}
        assert "False" in orphaned_values


# ---------------------------------------------------------------------------
# get_fsp -- pagination
# ---------------------------------------------------------------------------

class TestGetFspPagination:

    def test_limit_one_first_page(self, tools: _MockMCP) -> None:
        result = tools.get_fsp(limit=1, offset=0)
        assert len(result["items"]) == 1
        assert result["has_more"] is True
        assert result["total"] == 2

    def test_limit_one_second_page(self, tools: _MockMCP) -> None:
        result = tools.get_fsp(limit=1, offset=1)
        assert len(result["items"]) == 1
        assert result["has_more"] is False

    def test_offset_beyond_total(self, tools: _MockMCP) -> None:
        result = tools.get_fsp(offset=100)
        assert len(result["items"]) == 0
        assert result["has_more"] is False


# ---------------------------------------------------------------------------
# get_fsp -- absent section (P10: soft degradation)
# ---------------------------------------------------------------------------

class TestGetFspEmptySection:

    def test_absent_fsp_section_returns_empty_result(self, tmp_path) -> None:
        minimal = tmp_path / "minimal.json"
        minimal.write_text('{"users": []}', encoding="utf-8")
        forest = ForestConfig(
            name="minimal.local",
            relation=ForestRelation.STANDALONE,
            file=str(minimal),
        )
        ws = Workspace(mode=WorkspaceMode.OFFLINE, forests=[forest])
        ws._init_connectors()
        mcp = _MockMCP()
        fsp_module.register(mcp, ws)
        result = mcp.get_fsp()
        assert result["items"] == []
        assert result["total"] == 0
        assert result["has_more"] is False

    def test_absent_fsp_orphaned_only_returns_empty(self, tmp_path) -> None:
        minimal = tmp_path / "minimal2.json"
        minimal.write_text('{"users": []}', encoding="utf-8")
        forest = ForestConfig(
            name="minimal2.local",
            relation=ForestRelation.STANDALONE,
            file=str(minimal),
        )
        ws = Workspace(mode=WorkspaceMode.OFFLINE, forests=[forest])
        ws._init_connectors()
        mcp = _MockMCP()
        fsp_module.register(mcp, ws)
        result = mcp.get_fsp(orphaned_only=True)
        assert result["items"] == []
        assert result["total"] == 0


# ---------------------------------------------------------------------------
# Live Mode -- native Python bool field values (no SQLite serialization)
# ---------------------------------------------------------------------------

class TestGetFspLiveModeBoolNormalization:
    """Verify orphaned_only works when IsOrphaned is a native Python bool,
    as returned by the Live Mode connector (no SQLite string serialization).
    Task #139 regression coverage."""

    _RESOLVED = {"Name": "S-1-5-21-resolved", "IsOrphaned": False, "ResolvedName": "EXTDOM\\user1"}
    _ORPHANED = {"Name": "S-1-5-21-orphaned", "IsOrphaned": True, "ResolvedName": None}

    @pytest.fixture
    def live_tools(self) -> _MockMCP:
        from unittest.mock import MagicMock
        connector = MagicMock()
        connector.query.return_value = [self._RESOLVED, self._ORPHANED]
        workspace = MagicMock()
        workspace.connector.return_value = connector
        mcp = _MockMCP()
        fsp_module.register(mcp, workspace)
        return mcp

    def test_orphaned_only_true_native_bool(self, live_tools: _MockMCP) -> None:
        result = live_tools.get_fsp(orphaned_only=True)
        assert result["total"] == 1
        assert result["items"][0]["Name"] == "S-1-5-21-orphaned"

    def test_orphaned_only_false_native_bool_returns_all(self, live_tools: _MockMCP) -> None:
        result = live_tools.get_fsp(orphaned_only=False)
        assert result["total"] == 2
