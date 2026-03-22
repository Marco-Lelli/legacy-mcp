"""Unit tests for get_dns_zones and get_dns_forwarders MCP tools."""

from __future__ import annotations

from pathlib import Path

import pytest

from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, Workspace, WorkspaceMode
from legacy_mcp.tools import dns as dns_module

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
    dns_module.register(mcp, workspace)
    return mcp


# ---------------------------------------------------------------------------
# get_dns_zones
# ---------------------------------------------------------------------------

class TestGetDnsZones:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_dns_zones()
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_total_matches_fixture(self, tools: _MockMCP) -> None:
        # Fixture has 7 DNS zone entries.
        result = tools.get_dns_zones()
        assert result["total"] == 7

    def test_default_limit_fits_all(self, tools: _MockMCP) -> None:
        result = tools.get_dns_zones()
        assert result["limit"] == 200
        assert len(result["items"]) == 7
        assert result["has_more"] is False

    def test_items_have_expected_keys(self, tools: _MockMCP) -> None:
        result = tools.get_dns_zones()
        for item in result["items"]:
            assert "ZoneName" in item
            assert "ZoneType" in item
            assert "IsDsIntegrated" in item

    def test_pagination_limit_three(self, tools: _MockMCP) -> None:
        first = tools.get_dns_zones(offset=0, limit=3)
        assert len(first["items"]) == 3
        assert first["has_more"] is True
        assert first["total"] == 7

        last = tools.get_dns_zones(offset=6, limit=3)
        assert len(last["items"]) == 1
        assert last["has_more"] is False


# ---------------------------------------------------------------------------
# get_dns_forwarders — unchanged (bounded, returns list)
# ---------------------------------------------------------------------------

class TestGetDnsForwarders:

    def test_returns_list(self, tools: _MockMCP) -> None:
        result = tools.get_dns_forwarders()
        assert isinstance(result, list)

    def test_total_matches_fixture(self, tools: _MockMCP) -> None:
        # Fixture has 4 forwarder rows (one per DC).
        result = tools.get_dns_forwarders()
        assert len(result) == 4
