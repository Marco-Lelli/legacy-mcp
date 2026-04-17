"""MCP tools — AD Users."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace

# Days without authentication before a user is considered stale.
_STALE_DAYS = 90


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_user_summary(forest_name: str | None = None) -> dict[str, Any]:
        """Return user counts by state: total, enabled, disabled, locked out,
        password-never-expires, password-not-required, delegation configured,
        and accounts inactive for more than 90 days."""
        conn = workspace.connector(forest_name)
        users = conn.query("users")
        now = datetime.now(tz=timezone.utc)

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

        return {
            "total":                  len(users),
            "enabled":                sum(1 for u in users if u.get("Enabled") == "True"),
            "disabled":               sum(1 for u in users if u.get("Enabled") == "False"),
            "password_never_expires": sum(1 for u in users if u.get("PasswordNeverExpires") == "True"),
            "password_not_required":  sum(1 for u in users if u.get("PasswordNotRequired") == "True"),
            "locked_out":             sum(1 for u in users if u.get("LockedOut") == "True"),
            "delegation_configured":  sum(
                1 for u in users
                if u.get("TrustedForDelegation") == "True"
                or u.get("TrustedToAuthForDelegation") == "True"
                or u.get("AllowedToDelegateTo")
            ),
            "stale_90d":              stale,
        }

    @mcp.tool()
    def get_privileged_accounts(
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 200,
    ) -> dict[str, Any]:
        """Return accounts that are members of privileged groups
        (Domain Admins, Enterprise Admins, Schema Admins, Administrators).

        Returns a paginated result: {items, total, offset, limit, has_more}.
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
        password_never_expires: bool | None = None,
        locked_out: bool | None = None,
        has_sid_history: bool | None = None,
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 200,
    ) -> dict[str, Any]:
        """Return AD user accounts with semantic filters to keep responses
        small on large environments (1000+ users).

        Filters (all combinable, applied in sequence):

        enabled:
            True = only enabled accounts, False = only disabled, None = all.
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
            high-value targets — use this to find misconfigurations.
        password_never_expires:
            True = only accounts with PasswordNeverExpires set.
            False = only accounts where password does expire.
            None = all.
        locked_out:
            True = only locked-out accounts.
            False = only non-locked accounts.
            None = all.
        has_sid_history:
            True = only accounts with a non-empty SIDHistory (migrated accounts,
            M&A scenarios). False = only accounts without SIDHistory. None = all.
        forest_name:
            Target forest. Defaults to the first forest in the workspace.

        Recommended workflow for large environments:
          1. Call get_user_summary for totals and a quick hygiene overview.
          2. Call get_privileged_accounts for privileged group members.
          3. Use get_users with specific filters for focused findings
             (e.g. stale_only=True, delegation_only=True, admin_count=True).
          4. Use get_user_by_name for point lookups on a specific account.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        total reflects the filtered count before pagination.
        Default limit is 200.
        """
        conn = workspace.connector(forest_name)
        users = conn.query("users")

        if enabled is not None:
            users = [u for u in users if u.get("Enabled") == str(enabled)]

        if admin_count is True:
            users = [u for u in users if u.get("AdminCount") == "1"]
        elif admin_count is False:
            users = [u for u in users if u.get("AdminCount") != "1"]

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
                if u.get("TrustedForDelegation") == "True"
                or u.get("TrustedToAuthForDelegation") == "True"
                or u.get("AllowedToDelegateTo")
            ]

        if password_never_expires is True:
            users = [u for u in users if u.get("PasswordNeverExpires") == "True"]
        elif password_never_expires is False:
            users = [u for u in users if u.get("PasswordNeverExpires") != "True"]

        if locked_out is True:
            users = [u for u in users if u.get("LockedOut") == "True"]
        elif locked_out is False:
            users = [u for u in users if u.get("LockedOut") != "True"]

        if has_sid_history is True:
            users = [u for u in users if u.get("SIDHistory")]
        elif has_sid_history is False:
            users = [u for u in users if not u.get("SIDHistory")]

        total = len(users)
        page = users[offset : offset + limit]
        return {
            "items":    page,
            "total":    total,
            "offset":   offset,
            "limit":    limit,
            "has_more": offset + len(page) < total,
        }

    @mcp.tool()
    def get_user_by_name(
        sam_account_name: str,
        forest_name: str | None = None,
    ) -> dict[str, Any] | None:
        """Return the full record for a single user looked up by SamAccountName.

        Returns null if the account is not found. Use this for point lookups
        when you already know the account name — avoids loading the full
        user list.
        """
        conn = workspace.connector(forest_name)
        results = conn.query("users", SamAccountName=sam_account_name)
        return results[0] if results else None
