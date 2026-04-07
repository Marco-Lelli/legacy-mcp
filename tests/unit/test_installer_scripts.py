"""Textual regression tests for PowerShell installer scripts.

These tests do not execute PowerShell -- they verify that specific correct
(or incorrect) patterns are present or absent in the script source, catching
regressions that would only surface at runtime on Windows.
"""

from __future__ import annotations

from pathlib import Path

_SETUP_SCRIPT = Path("installer/Setup-LegacyMCPClient.ps1")
_INSTALL_SCRIPT = Path("installer/Install-LegacyMCP.ps1")


# ---------------------------------------------------------------------------
# Fix 2 regression: AUTH_HEADER value in JSON must NOT contain "Bearer " prefix
# ---------------------------------------------------------------------------


def test_setup_auth_header_json_value_no_bearer_prefix():
    """Fix 2: AUTH_HEADER in the JSON env block must be '${AUTH_HEADER}', not
    'Bearer ${AUTH_HEADER}'.  The env var already contains 'Bearer <key>';
    adding a prefix again would produce 'Bearer Bearer <key>' at runtime.
    """
    source = _SETUP_SCRIPT.read_text(encoding="utf-8")
    assert "Bearer ${AUTH_HEADER}" not in source, (
        "Setup-LegacyMCPClient.ps1 still contains 'Bearer ${AUTH_HEADER}' "
        "in the JSON env block -- this would double the Bearer prefix at runtime."
    )
    assert "'${AUTH_HEADER}'" in source or '"${AUTH_HEADER}"' in source, (
        "AUTH_HEADER JSON value should be '${AUTH_HEADER}' (no Bearer prefix)."
    )


# ---------------------------------------------------------------------------
# Fix 3 regression: admin guard must be present
# ---------------------------------------------------------------------------


def test_setup_admin_guard_present():
    """Fix 3: Setup-LegacyMCPClient.ps1 must refuse to run as Administrator.

    When elevated, $env:APPDATA points to the admin profile, causing
    claude_desktop_config.json to be written to the wrong location.
    The script must check for the Administrators group SID S-1-5-32-544.
    """
    source = _SETUP_SCRIPT.read_text(encoding="utf-8")
    assert "S-1-5-32-544" in source, (
        "Admin guard (S-1-5-32-544 SID check) not found in "
        "Setup-LegacyMCPClient.ps1 -- the script must refuse to run elevated."
    )


def test_setup_admin_guard_exits_on_elevation():
    """The admin guard block must call exit (not just Write-Error) to halt execution."""
    source = _SETUP_SCRIPT.read_text(encoding="utf-8")
    # Find the block containing the SID check and confirm 'exit' follows it
    idx = source.find("S-1-5-32-544")
    assert idx != -1
    surrounding = source[idx : idx + 300]
    assert "exit 1" in surrounding or "exit" in surrounding, (
        "Admin guard must call 'exit' after Write-Error to halt execution."
    )
