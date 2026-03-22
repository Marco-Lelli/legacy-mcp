"""Unit tests for get_domain_controllers, get_eventlog_config,
get_ntp_config, and get_fsmo_roles MCP tools."""

from __future__ import annotations

from pathlib import Path

import pytest

from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, Workspace, WorkspaceMode
from legacy_mcp.tools import dcs as dcs_module

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
    dcs_module.register(mcp, workspace)
    return mcp


# ---------------------------------------------------------------------------
# get_domain_controllers
# ---------------------------------------------------------------------------

class TestGetDomainControllers:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_domain_controllers()
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_total_matches_fixture(self, tools: _MockMCP) -> None:
        # Fixture has 5 DCs.
        result = tools.get_domain_controllers()
        assert result["total"] == 5

    def test_default_limit_fits_all(self, tools: _MockMCP) -> None:
        result = tools.get_domain_controllers()
        assert result["limit"] == 100
        assert len(result["items"]) == 5
        assert result["has_more"] is False

    def test_items_have_expected_keys(self, tools: _MockMCP) -> None:
        result = tools.get_domain_controllers()
        for item in result["items"]:
            assert "Name" in item
            assert "OperatingSystem" in item
            assert "IsGlobalCatalog" in item

    def test_pagination_limit_two(self, tools: _MockMCP) -> None:
        first = tools.get_domain_controllers(offset=0, limit=2)
        assert len(first["items"]) == 2
        assert first["has_more"] is True
        assert first["total"] == 5

        last = tools.get_domain_controllers(offset=4, limit=2)
        assert len(last["items"]) == 1
        assert last["has_more"] is False


# ---------------------------------------------------------------------------
# get_eventlog_config
# ---------------------------------------------------------------------------

class TestGetEventlogConfig:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_eventlog_config()
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_total_matches_fixture(self, tools: _MockMCP) -> None:
        # Fixture has 12 rows (5 DCs x ~3 logs, minus any unreachable).
        result = tools.get_eventlog_config()
        assert result["total"] == 12

    def test_default_limit_fits_all(self, tools: _MockMCP) -> None:
        result = tools.get_eventlog_config()
        assert result["limit"] == 100
        assert len(result["items"]) == 12
        assert result["has_more"] is False

    def test_items_have_expected_keys(self, tools: _MockMCP) -> None:
        result = tools.get_eventlog_config()
        for item in result["items"]:
            assert "DC" in item
            assert "LogName" in item
            assert "MaxSizeBytes" in item


# ---------------------------------------------------------------------------
# get_ntp_config
# ---------------------------------------------------------------------------

class TestGetNtpConfig:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_ntp_config()
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_total_matches_fixture(self, tools: _MockMCP) -> None:
        # Fixture has 5 NTP config rows (one per DC).
        result = tools.get_ntp_config()
        assert result["total"] == 5

    def test_default_limit_fits_all(self, tools: _MockMCP) -> None:
        result = tools.get_ntp_config()
        assert result["limit"] == 100
        assert len(result["items"]) == 5
        assert result["has_more"] is False

    def test_items_have_expected_keys(self, tools: _MockMCP) -> None:
        result = tools.get_ntp_config()
        for item in result["items"]:
            assert "DC" in item
            assert "NtpServer" in item
            assert "Type" in item


# ---------------------------------------------------------------------------
# get_fsmo_roles — unchanged (scalar, not paginated)
# ---------------------------------------------------------------------------

class TestGetFsmoRoles:

    def test_returns_dict(self, tools: _MockMCP) -> None:
        result = tools.get_fsmo_roles()
        assert isinstance(result, dict)
