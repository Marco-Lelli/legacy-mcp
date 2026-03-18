"""Unit tests for the get_users, get_user_summary, and get_user_by_name
MCP tools."""

from __future__ import annotations

from pathlib import Path

import pytest

from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, Workspace, WorkspaceMode
from legacy_mcp.tools import users as users_module

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
    users_module.register(mcp, workspace)
    return mcp


# ---------------------------------------------------------------------------
# get_users — no filters
# ---------------------------------------------------------------------------

class TestGetUsersNoFilter:

    def test_returns_all_users(self, tools: _MockMCP) -> None:
        result = tools.get_users()
        assert len(result) == 15

    def test_each_row_has_sam_account_name(self, tools: _MockMCP) -> None:
        result = tools.get_users()
        for user in result:
            assert "SamAccountName" in user


# ---------------------------------------------------------------------------
# get_users — enabled filter
# ---------------------------------------------------------------------------

class TestGetUsersEnabledFilter:

    def test_enabled_true(self, tools: _MockMCP) -> None:
        result = tools.get_users(enabled=True)
        # a.rossi m.ferrari l.bianchi g.conti s.martini svc.backup svc.monitor
        # svc.deploy adm.rossi adm.ferrari Administrator = 11
        assert len(result) == 11
        for u in result:
            assert u["Enabled"] == "True"

    def test_enabled_false(self, tools: _MockMCP) -> None:
        result = tools.get_users(enabled=False)
        # r.greco f.esposito Guest krbtgt = 4
        assert len(result) == 4
        for u in result:
            assert u["Enabled"] == "False"

    def test_enabled_true_and_false_sum_to_total(self, tools: _MockMCP) -> None:
        total = len(tools.get_users())
        enabled = len(tools.get_users(enabled=True))
        disabled = len(tools.get_users(enabled=False))
        assert enabled + disabled == total


# ---------------------------------------------------------------------------
# get_users — admin_count filter
# ---------------------------------------------------------------------------

class TestGetUsersAdminCount:

    def test_admin_count_true_count(self, tools: _MockMCP) -> None:
        # adm.rossi, adm.ferrari, Administrator, krbtgt have AdminCount=1.
        result = tools.get_users(admin_count=True)
        assert len(result) == 4

    def test_admin_count_true_names(self, tools: _MockMCP) -> None:
        result = tools.get_users(admin_count=True)
        names = {u["SamAccountName"] for u in result}
        assert names == {"adm.rossi", "adm.ferrari", "Administrator", "krbtgt"}

    def test_admin_count_false_excludes_protected_accounts(self, tools: _MockMCP) -> None:
        result = tools.get_users(admin_count=False)
        names = {u["SamAccountName"] for u in result}
        assert "adm.rossi" not in names
        assert "krbtgt" not in names

    def test_admin_count_true_and_false_sum_to_total(self, tools: _MockMCP) -> None:
        total = len(tools.get_users())
        with_ac = len(tools.get_users(admin_count=True))
        without_ac = len(tools.get_users(admin_count=False))
        assert with_ac + without_ac == total


# ---------------------------------------------------------------------------
# get_users — stale_only filter
# ---------------------------------------------------------------------------

class TestGetUsersStaleOnly:

    def test_stale_only_contains_never_logged_on(self, tools: _MockMCP) -> None:
        # Guest and krbtgt have never logged on — always stale.
        result = tools.get_users(stale_only=True)
        names = [u["SamAccountName"] for u in result]
        assert "Guest" in names
        assert "krbtgt" in names

    def test_stale_only_contains_long_inactive_accounts(self, tools: _MockMCP) -> None:
        # r.greco (2025-09-30) and f.esposito (2025-11-15) are well over
        # 90 days inactive from any plausible test execution date.
        result = tools.get_users(stale_only=True)
        names = [u["SamAccountName"] for u in result]
        assert "r.greco" in names
        assert "f.esposito" in names

    def test_stale_only_excludes_recently_active_accounts(self, tools: _MockMCP) -> None:
        # Users who logged on in early March 2026 are not stale yet.
        result = tools.get_users(stale_only=True)
        names = [u["SamAccountName"] for u in result]
        assert "a.rossi" not in names
        assert "adm.rossi" not in names


# ---------------------------------------------------------------------------
# get_users — delegation_only filter
# ---------------------------------------------------------------------------

class TestGetUsersDelegationOnly:

    def test_delegation_only_count(self, tools: _MockMCP) -> None:
        # Only svc.deploy has TrustedForDelegation=True.
        result = tools.get_users(delegation_only=True)
        assert len(result) == 1

    def test_svc_deploy_in_delegation_results(self, tools: _MockMCP) -> None:
        result = tools.get_users(delegation_only=True)
        assert result[0]["SamAccountName"] == "svc.deploy"

    def test_regular_user_excluded(self, tools: _MockMCP) -> None:
        result = tools.get_users(delegation_only=True)
        names = [u["SamAccountName"] for u in result]
        assert "a.rossi" not in names
        assert "adm.rossi" not in names


# ---------------------------------------------------------------------------
# get_users — password_never_expires filter
# ---------------------------------------------------------------------------

class TestGetUsersPasswordNeverExpires:

    def test_pne_true_count(self, tools: _MockMCP) -> None:
        # svc.backup, svc.monitor, svc.deploy, Administrator, Guest = 5
        result = tools.get_users(password_never_expires=True)
        assert len(result) == 5

    def test_pne_true_includes_service_accounts(self, tools: _MockMCP) -> None:
        result = tools.get_users(password_never_expires=True)
        names = {u["SamAccountName"] for u in result}
        assert "svc.backup" in names
        assert "svc.monitor" in names
        assert "svc.deploy" in names

    def test_pne_false_excludes_service_accounts(self, tools: _MockMCP) -> None:
        result = tools.get_users(password_never_expires=False)
        names = {u["SamAccountName"] for u in result}
        assert "svc.backup" not in names
        assert "svc.monitor" not in names

    def test_pne_true_and_false_sum_to_total(self, tools: _MockMCP) -> None:
        total = len(tools.get_users())
        pne_true = len(tools.get_users(password_never_expires=True))
        pne_false = len(tools.get_users(password_never_expires=False))
        assert pne_true + pne_false == total


# ---------------------------------------------------------------------------
# get_users — locked_out filter
# ---------------------------------------------------------------------------

class TestGetUsersLockedOut:

    def test_locked_out_true_count(self, tools: _MockMCP) -> None:
        # Only g.conti is locked out in the fixture.
        result = tools.get_users(locked_out=True)
        assert len(result) == 1

    def test_locked_out_true_name(self, tools: _MockMCP) -> None:
        result = tools.get_users(locked_out=True)
        assert result[0]["SamAccountName"] == "g.conti"

    def test_locked_out_false_excludes_locked(self, tools: _MockMCP) -> None:
        result = tools.get_users(locked_out=False)
        names = [u["SamAccountName"] for u in result]
        assert "g.conti" not in names


# ---------------------------------------------------------------------------
# get_users — combined filters
# ---------------------------------------------------------------------------

class TestGetUsersCombinedFilters:

    def test_admin_count_and_enabled(self, tools: _MockMCP) -> None:
        # AdminCount=1 AND enabled=True: adm.rossi, adm.ferrari, Administrator
        # (krbtgt is disabled)
        result = tools.get_users(admin_count=True, enabled=True)
        assert len(result) == 3
        names = {u["SamAccountName"] for u in result}
        assert "krbtgt" not in names
        assert "adm.rossi" in names

    def test_delegation_and_enabled(self, tools: _MockMCP) -> None:
        # svc.deploy is both delegation and enabled=True
        result = tools.get_users(delegation_only=True, enabled=True)
        assert len(result) == 1
        assert result[0]["SamAccountName"] == "svc.deploy"


# ---------------------------------------------------------------------------
# get_user_by_name
# ---------------------------------------------------------------------------

class TestGetUserByName:

    def test_found_returns_dict(self, tools: _MockMCP) -> None:
        result = tools.get_user_by_name("adm.rossi")
        assert isinstance(result, dict)
        assert result["SamAccountName"] == "adm.rossi"

    def test_found_has_expected_fields(self, tools: _MockMCP) -> None:
        result = tools.get_user_by_name("adm.rossi")
        assert result is not None
        assert result["AdminCount"] == "1"
        assert result["Enabled"] == "True"

    def test_not_found_returns_none(self, tools: _MockMCP) -> None:
        result = tools.get_user_by_name("nonexistent.user")
        assert result is None

    def test_case_sensitive_lookup(self, tools: _MockMCP) -> None:
        # SamAccountName lookup is case-insensitive in QueryEngine
        # (uses .lower() comparison)
        result = tools.get_user_by_name("ADM.ROSSI")
        assert result is not None
        assert result["SamAccountName"] == "adm.rossi"

    def test_disabled_user_found(self, tools: _MockMCP) -> None:
        result = tools.get_user_by_name("r.greco")
        assert result is not None
        assert result["Enabled"] == "False"
