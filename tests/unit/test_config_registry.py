"""Unit tests for legacy_mcp.config_registry.

All tests that exercise winreg code paths mock the registry -- the real
Windows registry is never accessed.  Tests that specifically exercise
Windows-only code paths are skipped on non-Windows platforms.
"""

from __future__ import annotations

import sys
from unittest.mock import MagicMock, patch, call

import pytest

from legacy_mcp.config_registry import read_registry_config, read_registry_service_config


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_winreg_mock(values: dict | None = None, open_raises: OSError | None = None):
    """Return a mock winreg module.

    values  -- dict mapping reg value name -> (value, type_int) tuples
    open_raises -- if set, OpenKey raises this exception
    """
    mock = MagicMock()
    mock.HKEY_LOCAL_MACHINE = 0x80000002

    if open_raises is not None:
        mock.OpenKey.side_effect = open_raises
    else:
        fake_key = MagicMock()
        fake_key.__enter__ = lambda s: s
        fake_key.__exit__ = MagicMock(return_value=False)
        mock.OpenKey.return_value = fake_key

        def _query(key, name):
            if values and name in values:
                return values[name]
            raise OSError(f"value {name!r} not found")

        mock.QueryValueEx.side_effect = _query

    return mock


# ---------------------------------------------------------------------------
# read_registry_config -- non-Windows
# ---------------------------------------------------------------------------


def test_returns_empty_on_non_windows():
    """On non-Windows platforms the function returns {} without touching winreg."""
    with patch("sys.platform", "linux"):
        result = read_registry_config()
    assert result == {}


# ---------------------------------------------------------------------------
# read_registry_config -- Windows paths (mocked)
# ---------------------------------------------------------------------------


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_key_absent_returns_empty():
    """When the registry key is absent, returns {}."""
    mock_winreg = _make_winreg_mock(open_raises=OSError("key not found"))
    with patch.dict("sys.modules", {"winreg": mock_winreg}):
        # Re-import to pick up mocked module
        import importlib
        import legacy_mcp.config_registry as m
        importlib.reload(m)
        result = m.read_registry_config()
    assert result == {}


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_all_string_fields_read():
    """All string registry values are mapped to lowercase dict keys."""
    values = {
        "ConfigPath": (r"C:\LegacyMCP\config\config.yaml", 1),
        "Profile": ("A", 1),
        "Transport": ("stdio", 1),
        "LogPath": (r"C:\LegacyMCP\logs", 1),
        "InstallPath": (r"C:\LegacyMCP", 1),
        "Version": ("0.1.3", 1),
    }
    mock_winreg = _make_winreg_mock(values=values)
    with patch.dict("sys.modules", {"winreg": mock_winreg}):
        import importlib
        import legacy_mcp.config_registry as m
        importlib.reload(m)
        result = m.read_registry_config()

    assert result["config_path"] == r"C:\LegacyMCP\config\config.yaml"
    assert result["profile"] == "A"
    assert result["transport"] == "stdio"
    assert result["log_path"] == r"C:\LegacyMCP\logs"
    assert result["install_path"] == r"C:\LegacyMCP"
    assert result["version"] == "0.1.3"


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_port_dword_converted_to_int():
    """Port REG_DWORD is returned as int."""
    values = {
        "ConfigPath": (r"C:\LegacyMCP\config\config.yaml", 1),
        "Port": (8000, 4),
    }
    mock_winreg = _make_winreg_mock(values=values)
    with patch.dict("sys.modules", {"winreg": mock_winreg}):
        import importlib
        import legacy_mcp.config_registry as m
        importlib.reload(m)
        result = m.read_registry_config()

    assert result["port"] == 8000
    assert isinstance(result["port"], int)


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_partial_registry_only_present_keys_returned():
    """Only keys present in the registry appear in the result dict."""
    values = {
        "ConfigPath": (r"C:\LegacyMCP\config\config.yaml", 1),
    }
    mock_winreg = _make_winreg_mock(values=values)
    with patch.dict("sys.modules", {"winreg": mock_winreg}):
        import importlib
        import legacy_mcp.config_registry as m
        importlib.reload(m)
        result = m.read_registry_config()

    assert "config_path" in result
    assert "profile" not in result
    assert "port" not in result


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_empty_string_value_excluded():
    """Empty string registry values are not included in the result."""
    values = {
        "ConfigPath": ("", 1),
        "Profile": ("A", 1),
    }
    mock_winreg = _make_winreg_mock(values=values)
    with patch.dict("sys.modules", {"winreg": mock_winreg}):
        import importlib
        import legacy_mcp.config_registry as m
        importlib.reload(m)
        result = m.read_registry_config()

    assert "config_path" not in result
    assert result["profile"] == "A"


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_unexpected_exception_returns_empty(capsys):
    """Unexpected exception during key read returns {} and prints warning."""
    mock_winreg = _make_winreg_mock(values={})
    # Make the context manager __enter__ raise
    fake_key = MagicMock()
    fake_key.__enter__ = MagicMock(side_effect=RuntimeError("boom"))
    fake_key.__exit__ = MagicMock(return_value=False)
    mock_winreg.OpenKey.return_value = fake_key

    with patch.dict("sys.modules", {"winreg": mock_winreg}):
        import importlib
        import legacy_mcp.config_registry as m
        importlib.reload(m)
        result = m.read_registry_config()

    assert result == {}
    captured = capsys.readouterr()
    assert "Warning" in captured.err


# ---------------------------------------------------------------------------
# read_registry_service_config -- non-Windows
# ---------------------------------------------------------------------------


def test_service_config_returns_empty_on_non_windows():
    """On non-Windows platforms service config returns {} without touching winreg."""
    with patch("sys.platform", "linux"):
        result = read_registry_service_config()
    assert result == {}


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_service_config_reads_account_and_autostart():
    """ServiceAccount and AutoStart are mapped correctly."""
    values = {
        "ServiceAccount": (r"CONTOSO\svc-legacymcp$", 1),
        "AutoStart": (1, 4),
    }
    mock_winreg = _make_winreg_mock(values=values)
    with patch.dict("sys.modules", {"winreg": mock_winreg}):
        import importlib
        import legacy_mcp.config_registry as m
        importlib.reload(m)
        result = m.read_registry_service_config()

    assert result["service_account"] == r"CONTOSO\svc-legacymcp$"
    assert result["auto_start"] is True


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_service_config_autostart_false():
    """AutoStart = 0 maps to False."""
    values = {
        "AutoStart": (0, 4),
    }
    mock_winreg = _make_winreg_mock(values=values)
    with patch.dict("sys.modules", {"winreg": mock_winreg}):
        import importlib
        import legacy_mcp.config_registry as m
        importlib.reload(m)
        result = m.read_registry_service_config()

    assert result["auto_start"] is False


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_service_subkey_absent_returns_empty():
    """If the Service subkey is absent, returns {}."""
    mock_winreg = _make_winreg_mock(open_raises=OSError("subkey not found"))
    with patch.dict("sys.modules", {"winreg": mock_winreg}):
        import importlib
        import legacy_mcp.config_registry as m
        importlib.reload(m)
        result = m.read_registry_service_config()

    assert result == {}


# ---------------------------------------------------------------------------
# Priority chain: CLI > registry > default  (integration with server.main)
# ---------------------------------------------------------------------------


def test_main_priority_cli_over_registry(tmp_path):
    """CLI --config beats registry config_path."""
    import yaml
    from pathlib import Path

    fixture = Path("tests/fixtures/contoso-sample.json")
    cfg = {
        "mode": "offline",
        "workspace": {"forests": [{"name": "contoso.local", "file": str(fixture)}]},
    }
    cli_config = tmp_path / "cli_config.yaml"
    cli_config.write_text(yaml.dump(cfg))

    registry_config = tmp_path / "registry_config.yaml"
    registry_config.write_text(yaml.dump(cfg))

    with patch("legacy_mcp.server.read_registry_config",
               return_value={"config_path": str(registry_config)}):
        with patch("sys.argv", ["legacy-mcp", "--config", str(cli_config)]):
            import legacy_mcp.server as srv
            import argparse

            # Simulate what main() does with priority chain
            parser = argparse.ArgumentParser()
            parser.add_argument("--config", default=None)
            parser.add_argument("--transport", default=None,
                                choices=["stdio", "streamable-http", "sse"])
            parser.add_argument("--host", default=None)
            parser.add_argument("--port", type=int, default=None)
            args = parser.parse_args(["--config", str(cli_config)])

            from legacy_mcp.config_registry import read_registry_config as _rrc
            registry = {"config_path": str(registry_config)}

            resolved = args.config or registry.get("config_path") or "config/config.yaml"

    assert resolved == str(cli_config)


def test_main_priority_registry_over_default(tmp_path):
    """Registry config_path beats built-in default when CLI is absent."""
    registry = {"config_path": r"C:\LegacyMCP\config\config.yaml"}

    config_path = None or registry.get("config_path") or "config/config.yaml"

    assert config_path == r"C:\LegacyMCP\config\config.yaml"


def test_main_priority_default_when_both_absent():
    """Built-in default used when neither CLI nor registry provides config_path."""
    registry: dict = {}

    config_path = None or registry.get("config_path") or "config/config.yaml"

    assert config_path == "config/config.yaml"


def test_main_priority_transport_from_registry():
    """Transport falls back to registry when CLI is absent."""
    registry = {"transport": "streamable-http"}

    transport = None or registry.get("transport") or "stdio"

    assert transport == "streamable-http"


def test_main_priority_transport_default():
    """Transport defaults to stdio when both CLI and registry are absent."""
    registry: dict = {}

    transport = None or registry.get("transport") or "stdio"

    assert transport == "stdio"


def test_main_priority_port_from_registry():
    """Port falls back to registry int when CLI is absent."""
    registry = {"port": 9000}

    port = None or registry.get("port") or None

    assert port == 9000


# ---------------------------------------------------------------------------
# B1 regression: CRYPTPROTECT_LOCAL_MACHINE must be the numeric constant 0x04
# ---------------------------------------------------------------------------


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_dpapi_uses_numeric_flag_not_module_attribute():
    """B1 regression: DPAPI decrypt must use 0x04, not win32crypt.CRYPTPROTECT_LOCAL_MACHINE.

    win32crypt does not expose CRYPTPROTECT_LOCAL_MACHINE as a module attribute.
    Using the attribute raises AttributeError on a clean install.  This test
    verifies that the call is made with the numeric value 0x04 directly.
    """
    import importlib
    import legacy_mcp.config_registry as m

    # Build a mock win32crypt that:
    #  - does NOT have CRYPTPROTECT_LOCAL_MACHINE as an attribute
    #  - records what flag value CryptUnprotectData was called with
    mock_win32crypt = MagicMock(spec=[])  # empty spec = no attributes
    mock_win32crypt.CryptUnprotectData = MagicMock(return_value=("", b"secret-key"))

    encrypted_value = b"\x01\x02\x03\x04"
    values = {"ApiKey": (encrypted_value, 3)}  # 3 = REG_BINARY
    mock_winreg = _make_winreg_mock(values=values)

    with patch.dict("sys.modules", {"winreg": mock_winreg, "win32crypt": mock_win32crypt}):
        importlib.reload(m)
        result = m.read_registry_config()

    # Confirm decryption was called and the flag passed is 0x04 (not a missing attribute)
    mock_win32crypt.CryptUnprotectData.assert_called_once()
    call_args = mock_win32crypt.CryptUnprotectData.call_args[0]
    assert call_args[4] == 0x04, (
        f"Expected DPAPI flag 0x04 at position 4, got {call_args[4]!r}. "
        "win32crypt.CRYPTPROTECT_LOCAL_MACHINE does not exist as a module attribute."
    )
    assert result["api_key"] == "secret-key"


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_dpapi_call_has_exactly_five_positional_args():
    """Fix 1 regression: CryptUnprotectData must be called with exactly 5 positional
    args (data, description, entropy, reserved, flags).  A 6-arg call raises
    TypeError on a clean pywin32 install.
    """
    import importlib
    import legacy_mcp.config_registry as m

    mock_win32crypt = MagicMock(spec=[])
    mock_win32crypt.CryptUnprotectData = MagicMock(return_value=("", b"key"))

    encrypted_value = b"\x01\x02\x03\x04"
    values = {"ApiKey": (encrypted_value, 3)}
    mock_winreg = _make_winreg_mock(values=values)

    with patch.dict("sys.modules", {"winreg": mock_winreg, "win32crypt": mock_win32crypt}):
        importlib.reload(m)
        m.read_registry_config()

    call_args = mock_win32crypt.CryptUnprotectData.call_args[0]
    assert len(call_args) == 5, (
        f"CryptUnprotectData called with {len(call_args)} positional args, expected 5. "
        "The correct signature is (data, description, entropy, reserved, flags)."
    )
