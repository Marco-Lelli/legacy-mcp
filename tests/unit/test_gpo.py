"""Unit tests for get_gpos, get_gpo_links, get_blocked_inheritance_ous MCP tools."""

from __future__ import annotations

from pathlib import Path

import pytest

from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, Workspace, WorkspaceMode
from legacy_mcp.tools import gpo as gpo_module

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

FIXTURE_PATH = Path(__file__).resolve().parents[1] / "fixtures" / "contoso-sample.json"


class _MockMCP:
    """Minimal FastMCP stand-in that captures registered tool functions."""

    def tool(self):
        def decorator(fn):
            setattr(self, fn.__name__, fn)
            return fn
        return decorator


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
    gpo_module.register(mcp, workspace)
    return mcp


# ---------------------------------------------------------------------------
# get_gpos
# ---------------------------------------------------------------------------

class TestGetGpos:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_gpos()
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_total_matches_fixture(self, tools: _MockMCP) -> None:
        # Fixture has 9 GPOs.
        result = tools.get_gpos()
        assert result["total"] == 9

    def test_default_limit_fits_all(self, tools: _MockMCP) -> None:
        # 9 GPOs < default limit 100 -- all fit in one page.
        result = tools.get_gpos()
        assert result["limit"] == 100
        assert result["offset"] == 0
        assert len(result["items"]) == 9
        assert result["has_more"] is False

    def test_items_have_expected_keys(self, tools: _MockMCP) -> None:
        result = tools.get_gpos()
        for item in result["items"]:
            assert "DisplayName" in item
            assert "Id" in item
            assert "GpoStatus" in item

    def test_pagination_limit_one(self, tools: _MockMCP) -> None:
        first = tools.get_gpos(offset=0, limit=1)
        assert len(first["items"]) == 1
        assert first["has_more"] is True
        assert first["total"] == 9

        last = tools.get_gpos(offset=8, limit=1)
        assert len(last["items"]) == 1
        assert last["has_more"] is False


# ---------------------------------------------------------------------------
# get_gpo_links
# ---------------------------------------------------------------------------

class TestGetGpoLinks:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_gpo_links()
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_total_matches_fixture(self, tools: _MockMCP) -> None:
        # Fixture has 10 GPO links (one row per GPO per target OU).
        result = tools.get_gpo_links()
        assert result["total"] == 10

    def test_default_limit_fits_all(self, tools: _MockMCP) -> None:
        # 10 links < default limit 100 -- all fit in one page.
        result = tools.get_gpo_links()
        assert result["limit"] == 100
        assert result["offset"] == 0
        assert len(result["items"]) == 10
        assert result["has_more"] is False

    def test_items_have_expected_keys(self, tools: _MockMCP) -> None:
        result = tools.get_gpo_links()
        for item in result["items"]:
            assert "DisplayName" in item
            assert "GpoId" in item
            assert "Target" in item

    def test_pagination_limit_five(self, tools: _MockMCP) -> None:
        first = tools.get_gpo_links(offset=0, limit=5)
        assert len(first["items"]) == 5
        assert first["has_more"] is True
        assert first["total"] == 10

        second = tools.get_gpo_links(offset=5, limit=5)
        assert len(second["items"]) == 5
        assert second["has_more"] is False
        assert second["total"] == 10


# ---------------------------------------------------------------------------
# get_blocked_inheritance_ous
# ---------------------------------------------------------------------------

class TestGetBlockedInheritanceOus:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_blocked_inheritance_ous()
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_total_matches_fixture(self, tools: _MockMCP) -> None:
        # Fixture has 2 OUs with blocked inheritance.
        result = tools.get_blocked_inheritance_ous()
        assert result["total"] == 2

    def test_default_limit_fits_all(self, tools: _MockMCP) -> None:
        result = tools.get_blocked_inheritance_ous()
        assert result["limit"] == 100
        assert len(result["items"]) == 2
        assert result["has_more"] is False

    def test_items_have_expected_keys(self, tools: _MockMCP) -> None:
        result = tools.get_blocked_inheritance_ous()
        for item in result["items"]:
            assert "Name" in item
            assert "DistinguishedName" in item
