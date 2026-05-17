"""Textual regression tests for PowerShell installer scripts.

These tests do not execute PowerShell -- they verify that specific correct
(or incorrect) patterns are present or absent in the script source, catching
regressions that would only surface at runtime on Windows.

After Fase 3 the monolithic Setup-LegacyMCPClient.ps1 was replaced by:
  - installer/Setup-LegacyMCP.ps1        -- unified orchestrator
  - installer/modules/LegacyMCP.Client.psm1  -- B-Client implementation
  - installer/modules/LegacyMCP.Common.psm1  -- shared utilities (elevation check)
"""

from __future__ import annotations

from pathlib import Path

_SETUP_SCRIPT  = Path("installer/Setup-LegacyMCP.ps1")
_CLIENT_MODULE = Path("installer/modules/LegacyMCP.Client.psm1")
_COMMON_MODULE = Path("installer/modules/LegacyMCP.Common.psm1")


# ---------------------------------------------------------------------------
# F3: API key stored as DPAPI file, not as AUTH_HEADER env var
# ---------------------------------------------------------------------------


def test_setup_uses_dpapi_not_auth_header_env_var():
    """F3: B-Client setup must encrypt the API key with DPAPI, not set AUTH_HEADER.

    The old approach stored the key as AUTH_HEADER in the User environment.
    The new approach encrypts with ConvertFrom-SecureString and writes .legacymcp-key.
    AUTH_HEADER must appear in neither the orchestrator nor the client module.
    """
    orchestrator = _SETUP_SCRIPT.read_text(encoding="utf-8")
    client = _CLIENT_MODULE.read_text(encoding="utf-8")
    assert "AUTH_HEADER" not in orchestrator, (
        "Setup-LegacyMCP.ps1 must not reference AUTH_HEADER. "
        "The API key must be stored as a DPAPI-encrypted .legacymcp-key file."
    )
    assert "AUTH_HEADER" not in client, (
        "LegacyMCP.Client.psm1 must not reference AUTH_HEADER. "
        "The API key must be stored as a DPAPI-encrypted .legacymcp-key file."
    )
    assert "ConvertFrom-SecureString" in client, (
        "LegacyMCP.Client.psm1 must use ConvertFrom-SecureString to encrypt "
        "the API key with DPAPI user-scope (Protect-LMClientApiKey)."
    )


def test_setup_writes_legacymcp_key_file():
    """F3: B-Client setup must write the DPAPI-encrypted key to .legacymcp-key."""
    source = _SETUP_SCRIPT.read_text(encoding="utf-8")
    assert ".legacymcp-key" in source, (
        "Setup-LegacyMCP.ps1 must reference .legacymcp-key as the output "
        "file for the DPAPI-encrypted API key."
    )


def test_setup_generates_bat_entry_point():
    """Bug #3: B-Client setup must generate mcp-remote-live.bat as Claude Desktop entry.

    Claude Desktop breaks when powershell.exe is used directly as MCP command:
    PowerShell emits startup output to stdout before mcp-remote takes over,
    corrupting the JSON-RPC framing.  The BAT (-NoProfile -NonInteractive) is
    the only reliable entry point.
    """
    orchestrator = _SETUP_SCRIPT.read_text(encoding="utf-8")
    client = _CLIENT_MODULE.read_text(encoding="utf-8")
    assert "mcp-remote-live.bat" in orchestrator, (
        "Setup-LegacyMCP.ps1 must reference mcp-remote-live.bat "
        "as the Claude Desktop entry point."
    )
    assert "command = $BatPath" in client, (
        "The legacymcp-live JSON entry command must be $BatPath (the generated BAT), "
        "not a hardcoded 'powershell.exe' string."
    )


def test_setup_bat_sets_node_extra_ca_certs():
    """Bug #3: Generated BAT must set NODE_EXTRA_CA_CERTS explicitly.

    Claude Desktop child processes do not reliably inherit User-scope env vars.
    The BAT must set NODE_EXTRA_CA_CERTS in the process environment before
    invoking mcp-remote-live.ps1 / npx.
    NODE_EXTRA_CA_CERTS is emitted by New-LMMcpRemoteBat in LegacyMCP.Client.psm1.
    """
    client = _CLIENT_MODULE.read_text(encoding="utf-8")
    bat_fn_idx = client.find("New-LMMcpRemoteBat")
    assert bat_fn_idx != -1, "New-LMMcpRemoteBat function not found in LegacyMCP.Client.psm1."
    bat_section = client[bat_fn_idx:bat_fn_idx + 800]
    assert "NODE_EXTRA_CA_CERTS" in bat_section, (
        "New-LMMcpRemoteBat must include 'set NODE_EXTRA_CA_CERTS=...' so the "
        "certificate path is available to Node.js / npx at process startup."
    )


# ---------------------------------------------------------------------------
# Fix 3 regression: admin guard must be present
# ---------------------------------------------------------------------------


def test_setup_admin_guard_present():
    """Fix 3: Profile A setup must refuse to run as Administrator.

    When elevated, $env:APPDATA points to the admin profile, causing
    claude_desktop_config.json to be written to the wrong location.
    The orchestrator must throw when Profile A is run elevated.
    """
    source = _SETUP_SCRIPT.read_text(encoding="utf-8")
    assert "must NOT run as Administrator" in source, (
        "Admin guard not found in Setup-LegacyMCP.ps1 -- the script must throw "
        "when Profile A is run as Administrator."
    )


def test_setup_admin_guard_exits_on_elevation():
    """The admin guard block must throw to halt execution on elevation."""
    source = _SETUP_SCRIPT.read_text(encoding="utf-8")
    idx = source.find("must NOT run as Administrator")
    assert idx != -1, "Admin guard message not found in Setup-LegacyMCP.ps1."
    surrounding = source[max(0, idx - 100) : idx + 300]
    assert "throw" in surrounding, (
        "Admin guard must call 'throw' to halt execution when Profile A is run elevated."
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
    The [ordered]@{} and ConvertTo-Json are in LegacyMCP.Client.psm1.
    """
    client = _CLIENT_MODULE.read_text(encoding="utf-8")
    assert "[ordered]@{" in client, (
        "LegacyMCP.Client.psm1 must use [ordered]@{} to build JSON entry "
        "objects so ConvertTo-Json serialises path strings without surprises."
    )
    json_pos = client.find("ConvertTo-Json")
    write_pos = client.find("WriteAllText")
    assert json_pos != -1, "ConvertTo-Json not found in LegacyMCP.Client.psm1."
    assert write_pos != -1, "WriteAllText not found in LegacyMCP.Client.psm1."
    between = client[json_pos:write_pos]
    assert "-replace" not in between, (
        "The -replace '\\\\\\\\' workaround must be removed. "
        "With [ordered]@{} + plain PS strings, ConvertTo-Json escapes correctly."
    )


def test_setup_json_bom_free_encoding():
    """Bug #2: WriteAllText must use BOM-free UTF-8 (New-Object System.Text.UTF8Encoding $false).

    [System.Text.Encoding]::UTF8 produces a UTF-8 BOM (EF BB BF) at the start
    of the file. Claude Desktop's JSON parser rejects files with a BOM.
    The encoding is handled in LegacyMCP.Client.psm1.
    """
    client = _CLIENT_MODULE.read_text(encoding="utf-8")
    assert "UTF8Encoding" in client, (
        "WriteAllText must use (New-Object System.Text.UTF8Encoding $false) "
        "for BOM-free output."
    )
    assert "$false" in client, (
        "The UTF8Encoding constructor must pass $false (no BOM). "
        "Omitting the argument or passing $true produces a BOM."
    )
    write_pos = client.find("WriteAllText")
    assert write_pos != -1, "WriteAllText not found in LegacyMCP.Client.psm1."
    write_area = client[write_pos : write_pos + 250]
    assert "[System.Text.Encoding]::UTF8" not in write_area, (
        "[System.Text.Encoding]::UTF8 in WriteAllText produces a BOM. "
        "Use (New-Object System.Text.UTF8Encoding $false) instead."
    )
