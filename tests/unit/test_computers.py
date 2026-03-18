"""Unit tests for the get_computers and get_computer_summary MCP tools."""

from __future__ import annotations

from pathlib import Path

import pytest

from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, Workspace, WorkspaceMode
from legacy_mcp.tools import computers as computers_module

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
    computers_module.register(mcp, workspace)
    return mcp


# ---------------------------------------------------------------------------
# get_computer_summary
# ---------------------------------------------------------------------------

class TestGetComputerSummary:

    def test_total_count(self, tools: _MockMCP) -> None:
        summary = tools.get_computer_summary()
        assert summary["total"] == 10

    def test_enabled_disabled_counts(self, tools: _MockMCP) -> None:
        summary = tools.get_computer_summary()
        assert summary["enabled"] == 10
        assert summary["disabled"] == 0

    def test_stale_at_least_two(self, tools: _MockMCP) -> None:
        # WS-LONDON-001 (2025-11-20) and WS-OLD-001 (2025-08-15) are always
        # stale regardless of when this test runs — both are well over 90 days
        # in the past relative to any plausible test execution date.
        summary = tools.get_computer_summary()
        assert summary["stale_90d"] >= 2

    def test_cno_count(self, tools: _MockMCP) -> None:
        # SQLCLUSTER is the only CNO in the fixture.
        summary = tools.get_computer_summary()
        assert summary["cno"] == 1

    def test_vco_count(self, tools: _MockMCP) -> None:
        summary = tools.get_computer_summary()
        assert summary["vco"] == 0

    def test_unconstrained_delegation_count(self, tools: _MockMCP) -> None:
        # Only SRV-APPSERVER01 has TrustedForDelegation=True.
        summary = tools.get_computer_summary()
        assert summary["trusted_for_delegation"] == 1

    def test_os_breakdown_keys(self, tools: _MockMCP) -> None:
        summary = tools.get_computer_summary()
        breakdown = summary["os_breakdown"]
        assert "Windows 10 Pro" in breakdown
        assert "Windows 11 Pro" in breakdown
        assert "Windows Server 2019 Standard" in breakdown
        assert "Windows Server 2022 Standard" in breakdown

    def test_os_breakdown_counts(self, tools: _MockMCP) -> None:
        summary = tools.get_computer_summary()
        breakdown = summary["os_breakdown"]
        assert breakdown["Windows 10 Pro"] == 3
        assert breakdown["Windows 11 Pro"] == 2
        assert breakdown["Windows Server 2019 Standard"] == 2
        assert breakdown["Windows Server 2022 Standard"] == 2

    def test_sqlcluster_cno_in_summary(self, tools: _MockMCP) -> None:
        # Verify SQLCLUSTER drives the CNO count (cross-check with full list).
        computers = tools.get_computers()
        cno_names = [c["Name"] for c in computers if c.get("IsCNO") == "True"]
        assert "SQLCLUSTER" in cno_names
        assert len(cno_names) == 1


# ---------------------------------------------------------------------------
# get_computers — no filters
# ---------------------------------------------------------------------------

class TestGetComputersNoFilter:

    def test_returns_all_computers(self, tools: _MockMCP) -> None:
        result = tools.get_computers()
        assert len(result) == 10

    def test_each_row_has_name(self, tools: _MockMCP) -> None:
        result = tools.get_computers()
        for computer in result:
            assert "Name" in computer


# ---------------------------------------------------------------------------
# get_computers — enabled filter
# ---------------------------------------------------------------------------

class TestGetComputersEnabledFilter:

    def test_enabled_true_returns_all(self, tools: _MockMCP) -> None:
        # All 10 computers in the fixture are enabled.
        result = tools.get_computers(enabled=True)
        assert len(result) == 10

    def test_enabled_false_returns_none(self, tools: _MockMCP) -> None:
        result = tools.get_computers(enabled=False)
        assert len(result) == 0


# ---------------------------------------------------------------------------
# get_computers — stale_only filter
# ---------------------------------------------------------------------------

class TestGetComputersStaleOnly:

    def test_stale_only_contains_known_stale_machines(self, tools: _MockMCP) -> None:
        result = tools.get_computers(stale_only=True)
        names = [c["Name"] for c in result]
        assert "WS-LONDON-001" in names
        assert "WS-OLD-001" in names

    def test_stale_only_excludes_recent_machines(self, tools: _MockMCP) -> None:
        # Machines that logged on in early March 2026 are not stale yet.
        result = tools.get_computers(stale_only=True)
        names = [c["Name"] for c in result]
        assert "WS-MILAN-001" not in names
        assert "SRV-APPSERVER01" not in names


# ---------------------------------------------------------------------------
# get_computers — delegation_only filter
# ---------------------------------------------------------------------------

class TestGetComputersDelegationOnly:

    def test_delegation_only_count(self, tools: _MockMCP) -> None:
        # SRV-APPSERVER01 (TrustedForDelegation) and
        # SRV-FILESERVER01 (TrustedToAuthForDelegation + AllowedToDelegateTo).
        result = tools.get_computers(delegation_only=True)
        assert len(result) == 2

    def test_srv_appserver01_in_delegation_results(self, tools: _MockMCP) -> None:
        result = tools.get_computers(delegation_only=True)
        names = [c["Name"] for c in result]
        assert "SRV-APPSERVER01" in names

    def test_srv_fileserver01_in_delegation_results(self, tools: _MockMCP) -> None:
        result = tools.get_computers(delegation_only=True)
        names = [c["Name"] for c in result]
        assert "SRV-FILESERVER01" in names

    def test_non_delegation_machine_excluded(self, tools: _MockMCP) -> None:
        result = tools.get_computers(delegation_only=True)
        names = [c["Name"] for c in result]
        assert "WS-MILAN-001" not in names
        assert "SQLCLUSTER" not in names
