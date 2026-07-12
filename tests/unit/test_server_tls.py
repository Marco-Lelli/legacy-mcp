"""Tests for server.py TLS private key password support.

All registry access is mocked -- the real Windows registry is never touched.
Tests that exercise Windows-only code paths are skipped on non-Windows.
"""
from __future__ import annotations

import sys
from unittest.mock import MagicMock, patch

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_winreg_mock(blob: str | None = None, open_raises: OSError | None = None):
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
            if name == "KeyPasswordBlob" and blob is not None:
                return (blob, 1)
            raise OSError(f"value {name!r} not found")

        mock.QueryValueEx.side_effect = _query

    return mock


def _make_key_file_mock(line1: str, line2: str = "") -> MagicMock:
    mock_file = MagicMock()
    mock_file.__enter__ = lambda s: s
    mock_file.__exit__ = MagicMock(return_value=False)
    mock_file.readline.side_effect = [line1, line2]
    return mock_file


def _make_proc(returncode: int, stdout: str, stderr: str = "") -> MagicMock:
    proc = MagicMock()
    proc.returncode = returncode
    proc.stdout = stdout
    proc.stderr = stderr
    return proc


# ---------------------------------------------------------------------------
# _get_key_password -- non-Windows
# ---------------------------------------------------------------------------

def test_get_key_password_non_windows():
    """On non-Windows platforms returns None without touching winreg."""
    import legacy_mcp.server as srv
    with patch("sys.platform", "linux"):
        result = srv._get_key_password()
    assert result is None


# ---------------------------------------------------------------------------
# _get_key_password -- Windows paths (mocked)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _run_with_tls -- encrypted key detection (platform-independent)
# ---------------------------------------------------------------------------

def test_run_with_tls_pkcs1_encrypted_key_raises():
    """RuntimeError when PKCS#1 key has Proc-Type: 4,ENCRYPTED and no password."""
    import legacy_mcp.server as srv

    mock_key = _make_key_file_mock(
        "-----BEGIN RSA PRIVATE KEY-----\n",
        "Proc-Type: 4,ENCRYPTED\n",
    )
    with (
        patch.object(srv, "_get_key_password", return_value=None),
        patch("builtins.open", return_value=mock_key),
    ):
        with pytest.raises(RuntimeError, match="KeyPasswordBlob is missing"):
            srv._run_with_tls(MagicMock(), "cert.crt", "key.key")


def test_run_with_tls_pkcs8_encrypted_key_raises():
    """RuntimeError when PKCS#8 encrypted key header detected and no password."""
    import legacy_mcp.server as srv

    mock_key = _make_key_file_mock("-----BEGIN ENCRYPTED PRIVATE KEY-----\n")
    with (
        patch.object(srv, "_get_key_password", return_value=None),
        patch("builtins.open", return_value=mock_key),
    ):
        with pytest.raises(RuntimeError, match="KeyPasswordBlob is missing"):
            srv._run_with_tls(MagicMock(), "cert.crt", "key.key")


def test_run_with_tls_unreadable_key_raises():
    """RuntimeError when key file cannot be opened."""
    import legacy_mcp.server as srv

    with (
        patch.object(srv, "_get_key_password", return_value=None),
        patch("builtins.open", side_effect=OSError("permission denied")),
    ):
        with pytest.raises(RuntimeError, match="Cannot read TLS key file"):
            srv._run_with_tls(MagicMock(), "cert.crt", "key.key")


# ---------------------------------------------------------------------------
# _get_key_password -- Windows paths (mocked)
# ---------------------------------------------------------------------------

@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_get_key_password_absent_returns_none():
    """When registry key is absent, returns None."""
    import importlib
    import legacy_mcp.server as srv

    mock_winreg = _make_winreg_mock(open_raises=OSError("key not found"))
    with patch.dict("sys.modules", {"winreg": mock_winreg}):
        importlib.reload(srv)
        result = srv._get_key_password()

    assert result is None


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_get_key_password_blob_missing_returns_none():
    """When KeyPasswordBlob value is absent, returns None."""
    import importlib
    import legacy_mcp.server as srv

    mock_winreg = _make_winreg_mock(blob=None)
    with patch.dict("sys.modules", {"winreg": mock_winreg}):
        importlib.reload(srv)
        result = srv._get_key_password()

    assert result is None


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_get_key_password_empty_blob_returns_none():
    """When KeyPasswordBlob is an empty string in registry, returns None."""
    import importlib
    import legacy_mcp.server as srv

    mock_winreg = _make_winreg_mock(blob="")
    with patch.dict("sys.modules", {"winreg": mock_winreg}):
        importlib.reload(srv)
        result = srv._get_key_password()

    assert result is None


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_get_key_password_present_returns_bytes():
    """Successful decryption: subprocess returns plaintext, encoded to bytes."""
    import importlib
    import legacy_mcp.server as srv

    mock_winreg = _make_winreg_mock(blob="AQIDBAencryptedblob==")
    with patch.dict("sys.modules", {"winreg": mock_winreg}):
        importlib.reload(srv)
        with patch("subprocess.run", return_value=_make_proc(0, "my-key-password\n")):
            result = srv._get_key_password()

    assert result == b"my-key-password"


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_get_key_password_blob_passed_via_stdin_not_env():
    """SEC-L1: KeyPasswordBlob reaches PowerShell as subprocess stdin, and
    LEGACYMCP_BLOB is never present in os.environ -- not even while the
    subprocess is running."""
    import importlib
    import os
    import legacy_mcp.server as srv

    mock_winreg = _make_winreg_mock(blob="AQIDBAencryptedblob==")
    captured: dict = {}

    def _fake_run(*args, **kwargs):
        captured["cmd"] = args[0] if args else kwargs.get("args", [])
        captured["kwargs"] = kwargs
        captured["env_during_call"] = "LEGACYMCP_BLOB" in os.environ
        return _make_proc(0, "my-key-password\n")

    with patch.dict("sys.modules", {"winreg": mock_winreg}):
        importlib.reload(srv)
        with patch("subprocess.run", side_effect=_fake_run):
            result = srv._get_key_password()

    assert result == b"my-key-password"
    assert captured["kwargs"]["input"] == "AQIDBAencryptedblob=="
    assert captured["env_during_call"] is False
    assert "LEGACYMCP_BLOB" not in os.environ
    # The PS command must read from stdin, not from an environment variable.
    ps_cmd = " ".join(str(part) for part in captured["cmd"])
    assert "$env:LEGACYMCP_BLOB" not in ps_cmd
    assert "[Console]::In.ReadToEnd()" in ps_cmd


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_get_key_password_subprocess_fails_raises():
    """Non-zero returncode from PowerShell raises RuntimeError."""
    import importlib
    import legacy_mcp.server as srv

    mock_winreg = _make_winreg_mock(blob="AQIDBAencryptedblob==")
    with patch.dict("sys.modules", {"winreg": mock_winreg}):
        importlib.reload(srv)
        with patch("subprocess.run", return_value=_make_proc(1, "", "module not found")):
            with pytest.raises(RuntimeError, match="Failed to decrypt"):
                srv._get_key_password()


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_get_key_password_empty_stdout_raises():
    """Empty stdout with returncode 0 also raises RuntimeError."""
    import importlib
    import legacy_mcp.server as srv

    mock_winreg = _make_winreg_mock(blob="AQIDBAencryptedblob==")
    with patch.dict("sys.modules", {"winreg": mock_winreg}):
        importlib.reload(srv)
        with patch("subprocess.run", return_value=_make_proc(0, "")):
            with pytest.raises(RuntimeError, match="Failed to decrypt"):
                srv._get_key_password()


# ---------------------------------------------------------------------------
# SEC-H2: main() fail-safe on undecryptable ApiKey
# ---------------------------------------------------------------------------

def test_main_aborts_when_apikey_cannot_be_decrypted():
    """SEC-H2: if read_registry_config raises ApiKeyDecryptionError, main() must
    exit(1) and never start the server (fail-safe, not fail-open)."""
    import legacy_mcp.server as srv
    from legacy_mcp.config_registry import ApiKeyDecryptionError

    with (
        patch("sys.argv", ["legacy-mcp"]),
        patch.object(srv, "read_registry_config",
                     side_effect=ApiKeyDecryptionError("ApiKey present but undecryptable")),
        patch.object(srv, "create_server") as mock_create,
        patch.object(srv.eventlog, "error") as mock_err,
    ):
        with pytest.raises(SystemExit) as exc_info:
            srv.main()

    assert exc_info.value.code == 1
    mock_create.assert_not_called()          # server never built
    mock_err.assert_called_once()            # failure logged to EventLog
