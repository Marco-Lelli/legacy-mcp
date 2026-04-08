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


def test_setup_json_entry_uses_ps1_wrapper():
    """F3: The claude_desktop_config.json entry must invoke mcp-remote-live.ps1,
    not call npx/mcp-remote directly.
    """
    source = _SETUP_SCRIPT.read_text(encoding="utf-8")
    assert "mcp-remote-live.ps1" in source, (
        "Setup-LegacyMCPClient.ps1 must build a claude_desktop_config.json entry "
        "that invokes mcp-remote-live.ps1 (which reads the key from .legacymcp-key)."
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
# Bug D regression: ConvertTo-Json backslash normalisation
# ---------------------------------------------------------------------------


def test_setup_json_backslash_normalisation_present():
    """Bug D: ConvertTo-Json doubles backslashes (\\ -> \\\\) in Windows paths.
    The script must apply a normalisation pass (-replace '\\\\\\\\', '\\\\')
    between ConvertTo-Json and writing the file.
    """
    source = _SETUP_SCRIPT.read_text(encoding="utf-8")
    # The normalisation must appear between ConvertTo-Json and the file write.
    json_pos = source.find("ConvertTo-Json")
    write_pos = source.find("WriteAllText")
    assert json_pos != -1, "ConvertTo-Json not found in script."
    assert write_pos != -1, "WriteAllText not found in script."
    between = source[json_pos:write_pos]
    assert "-replace" in between, (
        "No -replace normalisation found between ConvertTo-Json and WriteAllText. "
        "ConvertTo-Json doubles backslashes; the result must be normalised before "
        "writing to disk."
    )


def test_setup_json_output_valid_after_normalisation():
    """Bug D: simulate the ConvertTo-Json backslash-doubling + normalisation and
    verify the final string parses as valid JSON with single-escaped paths (\\).
    """
    import json
    import re

    # Simulate a Windows path that ConvertTo-Json would double-escape
    raw_path = r"C:\legacy-mcp\certs\server.crt"
    # ConvertTo-Json encodes \ as \\ in the JSON string, so the resulting
    # JSON text contains \\\\ (four backslashes = two escaped backslashes).
    simulated_json = json.dumps({"NODE_EXTRA_CA_CERTS": raw_path})
    # Verify it round-trips correctly through json.loads
    parsed = json.loads(simulated_json)
    assert parsed["NODE_EXTRA_CA_CERTS"] == raw_path

    # Now simulate the PowerShell ConvertTo-Json bug: it produces \\\\ in the
    # JSON text where \\ is correct (i.e. it double-escapes).
    bugged_json = simulated_json.replace("\\\\", "\\\\\\\\")
    # The normalisation pass fixes it: replace \\\\ with \\
    normalised = bugged_json.replace("\\\\\\\\", "\\\\")
    parsed2 = json.loads(normalised)
    assert parsed2["NODE_EXTRA_CA_CERTS"] == raw_path, (
        "After normalisation the path must survive a json.loads round-trip intact."
    )
    assert "\\\\" not in normalised or normalised.count("\\\\") == simulated_json.count("\\\\"), (
        "Normalised JSON must not contain quadruple backslashes."
    )
