"""Unit tests for get_domains and get_default_password_policy MCP tools."""

from __future__ import annotations

from pathlib import Path

import pytest

from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, Workspace, WorkspaceMode
from legacy_mcp.tools import domains as domains_module

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
    domains_module.register(mcp, workspace)
    return mcp


# ---------------------------------------------------------------------------
# get_domains
# ---------------------------------------------------------------------------

class TestGetDomains:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_domains()
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_total_matches_fixture(self, tools: _MockMCP) -> None:
        # Fixture has 2 domains (root + child).
        result = tools.get_domains()
        assert result["total"] == 2

    def test_default_limit_fits_all(self, tools: _MockMCP) -> None:
        result = tools.get_domains()
        assert result["limit"] == 200
        assert len(result["items"]) == 2
        assert result["has_more"] is False

    def test_items_have_expected_keys(self, tools: _MockMCP) -> None:
        result = tools.get_domains()
        for item in result["items"]:
            assert "Name" in item
            assert "DNSRoot" in item
            assert "DomainMode" in item


# ---------------------------------------------------------------------------
# get_default_password_policy -- unchanged (scalar)
# ---------------------------------------------------------------------------

class TestGetDefaultPasswordPolicy:

    def test_returns_dict(self, tools: _MockMCP) -> None:
        result = tools.get_default_password_policy()
        assert isinstance(result, dict)
