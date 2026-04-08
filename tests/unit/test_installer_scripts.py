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
# F3: API key stored as DPAPI file, not as AUTH_HEADER env var
# ---------------------------------------------------------------------------


def test_setup_uses_dpapi_not_auth_header_env_var():
    """F3: Setup must encrypt the API key with DPAPI, not set AUTH_HEADER env var.

    The old approach stored the key as AUTH_HEADER in the User environment.
    The new approach encrypts with ConvertFrom-SecureString and writes .legacymcp-key.
    """
    source = _SETUP_SCRIPT.read_text(encoding="utf-8")
    assert "AUTH_HEADER" not in source, (
        "Setup-LegacyMCPClient.ps1 must not reference AUTH_HEADER at all. "
        "The API key must be stored as a DPAPI-encrypted .legacymcp-key file."
    )
    assert "ConvertFrom-SecureString" in source, (
        "Setup-LegacyMCPClient.ps1 must use ConvertFrom-SecureString to encrypt "
        "the API key with DPAPI user-scope."
    )


def test_setup_writes_legacymcp_key_file():
    """F3: Setup must write the DPAPI-encrypted key to .legacymcp-key."""
    source = _SETUP_SCRIPT.read_text(encoding="utf-8")
    assert ".legacymcp-key" in source, (
        "Setup-LegacyMCPClient.ps1 must reference .legacymcp-key as the output "
        "file for the DPAPI-encrypted API key."
    )


def test_setup_generates_bat_entry_point():
    """Bug #3: Setup must generate client\\mcp-remote-live.bat as Claude Desktop entry.

    Claude Desktop breaks when powershell.exe is used directly as MCP command:
    PowerShell emits startup output to stdout before mcp-remote takes over,
    corrupting the JSON-RPC framing.  The BAT (-NoProfile -NonInteractive) is
    the only reliable entry point.
    """
    source = _SETUP_SCRIPT.read_text(encoding="utf-8")
    assert "mcp-remote-live.bat" in source, (
        "Setup-LegacyMCPClient.ps1 must generate client\\mcp-remote-live.bat "
        "as the Claude Desktop entry point (not invoke powershell.exe directly)."
    )
    assert "command = $batPath" in source, (
        "The legacymcp-live JSON entry command must be $batPath (the generated BAT), "
        "not a hardcoded 'powershell.exe' string."
    )


def test_setup_bat_sets_node_extra_ca_certs():
    """Bug #3: Generated BAT must set NODE_EXTRA_CA_CERTS explicitly.

    Claude Desktop child processes do not reliably inherit User-scope env vars.
    The BAT must set NODE_EXTRA_CA_CERTS in the process environment before
    invoking mcp-remote-live.ps1 / npx.
    """
    source = _SETUP_SCRIPT.read_text(encoding="utf-8")
    # The BAT content in the script must include NODE_EXTRA_CA_CERTS assignment
    bat_idx = source.find("batContent")
    assert bat_idx != -1, "$batContent variable not found in script."
    bat_section = source[bat_idx:bat_idx + 600]
    assert "NODE_EXTRA_CA_CERTS" in bat_section, (
        "The BAT content must include 'set NODE_EXTRA_CA_CERTS=...' so the "
        "certificate path is available to Node.js / npx at process startup."
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


# ---------------------------------------------------------------------------
# Bug #1: JSON must use [ordered]@{} -- no -replace workaround needed
# Bug #2: WriteAllText must use BOM-free UTF-8 encoding
# ---------------------------------------------------------------------------


def test_setup_json_uses_ordered_dict_no_replace_workaround():
    """Bug #1: JSON entries must be built with [ordered]@{} + plain PS path strings.

    ConvertTo-Json handles backslash escaping correctly when path strings are
    inserted as normal PS variables (single backslash).  The old -replace
    '\\\\\\\\' workaround was needed when paths were pre-escaped; it is now
    removed to avoid double-fixing that never existed.
    """
    source = _SETUP_SCRIPT.read_text(encoding="utf-8")
    assert "[ordered]@{" in source, (
        "Setup-LegacyMCPClient.ps1 must use [ordered]@{} to build JSON entry "
        "objects so ConvertTo-Json serialises path strings without surprises."
    )
    # Verify the old quadruple-backslash workaround is gone
    json_pos = source.find("ConvertTo-Json")
    write_pos = source.find("WriteAllText")
    assert json_pos != -1, "ConvertTo-Json not found in script."
    assert write_pos != -1, "WriteAllText not found in script."
    between = source[json_pos:write_pos]
    assert "-replace" not in between, (
        "The -replace '\\\\\\\\' workaround must be removed. "
        "With [ordered]@{} + plain PS strings, ConvertTo-Json escapes correctly."
    )


def test_setup_json_bom_free_encoding():
    """Bug #2: WriteAllText must use BOM-free UTF-8 (New-Object System.Text.UTF8Encoding $false).

    [System.Text.Encoding]::UTF8 produces a UTF-8 BOM (EF BB BF) at the start
    of the file. Claude Desktop's JSON parser rejects files with a BOM.
    """
    source = _SETUP_SCRIPT.read_text(encoding="utf-8")
    # The BOM-free constructor must be present
    assert "UTF8Encoding" in source, (
        "WriteAllText must use (New-Object System.Text.UTF8Encoding $false) "
        "for BOM-free output."
    )
    assert "$false" in source, (
        "The UTF8Encoding constructor must pass $false (no BOM). "
        "Omitting the argument or passing $true produces a BOM."
    )
    # The old BOM-producing form must not be in the WriteAllText call area
    write_pos = source.find("WriteAllText")
    assert write_pos != -1, "WriteAllText not found in script."
    write_area = source[write_pos: write_pos + 250]
    assert "[System.Text.Encoding]::UTF8" not in write_area, (
        "[System.Text.Encoding]::UTF8 in WriteAllText produces a BOM. "
        "Use (New-Object System.Text.UTF8Encoding $false) instead."
    )
