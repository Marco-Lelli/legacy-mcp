"""Unit tests for the get_ous MCP tool."""

from __future__ import annotations

from pathlib import Path

import pytest

from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, Workspace, WorkspaceMode
from legacy_mcp.tools import ous as ous_module

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
    ous_module.register(mcp, workspace)
    return mcp


# ---------------------------------------------------------------------------
# get_ous
# ---------------------------------------------------------------------------

class TestGetOus:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_ous()
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_total_matches_fixture(self, tools: _MockMCP) -> None:
        # Fixture has 11 OUs.
        result = tools.get_ous()
        assert result["total"] == 11

    def test_default_limit_fits_all(self, tools: _MockMCP) -> None:
        # 11 OUs < default limit 100 — all fit in one page.
        result = tools.get_ous()
        assert result["limit"] == 100
        assert result["offset"] == 0
        assert len(result["items"]) == 11
        assert result["has_more"] is False

    def test_items_have_expected_keys(self, tools: _MockMCP) -> None:
        result = tools.get_ous()
        for item in result["items"]:
            assert "Name" in item
            assert "DistinguishedName" in item
            assert "BlockedInheritance" in item

    def test_pagination_offset_and_limit(self, tools: _MockMCP) -> None:
        # First page of 5: items=[0..4], has_more=True.
        first = tools.get_ous(offset=0, limit=5)
        assert len(first["items"]) == 5
        assert first["has_more"] is True
        assert first["total"] == 11

        # Third page with limit=5: items=[10], has_more=False.
        third = tools.get_ous(offset=10, limit=5)
        assert len(third["items"]) == 1
        assert third["has_more"] is False
        assert third["total"] == 11
