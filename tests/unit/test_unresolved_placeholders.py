"""Unit tests for unresolved-member placeholders (task #134 follow-up).

A member DN that cannot be resolved (orphaned SID, deleted object, foreign
principal across a broken trust) is no longer dropped. It is emitted as an
explicit placeholder row in group_members and as a placeholder element in
privileged_groups.Members, reusing the existing keys.

The point these tests defend is the one that started task #134: the
privileged-account COUNT must stay accurate. Placeholders must be visible
where they help (membership listings) and absent where they would inflate a
count (privileged_accounts).
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from legacy_mcp.workspace.workspace import (
    ForestConfig,
    ForestRelation,
    Workspace,
    WorkspaceMode,
)
from legacy_mcp.tools import groups as groups_module
from legacy_mcp.tools import users as users_module


class _MockMCP:
    """Minimal FastMCP stand-in that captures registered tool functions."""

    def tool(self):
        def decorator(fn):
            setattr(self, fn.__name__, fn)
            return fn
        return decorator


# "Administrators" holds 3 raw member DNs: one real user, one nested group,
# and one broken reference. "Domain Admins" holds 2, one of them broken.
_BROKEN_DN_1 = "CN=S-1-5-21-1111-2222-3333-4444,CN=ForeignSecurityPrincipals,DC=contoso,DC=local"
_BROKEN_DN_2 = "CN=Ghost Account,OU=Deleted,DC=contoso,DC=local"


def _payload() -> dict[str, Any]:
    return {
        "_metadata": {"module": "ad-core", "forest": "contoso.local", "domain": "contoso.local"},
        "groups": [
            # MemberCount counts RAW member DNs, so it includes the broken ones.
            {"Name": "Administrators", "SamAccountName": "Administrators",
             "DistinguishedName": "CN=Administrators,DC=contoso,DC=local",
             "GroupCategory": "Security", "GroupScope": "DomainLocal",
             "MemberCount": 3, "AdminCount": 1},
            {"Name": "Domain Admins", "SamAccountName": "Domain Admins",
             "DistinguishedName": "CN=Domain Admins,DC=contoso,DC=local",
             "GroupCategory": "Security", "GroupScope": "Global",
             "MemberCount": 2, "AdminCount": 1},
        ],
        "group_members": [
            {"GroupName": "Administrators", "MemberSamAccountName": "adm.rossi",
             "MemberDisplayName": "Alessandro Rossi", "MemberObjectClass": "user",
             "MemberDistinguishedName": "CN=Alessandro Rossi,DC=contoso,DC=local",
             "MemberEnabled": True},
            {"GroupName": "Administrators", "MemberSamAccountName": "Domain Admins",
             "MemberDisplayName": "Domain Admins", "MemberObjectClass": "group",
             "MemberDistinguishedName": "CN=Domain Admins,DC=contoso,DC=local",
             "MemberEnabled": None},
            {"GroupName": "Administrators", "MemberSamAccountName": None,
             "MemberDisplayName": None, "MemberObjectClass": "unresolved",
             "MemberDistinguishedName": _BROKEN_DN_1, "MemberEnabled": None},
            {"GroupName": "Domain Admins", "MemberSamAccountName": "adm.ferrari",
             "MemberDisplayName": "Marco Ferrari", "MemberObjectClass": "user",
             "MemberDistinguishedName": "CN=Marco Ferrari,DC=contoso,DC=local",
             "MemberEnabled": True},
            {"GroupName": "Domain Admins", "MemberSamAccountName": None,
             "MemberDisplayName": None, "MemberObjectClass": "unresolved",
             "MemberDistinguishedName": _BROKEN_DN_2, "MemberEnabled": None},
        ],
        "privileged_groups": [
            {"Group": "Administrators", "Members": [
                {"SamAccountName": "adm.rossi", "objectClass": "user",
                 "distinguishedName": "CN=Alessandro Rossi,DC=contoso,DC=local"},
                {"SamAccountName": "adm.ferrari", "objectClass": "user",
                 "distinguishedName": "CN=Marco Ferrari,DC=contoso,DC=local"},
                {"SamAccountName": None, "objectClass": "unresolved",
                 "distinguishedName": _BROKEN_DN_1},
            ]},
        ],
        # No placeholder here, by design: this section feeds a count.
        "privileged_accounts": [
            {"SamAccountName": "adm.rossi", "Group": "Administrators"},
            {"SamAccountName": "adm.ferrari", "Group": "Domain Admins"},
        ],
    }


@pytest.fixture()
def tools(tmp_path: Path) -> tuple[_MockMCP, _MockMCP]:
    path = tmp_path / "placeholders.json"
    path.write_text(json.dumps(_payload()), encoding="utf-8")
    forest = ForestConfig(
        name="contoso.local",
        relation=ForestRelation.STANDALONE,
        file=str(path),
    )
    ws = Workspace(mode=WorkspaceMode.OFFLINE, forests=[forest])
    ws._init_connectors()
    gmcp, umcp = _MockMCP(), _MockMCP()
    groups_module.register(gmcp, ws)
    users_module.register(umcp, ws)
    return gmcp, umcp


# ---------------------------------------------------------------------------
# Placeholders are visible where they belong
# ---------------------------------------------------------------------------


def test_unresolved_rows_are_listable_for_cleanup(tools):
    """The whole point of keeping the DN: produce a remediation list."""
    gmcp, _ = tools
    page = gmcp.get_group_members(group_name="Administrators")
    unresolved = [r for r in page["items"] if r["MemberObjectClass"] == "unresolved"]
    assert len(unresolved) == 1
    assert unresolved[0]["MemberDistinguishedName"] == _BROKEN_DN_1
    assert unresolved[0]["MemberSamAccountName"] in (None, "", "None")


def test_group_member_rows_match_membercount(tools):
    """rows(group_members) == MemberCount(groups) -- the invariant placeholders restore."""
    gmcp, _ = tools
    counts = {g["Name"]: int(g["MemberCount"]) for g in gmcp.get_groups()["items"]}
    for name, expected in counts.items():
        page = gmcp.get_group_members(group_name=name)
        assert page["total"] == expected, (
            f"group '{name}': {page['total']} rows vs MemberCount {expected} -- "
            "a dropped unresolved member would break this invariant"
        )


def test_privileged_groups_keeps_placeholder_with_original_keys(tools):
    """privileged_groups is the only place tying a broken DN to a privileged group."""
    gmcp, _ = tools
    admins = next(g for g in gmcp.get_privileged_groups() if g["Group"] == "Administrators")
    members = admins["Members"]
    if isinstance(members, str):
        members = json.loads(members)
    placeholders = [m for m in members if m["objectClass"] == "unresolved"]
    assert len(placeholders) == 1
    assert placeholders[0]["distinguishedName"] == _BROKEN_DN_1
    # No new key may be introduced: the SQLite schema is derived from the
    # first row of a section, so an extra field would be silently dropped.
    assert set(placeholders[0].keys()) == {"SamAccountName", "objectClass", "distinguishedName"}


# ---------------------------------------------------------------------------
# ...and absent where they would corrupt a count (the task #134 regression)
# ---------------------------------------------------------------------------


def test_privileged_accounts_total_is_not_inflated(tools):
    """tools/users.py query_page 'total' must count real accounts only.

    This is the number an LLM reads as "how many privileged accounts exist".
    Two broken DNs exist in the same expansion; neither may appear here.
    """
    _, umcp = tools
    page = umcp.get_privileged_accounts()
    assert page["total"] == 2
    sams = {r["SamAccountName"] for r in page["items"]}
    assert sams == {"adm.rossi", "adm.ferrari"}
    assert not any(
        str(r.get("SamAccountName")) in ("None", "", "unresolved") for r in page["items"]
    )


def test_no_unresolved_marker_leaks_into_privileged_accounts(tools):
    """Defence in depth: no row of that section may carry the placeholder marker."""
    _, umcp = tools
    page = umcp.get_privileged_accounts()
    for row in page["items"]:
        assert "unresolved" not in str(row.values()).lower()


def test_user_summary_unaffected_by_placeholders(tools):
    """get_user_summary reads users/, not group membership -- must stay clean."""
    _, umcp = tools
    summary = umcp.get_user_summary()
    assert summary["total"] == 0  # no users section in this payload
