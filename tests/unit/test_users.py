"""Unit tests for the get_users, get_user_summary, get_privileged_accounts,
and get_user_by_name MCP tools."""

from __future__ import annotations

from pathlib import Path

import pytest

from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, Workspace, WorkspaceMode
from legacy_mcp.tools import users as users_module
from legacy_mcp.tools.users import _get_primary_group_id

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
# get_users — contract and pagination
# ---------------------------------------------------------------------------

class TestGetUsersContractAndPagination:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_users()
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_default_limit_and_offset(self, tools: _MockMCP) -> None:
        result = tools.get_users()
        assert result["limit"] == 200
        assert result["offset"] == 0

    def test_all_fit_in_default_page(self, tools: _MockMCP) -> None:
        # 15 users < limit 200 -- has_more must be False.
        result = tools.get_users()
        assert result["has_more"] is False
        assert len(result["items"]) == result["total"]

    def test_pagination_limit_one(self, tools: _MockMCP) -> None:
        first = tools.get_users(offset=0, limit=1)
        assert len(first["items"]) == 1
        assert first["has_more"] is True
        assert first["total"] == 15

    def test_total_reflects_filtered_count(self, tools: _MockMCP) -> None:
        # total must reflect post-filter count, not the full table size.
        result = tools.get_users(enabled=True)
        assert result["total"] == 11
        # Now paginate over that filtered set.
        page = tools.get_users(enabled=True, offset=0, limit=5)
        assert page["total"] == 11
        assert len(page["items"]) == 5
        assert page["has_more"] is True


# ---------------------------------------------------------------------------
# get_users — no filters
# ---------------------------------------------------------------------------

class TestGetUsersNoFilter:

    def test_returns_all_users(self, tools: _MockMCP) -> None:
        result = tools.get_users()
        assert result["total"] == 15

    def test_each_row_has_sam_account_name(self, tools: _MockMCP) -> None:
        result = tools.get_users()
        for user in result["items"]:
            assert "SamAccountName" in user


# ---------------------------------------------------------------------------
# get_users — enabled filter
# ---------------------------------------------------------------------------

class TestGetUsersEnabledFilter:

    def test_enabled_true(self, tools: _MockMCP) -> None:
        # a.rossi m.ferrari l.bianchi g.conti s.martini svc.backup svc.monitor
        # svc.deploy adm.rossi adm.ferrari Administrator = 11
        result = tools.get_users(enabled=True)
        assert result["total"] == 11
        for u in result["items"]:
            assert u["Enabled"] == "True"

    def test_enabled_false(self, tools: _MockMCP) -> None:
        # r.greco f.esposito Guest krbtgt = 4
        result = tools.get_users(enabled=False)
        assert result["total"] == 4
        for u in result["items"]:
            assert u["Enabled"] == "False"

    def test_enabled_true_and_false_sum_to_total(self, tools: _MockMCP) -> None:
        total = tools.get_users()["total"]
        enabled = tools.get_users(enabled=True)["total"]
        disabled = tools.get_users(enabled=False)["total"]
        assert enabled + disabled == total


# ---------------------------------------------------------------------------
# get_users — admin_count filter
# ---------------------------------------------------------------------------

class TestGetUsersAdminCount:

    def test_admin_count_true_count(self, tools: _MockMCP) -> None:
        # adm.rossi, adm.ferrari, Administrator, krbtgt have AdminCount=1.
        result = tools.get_users(admin_count=True)
        assert result["total"] == 4

    def test_admin_count_true_names(self, tools: _MockMCP) -> None:
        result = tools.get_users(admin_count=True)
        names = {u["SamAccountName"] for u in result["items"]}
        assert names == {"adm.rossi", "adm.ferrari", "Administrator", "krbtgt"}

    def test_admin_count_false_excludes_protected_accounts(self, tools: _MockMCP) -> None:
        result = tools.get_users(admin_count=False)
        names = {u["SamAccountName"] for u in result["items"]}
        assert "adm.rossi" not in names
        assert "krbtgt" not in names

    def test_admin_count_true_and_false_sum_to_total(self, tools: _MockMCP) -> None:
        total = tools.get_users()["total"]
        with_ac = tools.get_users(admin_count=True)["total"]
        without_ac = tools.get_users(admin_count=False)["total"]
        assert with_ac + without_ac == total


# ---------------------------------------------------------------------------
# get_users — stale_only filter
# ---------------------------------------------------------------------------

class TestGetUsersStaleOnly:

    def test_stale_only_contains_never_logged_on(self, tools: _MockMCP) -> None:
        # Guest and krbtgt have never logged on -- always stale.
        result = tools.get_users(stale_only=True)
        names = [u["SamAccountName"] for u in result["items"]]
        assert "Guest" in names
        assert "krbtgt" in names

    def test_stale_only_contains_long_inactive_accounts(self, tools: _MockMCP) -> None:
        # r.greco (2025-09-30) and f.esposito (2025-11-15) are well over
        # 90 days inactive from any plausible test execution date.
        result = tools.get_users(stale_only=True)
        names = [u["SamAccountName"] for u in result["items"]]
        assert "r.greco" in names
        assert "f.esposito" in names

    def test_stale_only_excludes_recently_active_accounts(self, tools: _MockMCP) -> None:
        # Users who logged on in early March 2026 are not stale yet.
        result = tools.get_users(stale_only=True)
        names = [u["SamAccountName"] for u in result["items"]]
        assert "a.rossi" not in names
        assert "adm.rossi" not in names


# ---------------------------------------------------------------------------
# get_users — delegation_only filter
# ---------------------------------------------------------------------------

class TestGetUsersDelegationOnly:

    def test_delegation_only_count(self, tools: _MockMCP) -> None:
        # Only svc.deploy has TrustedForDelegation=True.
        result = tools.get_users(delegation_only=True)
        assert result["total"] == 1

    def test_svc_deploy_in_delegation_results(self, tools: _MockMCP) -> None:
        result = tools.get_users(delegation_only=True)
        assert result["items"][0]["SamAccountName"] == "svc.deploy"

    def test_regular_user_excluded(self, tools: _MockMCP) -> None:
        result = tools.get_users(delegation_only=True)
        names = [u["SamAccountName"] for u in result["items"]]
        assert "a.rossi" not in names
        assert "adm.rossi" not in names


# ---------------------------------------------------------------------------
# get_users — password_never_expires filter
# ---------------------------------------------------------------------------

class TestGetUsersPasswordNeverExpires:

    def test_pne_true_count(self, tools: _MockMCP) -> None:
        # svc.backup, svc.monitor, svc.deploy, Administrator, Guest = 5
        result = tools.get_users(password_never_expires=True)
        assert result["total"] == 5

    def test_pne_true_includes_service_accounts(self, tools: _MockMCP) -> None:
        result = tools.get_users(password_never_expires=True)
        names = {u["SamAccountName"] for u in result["items"]}
        assert "svc.backup" in names
        assert "svc.monitor" in names
        assert "svc.deploy" in names

    def test_pne_false_excludes_service_accounts(self, tools: _MockMCP) -> None:
        result = tools.get_users(password_never_expires=False)
        names = {u["SamAccountName"] for u in result["items"]}
        assert "svc.backup" not in names
        assert "svc.monitor" not in names

    def test_pne_true_and_false_sum_to_total(self, tools: _MockMCP) -> None:
        total = tools.get_users()["total"]
        pne_true = tools.get_users(password_never_expires=True)["total"]
        pne_false = tools.get_users(password_never_expires=False)["total"]
        assert pne_true + pne_false == total


# ---------------------------------------------------------------------------
# get_users — has_sid_history filter
# ---------------------------------------------------------------------------

class TestGetUsersSIDHistory:

    def test_sid_history_true_returns_only_migrated(self, tools: _MockMCP) -> None:
        # Only a.rossi has a non-empty SIDHistory in the fixture.
        result = tools.get_users(has_sid_history=True)
        assert result["total"] == 1
        assert result["items"][0]["SamAccountName"] == "a.rossi"

    def test_sid_history_true_items_have_non_empty_list(self, tools: _MockMCP) -> None:
        result = tools.get_users(has_sid_history=True)
        for u in result["items"]:
            assert isinstance(u["SIDHistory"], list)
            assert len(u["SIDHistory"]) > 0

    def test_sid_history_false_excludes_migrated(self, tools: _MockMCP) -> None:
        result = tools.get_users(has_sid_history=False)
        names = [u["SamAccountName"] for u in result["items"]]
        assert "a.rossi" not in names

    def test_sid_history_false_count(self, tools: _MockMCP) -> None:
        # 14 users: all except a.rossi (m.ferrari has [] which is falsy,
        # rest have no SIDHistory field at all — both match has_sid_history=False).
        result = tools.get_users(has_sid_history=False)
        assert result["total"] == 14

    def test_sid_history_none_returns_all(self, tools: _MockMCP) -> None:
        result = tools.get_users(has_sid_history=None)
        assert result["total"] == 15

    def test_sid_history_field_is_array_of_strings(self, tools: _MockMCP) -> None:
        result = tools.get_users(has_sid_history=True)
        sids = result["items"][0]["SIDHistory"]
        assert isinstance(sids, list)
        assert all(isinstance(s, str) for s in sids)
        assert sids[0].startswith("S-1-5-")

    def test_sid_history_true_false_complement(self, tools: _MockMCP) -> None:
        total = tools.get_users()["total"]
        with_sid = tools.get_users(has_sid_history=True)["total"]
        without_sid = tools.get_users(has_sid_history=False)["total"]
        assert with_sid + without_sid == total


# ---------------------------------------------------------------------------
# get_users — locked_out filter
# ---------------------------------------------------------------------------

class TestGetUsersLockedOut:

    def test_locked_out_true_count(self, tools: _MockMCP) -> None:
        # Only g.conti is locked out in the fixture.
        result = tools.get_users(locked_out=True)
        assert result["total"] == 1

    def test_locked_out_true_name(self, tools: _MockMCP) -> None:
        result = tools.get_users(locked_out=True)
        assert result["items"][0]["SamAccountName"] == "g.conti"

    def test_locked_out_false_excludes_locked(self, tools: _MockMCP) -> None:
        result = tools.get_users(locked_out=False)
        names = [u["SamAccountName"] for u in result["items"]]
        assert "g.conti" not in names


# ---------------------------------------------------------------------------
# get_users — combined filters
# ---------------------------------------------------------------------------

class TestGetUsersCombinedFilters:

    def test_admin_count_and_enabled(self, tools: _MockMCP) -> None:
        # AdminCount=1 AND enabled=True: adm.rossi, adm.ferrari, Administrator
        # (krbtgt is disabled)
        result = tools.get_users(admin_count=True, enabled=True)
        assert result["total"] == 3
        names = {u["SamAccountName"] for u in result["items"]}
        assert "krbtgt" not in names
        assert "adm.rossi" in names

    def test_delegation_and_enabled(self, tools: _MockMCP) -> None:
        # svc.deploy is both delegation and enabled=True
        result = tools.get_users(delegation_only=True, enabled=True)
        assert result["total"] == 1
        assert result["items"][0]["SamAccountName"] == "svc.deploy"


# ---------------------------------------------------------------------------
# get_privileged_accounts
# ---------------------------------------------------------------------------

class TestGetPrivilegedAccounts:

    def test_returns_dict_contract(self, tools: _MockMCP) -> None:
        result = tools.get_privileged_accounts()
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_total_matches_fixture(self, tools: _MockMCP) -> None:
        # Fixture has 7 privileged account entries.
        result = tools.get_privileged_accounts()
        assert result["total"] == 7

    def test_default_limit_fits_all(self, tools: _MockMCP) -> None:
        result = tools.get_privileged_accounts()
        assert result["limit"] == 200
        assert result["has_more"] is False
        assert len(result["items"]) == 7

    def test_items_have_expected_keys(self, tools: _MockMCP) -> None:
        result = tools.get_privileged_accounts()
        for item in result["items"]:
            assert "SamAccountName" in item
            assert "Group" in item


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


# ---------------------------------------------------------------------------
# get_user_summary
# ---------------------------------------------------------------------------

class TestGetUserSummary:

    def test_returns_new_keys(self, tools: _MockMCP) -> None:
        result = tools.get_user_summary()
        assert "no_last_logon" in result
        assert "primary_group_not_domain_users" in result

    def test_no_last_logon_count(self, tools: _MockMCP) -> None:
        # Guest and krbtgt have LastLogonDate: null in the fixture.
        result = tools.get_user_summary()
        assert result["no_last_logon"]["count"] == 2

    def test_no_last_logon_active_count(self, tools: _MockMCP) -> None:
        # Both Guest and krbtgt are disabled -- active_count must be 0.
        result = tools.get_user_summary()
        assert result["no_last_logon"]["active_count"] == 0

    def test_no_last_logon_pct_of_total(self, tools: _MockMCP) -> None:
        result = tools.get_user_summary()
        assert result["no_last_logon"]["pct_of_total"] == round(2 / 15 * 100, 2)

    def test_no_last_logon_pct_of_active_is_zero(self, tools: _MockMCP) -> None:
        result = tools.get_user_summary()
        assert result["no_last_logon"]["pct_of_active"] == 0.0

    def test_primary_group_not_domain_users_count(self, tools: _MockMCP) -> None:
        # krbtgt has PrimaryGroupID=516; all others have 513.
        result = tools.get_user_summary()
        assert result["primary_group_not_domain_users"]["count"] == 1

    def test_primary_group_not_domain_users_pct(self, tools: _MockMCP) -> None:
        result = tools.get_user_summary()
        assert result["primary_group_not_domain_users"]["pct_of_total"] == round(1 / 15 * 100, 2)

    def test_pct_zero_when_no_users(self, tmp_path) -> None:
        empty_json = tmp_path / "empty.json"
        empty_json.write_text('{"users": []}', encoding="utf-8")
        from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, WorkspaceMode
        forest = ForestConfig(
            name="empty.local",
            relation=ForestRelation.STANDALONE,
            file=str(empty_json),
        )
        ws = Workspace(mode=WorkspaceMode.OFFLINE, forests=[forest])
        ws._init_connectors()
        empty_mcp = _MockMCP()
        users_module.register(empty_mcp, ws)
        result = empty_mcp.get_user_summary()
        assert result["no_last_logon"]["pct_of_total"] == 0.0
        assert result["no_last_logon"]["pct_of_active"] == 0.0
        assert result["primary_group_not_domain_users"]["pct_of_total"] == 0.0


# ---------------------------------------------------------------------------
# get_users -- no_last_logon filter
# ---------------------------------------------------------------------------

class TestGetUsersNoLastLogon:

    def test_no_last_logon_true_count(self, tools: _MockMCP) -> None:
        # Guest and krbtgt have no LastLogonDate in the fixture.
        result = tools.get_users(no_last_logon=True)
        assert result["total"] == 2

    def test_no_last_logon_true_names(self, tools: _MockMCP) -> None:
        result = tools.get_users(no_last_logon=True)
        names = {u["SamAccountName"] for u in result["items"]}
        assert names == {"Guest", "krbtgt"}

    def test_no_last_logon_combined_with_enabled_returns_empty(self, tools: _MockMCP) -> None:
        # Both no-logon accounts are disabled -- combined filter yields 0.
        result = tools.get_users(no_last_logon=True, enabled=True)
        assert result["total"] == 0

    def test_no_last_logon_false_returns_all(self, tools: _MockMCP) -> None:
        result = tools.get_users(no_last_logon=False)
        assert result["total"] == 15


# ---------------------------------------------------------------------------
# get_users -- primary_group_not_domain_users filter
# ---------------------------------------------------------------------------

class TestGetUsersPrimaryGroupNotDomainUsers:

    def test_pgid_not_domain_users_count(self, tools: _MockMCP) -> None:
        # Only krbtgt has PrimaryGroupID=516.
        result = tools.get_users(primary_group_not_domain_users=True)
        assert result["total"] == 1

    def test_pgid_not_domain_users_name(self, tools: _MockMCP) -> None:
        result = tools.get_users(primary_group_not_domain_users=True)
        assert result["items"][0]["SamAccountName"] == "krbtgt"

    def test_pgid_false_returns_all(self, tools: _MockMCP) -> None:
        result = tools.get_users(primary_group_not_domain_users=False)
        assert result["total"] == 15

    def test_pgid_combined_with_enabled_returns_empty(self, tools: _MockMCP) -> None:
        # krbtgt is disabled -- pgid filter + enabled=True yields 0.
        result = tools.get_users(primary_group_not_domain_users=True, enabled=True)
        assert result["total"] == 0


# ---------------------------------------------------------------------------
# _get_primary_group_id -- normalization helper (Live Mode compat)
# ---------------------------------------------------------------------------

class TestGetPrimaryGroupId:

    def test_list_513_not_flagged(self) -> None:
        # Live Mode may return PrimaryGroupID as a single-element list.
        assert _get_primary_group_id({"PrimaryGroupID": [513]}) == 513

    def test_list_512_flagged(self) -> None:
        assert _get_primary_group_id({"PrimaryGroupID": [512]}) == 512

    def test_string_514_flagged(self) -> None:
        # Offline Mode serializes integers to strings via the SQLite loader.
        assert _get_primary_group_id({"PrimaryGroupID": "514"}) == 514

    def test_absent_defaults_to_513(self) -> None:
        assert _get_primary_group_id({}) == 513


# ---------------------------------------------------------------------------
# get_users -- cannot_change_password filter
# ---------------------------------------------------------------------------

class TestGetUsersCannotChangePassword:

    def test_cannot_change_password_true_count(self, tools: _MockMCP) -> None:
        # Only svc.backup has CannotChangePassword=True in the fixture.
        result = tools.get_users(cannot_change_password=True)
        assert result["total"] == 1

    def test_cannot_change_password_true_name(self, tools: _MockMCP) -> None:
        result = tools.get_users(cannot_change_password=True)
        assert result["items"][0]["SamAccountName"] == "svc.backup"

    def test_cannot_change_password_false_returns_all(self, tools: _MockMCP) -> None:
        result = tools.get_users(cannot_change_password=False)
        assert result["total"] == 15

    def test_cannot_change_password_missing_field_not_flagged(self, tmp_path) -> None:
        # A user record without the CannotChangePassword field must not be
        # returned when cannot_change_password=True — default is False.
        minimal = tmp_path / "minimal.json"
        minimal.write_text(
            '{"users": [{"SamAccountName": "no.field", "Enabled": "True"}]}',
            encoding="utf-8",
        )
        from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, WorkspaceMode
        forest = ForestConfig(
            name="minimal.local",
            relation=ForestRelation.STANDALONE,
            file=str(minimal),
        )
        ws = Workspace(mode=WorkspaceMode.OFFLINE, forests=[forest])
        ws._init_connectors()
        minimal_mcp = _MockMCP()
        users_module.register(minimal_mcp, ws)
        result = minimal_mcp.get_users(cannot_change_password=True)
        assert result["total"] == 0


# ---------------------------------------------------------------------------
# get_user_summary -- cannot_change_password key
# ---------------------------------------------------------------------------

class TestGetUserSummaryCannotChangePassword:

    def test_summary_has_cannot_change_password_key(self, tools: _MockMCP) -> None:
        result = tools.get_user_summary()
        assert "cannot_change_password" in result

    def test_cannot_change_password_count(self, tools: _MockMCP) -> None:
        # Only svc.backup has CannotChangePassword=True in the fixture.
        result = tools.get_user_summary()
        assert result["cannot_change_password"]["count"] == 1

    def test_cannot_change_password_pct(self, tools: _MockMCP) -> None:
        result = tools.get_user_summary()
        assert result["cannot_change_password"]["pct_of_total"] == round(1 / 15 * 100, 2)

    def test_cannot_change_password_pct_zero_when_empty(self, tmp_path) -> None:
        empty_json = tmp_path / "empty.json"
        empty_json.write_text('{"users": []}', encoding="utf-8")
        from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, WorkspaceMode
        forest = ForestConfig(
            name="empty2.local",
            relation=ForestRelation.STANDALONE,
            file=str(empty_json),
        )
        ws = Workspace(mode=WorkspaceMode.OFFLINE, forests=[forest])
        ws._init_connectors()
        empty_mcp = _MockMCP()
        users_module.register(empty_mcp, ws)
        result = empty_mcp.get_user_summary()
        assert result["cannot_change_password"]["pct_of_total"] == 0.0
