"""Unit tests for get_groups and get_group_members MCP tools."""

from __future__ import annotations

from pathlib import Path

import pytest

from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, Workspace, WorkspaceMode
from legacy_mcp.tools import groups as groups_module

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
    groups_module.register(mcp, workspace)
    return mcp


# ---------------------------------------------------------------------------
# get_groups
# ---------------------------------------------------------------------------

class TestGetGroups:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_groups()
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_total_matches_fixture(self, tools: _MockMCP) -> None:
        # Fixture has 16 groups.
        result = tools.get_groups()
        assert result["total"] == 16

    def test_default_limit_fits_all(self, tools: _MockMCP) -> None:
        # 16 groups < default limit 50 — all fit in one page.
        result = tools.get_groups()
        assert result["limit"] == 50
        assert result["offset"] == 0
        assert len(result["items"]) == 16
        assert result["has_more"] is False

    def test_pagination_limit_one(self, tools: _MockMCP) -> None:
        first = tools.get_groups(offset=0, limit=1)
        assert len(first["items"]) == 1
        assert first["has_more"] is True
        assert first["total"] == 16

        last = tools.get_groups(offset=15, limit=1)
        assert len(last["items"]) == 1
        assert last["has_more"] is False

    def test_items_have_expected_keys(self, tools: _MockMCP) -> None:
        result = tools.get_groups()
        for item in result["items"]:
            assert "GroupCategory" in item
            assert "GroupScope" in item


# ---------------------------------------------------------------------------
# get_group_members
# ---------------------------------------------------------------------------

class TestGetGroupMembers:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_group_members("Domain Admins")
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_domain_admins_total(self, tools: _MockMCP) -> None:
        # Fixture: Domain Admins has 3 direct members.
        result = tools.get_group_members("Domain Admins")
        assert result["total"] == 3

    def test_members_have_expected_keys(self, tools: _MockMCP) -> None:
        result = tools.get_group_members("Domain Admins")
        for item in result["items"]:
            assert "MemberSamAccountName" in item
            assert "MemberObjectClass" in item
            assert "MemberEnabled" in item

    def test_unknown_group_returns_empty(self, tools: _MockMCP) -> None:
        result = tools.get_group_members("NonExistentGroup")
        assert result["total"] == 0
        assert result["items"] == []
        assert result["has_more"] is False

    def test_pagination_limit_one(self, tools: _MockMCP) -> None:
        # Domain Admins has 3 members — limit=1 should page through them.
        first = tools.get_group_members("Domain Admins", limit=1, offset=0)
        assert len(first["items"]) == 1
        assert first["has_more"] is True

        # offset=3 is past the end.
        beyond = tools.get_group_members("Domain Admins", limit=1, offset=3)
        assert beyond["items"] == []
        assert beyond["has_more"] is False
        assert beyond["total"] == 3

    def test_all_items_belong_to_group(self, tools: _MockMCP) -> None:
        result = tools.get_group_members("Domain Admins")
        for item in result["items"]:
            assert item["GroupName"] == "Domain Admins"
