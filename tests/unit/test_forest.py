"""Unit tests for get_forest_info, get_optional_features,
and get_schema_extensions MCP tools."""

from __future__ import annotations

from pathlib import Path

import pytest

from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, Workspace, WorkspaceMode
from legacy_mcp.tools import forest as forest_module

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
    forest_module.register(mcp, workspace)
    return mcp


# ---------------------------------------------------------------------------
# get_forest_info -- unchanged (scalar)
# ---------------------------------------------------------------------------

class TestGetForestInfo:

    def test_returns_dict(self, tools: _MockMCP) -> None:
        result = tools.get_forest_info()
        assert isinstance(result, dict)

    def test_has_name_field(self, tools: _MockMCP) -> None:
        result = tools.get_forest_info()
        assert "Name" in result


# ---------------------------------------------------------------------------
# get_optional_features -- unchanged (always small, ~2-5 rows)
# ---------------------------------------------------------------------------

class TestGetOptionalFeatures:

    def test_returns_list(self, tools: _MockMCP) -> None:
        result = tools.get_optional_features()
        assert isinstance(result, list)

    def test_total_matches_fixture(self, tools: _MockMCP) -> None:
        # Fixture has 2 optional features.
        result = tools.get_optional_features()
        assert len(result) == 2

    def test_items_have_expected_keys(self, tools: _MockMCP) -> None:
        for item in tools.get_optional_features():
            assert "Name" in item
            assert "Enabled" in item


# ---------------------------------------------------------------------------
# get_schema_extensions
# ---------------------------------------------------------------------------

class TestGetSchemaExtensions:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_schema_extensions()
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_total_matches_fixture(self, tools: _MockMCP) -> None:
        # Fixture has 3 schema extensions.
        result = tools.get_schema_extensions()
        assert result["total"] == 3

    def test_default_limit_fits_all(self, tools: _MockMCP) -> None:
        result = tools.get_schema_extensions()
        assert result["limit"] == 200
        assert len(result["items"]) == 3
        assert result["has_more"] is False

    def test_items_have_expected_keys(self, tools: _MockMCP) -> None:
        result = tools.get_schema_extensions()
        for item in result["items"]:
            assert "lDAPDisplayName" in item
            assert "ObjectClass" in item

    def test_pagination_limit_one(self, tools: _MockMCP) -> None:
        first = tools.get_schema_extensions(offset=0, limit=1)
        assert len(first["items"]) == 1
        assert first["has_more"] is True
        assert first["total"] == 3

        last = tools.get_schema_extensions(offset=2, limit=1)
        assert len(last["items"]) == 1
        assert last["has_more"] is False
