"""Unit tests for get_sites and get_site_links MCP tools."""

from __future__ import annotations

from pathlib import Path

import pytest

from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, Workspace, WorkspaceMode
from legacy_mcp.tools import sites as sites_module

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
    sites_module.register(mcp, workspace)
    return mcp


# ---------------------------------------------------------------------------
# get_sites
# ---------------------------------------------------------------------------

class TestGetSites:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_sites()
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_total_matches_fixture(self, tools: _MockMCP) -> None:
        # Fixture has 3 sites.
        result = tools.get_sites()
        assert result["total"] == 3

    def test_default_limit_fits_all(self, tools: _MockMCP) -> None:
        result = tools.get_sites()
        assert result["limit"] == 200
        assert len(result["items"]) == 3
        assert result["has_more"] is False

    def test_items_have_expected_keys(self, tools: _MockMCP) -> None:
        result = tools.get_sites()
        for item in result["items"]:
            assert "Name" in item

    def test_pagination_limit_one(self, tools: _MockMCP) -> None:
        first = tools.get_sites(offset=0, limit=1)
        assert len(first["items"]) == 1
        assert first["has_more"] is True
        assert first["total"] == 3

        last = tools.get_sites(offset=2, limit=1)
        assert len(last["items"]) == 1
        assert last["has_more"] is False


# ---------------------------------------------------------------------------
# get_site_links
# ---------------------------------------------------------------------------

class TestGetSiteLinks:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_site_links()
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_total_matches_fixture(self, tools: _MockMCP) -> None:
        # Fixture has 3 site links.
        result = tools.get_site_links()
        assert result["total"] == 3

    def test_default_limit_fits_all(self, tools: _MockMCP) -> None:
        result = tools.get_site_links()
        assert result["limit"] == 200
        assert len(result["items"]) == 3
        assert result["has_more"] is False

    def test_items_have_expected_keys(self, tools: _MockMCP) -> None:
        result = tools.get_site_links()
        for item in result["items"]:
            assert "Name" in item
            assert "Cost" in item
            assert "Transport" in item
