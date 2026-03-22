"""Unit tests for the get_sysvol_state MCP tool."""

from __future__ import annotations

from pathlib import Path

import pytest

from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, Workspace, WorkspaceMode
from legacy_mcp.tools import sysvol as sysvol_module

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
    sysvol_module.register(mcp, workspace)
    return mcp


# ---------------------------------------------------------------------------
# get_sysvol_state
# ---------------------------------------------------------------------------

class TestGetSysvolState:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_sysvol_state()
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_total_matches_fixture(self, tools: _MockMCP) -> None:
        # Fixture has 5 SYSVOL rows (one per DC).
        result = tools.get_sysvol_state()
        assert result["total"] == 5

    def test_default_limit_fits_all(self, tools: _MockMCP) -> None:
        result = tools.get_sysvol_state()
        assert result["limit"] == 100
        assert len(result["items"]) == 5
        assert result["has_more"] is False

    def test_items_have_expected_keys(self, tools: _MockMCP) -> None:
        result = tools.get_sysvol_state()
        for item in result["items"]:
            assert "DC" in item
            assert "Mechanism" in item
            assert "State" in item

    def test_pagination_limit_two(self, tools: _MockMCP) -> None:
        first = tools.get_sysvol_state(offset=0, limit=2)
        assert len(first["items"]) == 2
        assert first["has_more"] is True
        assert first["total"] == 5

        last = tools.get_sysvol_state(offset=4, limit=2)
        assert len(last["items"]) == 1
        assert last["has_more"] is False
