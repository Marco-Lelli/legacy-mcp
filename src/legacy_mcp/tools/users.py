"""MCP tools — AD Users."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import TYPE_CHECKING, Any

from legacy_mcp.tools._normalize import is_admin_count_set, is_false as _is_false, is_true as _is_true

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace

# Days without authentication before a user is considered stale.
_STALE_DAYS = 90


def _get_primary_group_id(u: dict) -> int:
    """Normalize PrimaryGroupID to int regardless of source shape.

    Live Mode may return PrimaryGroupID as a single-element Object[] (list)
    rather than a scalar. Offline Mode serializes it to a string via the
    SQLite loader. Both forms are handled here so filter logic stays uniform.
    """
    val = u.get("PrimaryGroupID", 513)
    if isinstance(val, list):
        val = val[0] if val else 513
    try:
        return int(val)
    except (TypeError, ValueError):
        return 513


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_user_summary(forest_name: str | None = None) -> dict[str, Any]:
        """Return user counts by state: total, enabled, disabled, locked out,
        password-never-expires, password-not-required, delegation configured,
        accounts inactive for more than 90 days, and uac_unreadable_count.

        enabled and disabled are strict: an account only counts toward one
        of them when Enabled is explicitly True/False. Accounts whose
        userAccountControl could not be read (Enabled is null, task #131)
        count toward neither -- they are reported separately in
        uac_unreadable_count instead, so enabled + disabled +
        uac_unreadable_count == total always holds (task #136). The same
        userAccountControl read also backs PasswordNeverExpires,
        TrustedForDelegation, TrustedToAuthForDelegation, and
        PasswordNotRequired (task #135) -- they go null for the same users
        at the same time, so a single count covers all 5.

        In Live Mode, the result may include a "warnings" list (e.g.
        userAccountControl unreadable for N users). Present only when
        something actually degraded this collection; absent otherwise.
        """
        conn = workspace.connector(forest_name)
        users, warnings = conn.query_with_warnings("users")
        now = datetime.now(tz=timezone.utc)
        total = len(users)
        enabled_count = sum(1 for u in users if _is_true(u.get("Enabled")))
        disabled_count = sum(1 for u in users if _is_false(u.get("Enabled")))
        # Enabled is the representative field for the shared null cause --
        # all 5 UAC-derived fields go null together for the same user
        # (Users.psm1 / live.py compute them in the same if/else block from
        # a single $uac read), so checking just this one is exact, not an
        # approximation (confirmed in Fase 1 analysis, task #136).
        uac_unreadable_count = sum(1 for u in users if u.get("Enabled") is None)

        stale = 0
        for u in users:
            last_logon = u.get("LastLogonDate")
            is_stale = True
            if last_logon:
                try:
                    dt = datetime.fromisoformat(str(last_logon).rstrip("Z"))
                    if dt.tzinfo is None:
                        dt = dt.replace(tzinfo=timezone.utc)
                    is_stale = (now - dt).days > _STALE_DAYS
                except ValueError:
                    pass
            if is_stale:
                stale += 1

        no_logon_count = sum(1 for u in users if not u.get("LastLogonDate"))
        no_logon_active = sum(
            1 for u in users
            if not u.get("LastLogonDate") and _is_true(u.get("Enabled"))
        )
        pgid_count = sum(1 for u in users if _get_primary_group_id(u) != 513)
        ccp_count = sum(1 for u in users if _is_true(u.get("CannotChangePassword")))

        result: dict[str, Any] = {
            "total":                  total,
            "enabled":                enabled_count,
            "disabled":               disabled_count,
            "uac_unreadable_count":   uac_unreadable_count,
            "password_never_expires": sum(1 for u in users if _is_true(u.get("PasswordNeverExpires"))),
            "password_not_required":  sum(1 for u in users if _is_true(u.get("PasswordNotRequired"))),
            "locked_out":             sum(1 for u in users if _is_true(u.get("LockedOut"))),
            "delegation_configured":  sum(
                1 for u in users
                if _is_true(u.get("TrustedForDelegation"))
                or _is_true(u.get("TrustedToAuthForDelegation"))
                or u.get("AllowedToDelegateTo")
            ),
            "stale_90d":              stale,
            "no_last_logon": {
                "count":         no_logon_count,
                "pct_of_total":  round(no_logon_count / total * 100, 2) if total > 0 else 0.0,
                "active_count":  no_logon_active,
                "pct_of_active": round(no_logon_active / enabled_count * 100, 2) if enabled_count > 0 else 0.0,
            },
            "primary_group_not_domain_users": {
                "count":        pgid_count,
                "pct_of_total": round(pgid_count / total * 100, 2) if total > 0 else 0.0,
            },
            "cannot_change_password": {
                "count":        ccp_count,
                "pct_of_total": round(ccp_count / total * 100, 2) if total > 0 else 0.0,
            },
        }
        # task #141: present only when this call actually produced a
        # warning (e.g. userAccountControl null for N users) -- omitted
        # otherwise, same convention as LiveConnector.query_page().
        if warnings:
            result["warnings"] = warnings
        return result

    @mcp.tool()
    def get_privileged_accounts(
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 200,
    ) -> dict[str, Any]:
        """Return accounts that are members of privileged groups
        (Domain Admins, Enterprise Admins, Schema Admins, Administrators).

        Returns a paginated result: {items, total, offset, limit, has_more}.
        May include a "warnings" list in Live Mode (present only when
        something degraded this collection; absent otherwise).
        Default limit is 200.
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("privileged_accounts", offset=offset, limit=limit)

    @mcp.tool()
    def get_users(
        enabled: bool | None = None,
        admin_count: bool | None = None,
        stale_only: bool = False,
        delegation_only: bool = False,
        uac_unreadable: bool = False,
        password_never_expires: bool | None = None,
        password_not_required: bool | None = None,
        locked_out: bool | None = None,
        has_sid_history: bool | None = None,
        no_last_logon: bool = False,
        primary_group_not_domain_users: bool = False,
        cannot_change_password: bool = False,
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 200,
    ) -> dict[str, Any]:
        """Return AD user accounts with semantic filters to keep responses
        small on large environments (1000+ users).

        Filters (all combinable, applied in sequence):

        enabled:
            True = only accounts with Enabled explicitly True, False = only
            accounts with Enabled explicitly False, None = all. Accounts
            whose userAccountControl could not be read (Enabled is null,
            task #131) match neither True nor False -- use uac_unreadable=True
            to retrieve them.
        admin_count:
            True = only accounts with AdminCount=1 (SDProp-protected, i.e.
            current or former privileged group members).
            False = only accounts without AdminCount set.
            None = all.
        stale_only:
            If True, return only accounts with no logon in 90+ days or that
            have never logged on. Useful for identifying inactive users.
        delegation_only:
            If True, return only accounts with any form of Kerberos delegation
            (TrustedForDelegation, TrustedToAuthForDelegation, or
            AllowedToDelegateTo set). Service accounts with delegation are
            high-value targets — use this to find misconfigurations. Accounts
            whose userAccountControl could not be read are excluded unless
            AllowedToDelegateTo is independently set (that field does not
            depend on userAccountControl) -- their delegation status via
            TrustedForDelegation/TrustedToAuthForDelegation is unknown, not
            confirmed absent; cross-check with uac_unreadable=True.
        uac_unreadable:
            If True, return only accounts whose userAccountControl could not
            be read during collection (Enabled, PasswordNeverExpires,
            TrustedForDelegation, TrustedToAuthForDelegation, and
            PasswordNotRequired are all null for these accounts — task #135,
            #136). Combining this with enabled/password_never_expires/
            password_not_required True or False, or with delegation_only,
            always returns an empty result, since those filters require a
            confirmed value on fields this population does not have by
            definition.
        password_never_expires:
            True = only accounts with PasswordNeverExpires explicitly True,
            False = only accounts with PasswordNeverExpires explicitly False,
            None = all. Same null handling as enabled above.
        password_not_required:
            True = only accounts with PasswordNotRequired explicitly True
            (PASSWD_NOTREQD set — the account can have a blank password),
            False = only accounts with PasswordNotRequired explicitly False,
            None = all. Same null handling as enabled above.
        locked_out:
            True = only locked-out accounts.
            False = only non-locked accounts.
            None = all.
        has_sid_history:
            True = only accounts with a non-empty SIDHistory (migrated accounts,
            M&A scenarios). False = only accounts without SIDHistory. None = all.
        no_last_logon:
            If True, return only accounts that have never logged on
            (LastLogonDate is absent or null). Useful for identifying accounts
            created but never used.
        primary_group_not_domain_users:
            If True, return only accounts whose primary group is not Domain Users
            (PrimaryGroupID != 513). May indicate misconfigurations or privileged
            account remnants.
        cannot_change_password:
            If True, return only accounts where the user cannot change their own
            password. May indicate restricted service accounts or compliance
            policy enforcement.
        forest_name:
            Target forest. Defaults to the first forest in the workspace.

        Recommended workflow for large environments:
          1. Call get_user_summary for totals and a quick hygiene overview.
          2. Call get_privileged_accounts for privileged group members.
          3. Use get_users with specific filters for focused findings
             (e.g. stale_only=True, delegation_only=True, admin_count=True).
          4. Use get_user_by_name for point lookups on a specific account.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        total reflects the filtered count before pagination. May include a
        "warnings" list in Live Mode -- present only when something
        degraded this collection (e.g. userAccountControl unreadable for
        some users); absent otherwise.
        Default limit is 200.
        """
        conn = workspace.connector(forest_name)
        users, warnings = conn.query_with_warnings("users")

        if enabled is True:
            users = [u for u in users if _is_true(u.get("Enabled"))]
        elif enabled is False:
            users = [u for u in users if _is_false(u.get("Enabled"))]

        if uac_unreadable:
            users = [u for u in users if u.get("Enabled") is None]

        if admin_count is True:
            users = [u for u in users if is_admin_count_set(u.get("AdminCount"))]
        elif admin_count is False:
            users = [u for u in users if not is_admin_count_set(u.get("AdminCount"))]

        if stale_only:
            now = datetime.now(tz=timezone.utc)
            filtered = []
            for u in users:
                last_logon = u.get("LastLogonDate")
                is_stale = True
                if last_logon:
                    try:
                        dt = datetime.fromisoformat(str(last_logon).rstrip("Z"))
                        if dt.tzinfo is None:
                            dt = dt.replace(tzinfo=timezone.utc)
                        is_stale = (now - dt).days > _STALE_DAYS
                    except ValueError:
                        pass
                if is_stale:
                    filtered.append(u)
            users = filtered

        if delegation_only:
            users = [
                u for u in users
                if _is_true(u.get("TrustedForDelegation"))
                or _is_true(u.get("TrustedToAuthForDelegation"))
                or u.get("AllowedToDelegateTo")
            ]

        if password_never_expires is True:
            users = [u for u in users if _is_true(u.get("PasswordNeverExpires"))]
        elif password_never_expires is False:
            users = [u for u in users if _is_false(u.get("PasswordNeverExpires"))]

        if password_not_required is True:
            users = [u for u in users if _is_true(u.get("PasswordNotRequired"))]
        elif password_not_required is False:
            users = [u for u in users if _is_false(u.get("PasswordNotRequired"))]

        if locked_out is True:
            users = [u for u in users if _is_true(u.get("LockedOut"))]
        elif locked_out is False:
            users = [u for u in users if not _is_true(u.get("LockedOut"))]

        if has_sid_history is True:
            users = [u for u in users if u.get("SIDHistory")]
        elif has_sid_history is False:
            users = [u for u in users if not u.get("SIDHistory")]

        if no_last_logon:
            users = [u for u in users if not u.get("LastLogonDate")]

        if primary_group_not_domain_users:
            users = [u for u in users if _get_primary_group_id(u) != 513]

        if cannot_change_password:
            users = [u for u in users if _is_true(u.get("CannotChangePassword"))]

        total = len(users)
        page = users[offset : offset + limit]
        result: dict[str, Any] = {
            "items":    page,
            "total":    total,
            "offset":   offset,
            "limit":    limit,
            "has_more": offset + len(page) < total,
        }
        # task #141: present only when this call actually produced a
        # warning -- omitted otherwise, same convention as query_page().
        if warnings:
            result["warnings"] = warnings
        return result

    @mcp.tool()
    def get_user_by_name(
        sam_account_name: str,
        forest_name: str | None = None,
    ) -> dict[str, Any] | None:
        """Return the full record for a single user looked up by SamAccountName.

        Returns null if the account is not found. Use this for point lookups
        when you already know the account name — avoids loading the full
        user list.

        Does not surface a "warnings" field (single-object return, no
        natural place for it) -- any collection warning for this section is
        still captured in full in the server's EventLog. Use get_users or
        get_user_summary if you need warnings in the response itself.
        """
        conn = workspace.connector(forest_name)
        results = conn.query("users", SamAccountName=sam_account_name)
        return results[0] if results else None
