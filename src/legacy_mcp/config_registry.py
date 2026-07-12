"""Windows registry configuration reader for LegacyMCP.

Reads HKLM\\SOFTWARE\\LegacyMCP\\ at server startup when no --config CLI
argument is provided.  On non-Windows platforms (or when the registry key is
absent) returns an empty dict so the caller falls back to the file-system
default without any error.

Priority applied by the caller: CLI > registry > default.
"""

from __future__ import annotations

import subprocess
import sys

_PS_EXE = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

_REGISTRY_KEY = r"SOFTWARE\LegacyMCP"
_SERVICE_SUBKEY = r"SOFTWARE\LegacyMCP\Service"


class ApiKeyDecryptionError(RuntimeError):
    """Raised when ApiKey is present in the registry but cannot be decrypted.

    SEC-H2 fix: fail-safe. When an ApiKey value exists in the registry (i.e. a
    Profile B server was configured with authentication) but DPAPI-NG decryption
    fails for any reason, the server must refuse to start rather than silently
    fall back to running without authentication. This mirrors the explicit
    RuntimeError raised for an undecryptable TLS key in server._run_with_tls().
    """


def read_registry_config() -> dict:
    """Read HKLM\\SOFTWARE\\LegacyMCP\\ and return a normalised config dict.

    Keys returned (all lowercase, only when present in the registry):
      config_path   - absolute path to config.yaml
      profile       - A | B-core | B-enterprise | C
      transport     - stdio | streamable-http
      port          - int
      log_path      - absolute path to log directory
      install_path  - absolute path to install directory
      api_key       - decrypted API key string (Profile B only)

    Returns {} if:
      - not running on Windows
      - the registry key does not exist (informal / development install)
      - winreg raises an unexpected error (logged to stderr, never fatal)
    """
    if sys.platform != "win32":
        return {}

    try:
        import winreg  # noqa: PLC0415 -- stdlib, Windows only
    except ImportError:
        return {}

    result: dict = {}

    try:
        key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, _REGISTRY_KEY)
    except OSError:
        # Key absent -- not formally installed, use defaults.
        return {}

    _STRING_FIELDS = {
        "ConfigPath": "config_path",
        "Profile": "profile",
        "Transport": "transport",
        "LogPath": "log_path",
        "InstallPath": "install_path",
        "Version": "version",
    }
    _DWORD_FIELDS = {
        "Port": "port",
    }

    try:
        with key:
            for reg_name, dict_key in _STRING_FIELDS.items():
                try:
                    value, _ = winreg.QueryValueEx(key, reg_name)
                    if value:
                        result[dict_key] = value
                except OSError:
                    pass

            for reg_name, dict_key in _DWORD_FIELDS.items():
                try:
                    value, _ = winreg.QueryValueEx(key, reg_name)
                    result[dict_key] = int(value)
                except (OSError, ValueError):
                    pass

            # ApiKey is stored as REG_SZ: a Base64 string produced by
            # ConvertTo-DpapiNGSecret (SecretManagement.DpapiNG) in
            # Install-LegacyMCP.ps1. The secret is SID-scoped to the
            # service account -- only that identity can decrypt it.
            # Decryption via PowerShell subprocess: NCryptUnprotectSecret works
            # for any SID-authorised account; the dpapi_ng Python library fails
            # with 0x80070005 because MS-GKDI root key retrieval requires DC RPC.
            try:
                encrypted_b64, _ = winreg.QueryValueEx(key, "ApiKey")
            except OSError:
                encrypted_b64 = None  # key absent -- Profile A or not yet configured

            if encrypted_b64:
                # SEC-H2 fix: an ApiKey is configured, so decryption failure must
                # be fatal (fail-safe), not a silent fall-through to no-auth.
                # SEC-L1: the blob is passed to PowerShell via stdin, never via
                # an environment variable, so it is not visible to child
                # processes or environment enumeration.
                decryption_error: str | None = None
                api_key = ""
                ps_cmd = (
                    "Import-Module SecretManagement.DpapiNG -ErrorAction Stop; "
                    "$blob = [Console]::In.ReadToEnd().Trim(); "
                    "$secure = ConvertFrom-DpapiNGSecret -InputObject $blob; "
                    "[Runtime.InteropServices.Marshal]::PtrToStringAuto("
                    "[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))"
                )
                try:
                    proc = subprocess.run(
                        [_PS_EXE, "-NoProfile", "-NonInteractive",
                         "-ExecutionPolicy", "Bypass", "-Command", ps_cmd],
                        input=encrypted_b64.encode("utf-8"),
                        capture_output=True,
                        timeout=10,
                        check=False,
                    )
                    api_key = proc.stdout.decode("utf-8", errors="replace").strip()
                    if proc.returncode != 0:
                        decryption_error = (
                            "SecretManagement.DpapiNG module not available"
                        )
                    elif not api_key:
                        decryption_error = "decryption returned empty result"
                except FileNotFoundError:
                    decryption_error = "powershell.exe not found at expected path"
                except subprocess.TimeoutExpired:
                    decryption_error = "decryption timed out after 10s"
                except Exception as exc:  # noqa: BLE001
                    decryption_error = f"{type(exc).__name__}: {exc}"

                if decryption_error is not None:
                    raise ApiKeyDecryptionError(
                        f"DPAPI-NG: ApiKey is present in the registry but could "
                        f"not be decrypted: {decryption_error}"
                    )
                result["api_key"] = api_key

    except ApiKeyDecryptionError:
        raise  # fail-safe: propagate to main() so the server refuses to start
    except Exception as exc:  # noqa: BLE001
        print(f"[LegacyMCP] Warning: failed to read registry: {exc}", file=sys.stderr)
        return {}

    return result


def read_registry_service_config() -> dict:
    """Read HKLM\\SOFTWARE\\LegacyMCP\\Service\\ and return a dict.

    Keys returned (lowercase):
      service_account  - account or gMSA running the Windows service
      auto_start       - bool

    Returns {} under the same conditions as read_registry_config().
    """
    if sys.platform != "win32":
        return {}

    try:
        import winreg  # noqa: PLC0415
    except ImportError:
        return {}

    result: dict = {}

    try:
        key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, _SERVICE_SUBKEY)
    except OSError:
        return {}

    try:
        with key:
            try:
                value, _ = winreg.QueryValueEx(key, "ServiceAccount")
                if value:
                    result["service_account"] = value
            except OSError:
                pass

            try:
                value, _ = winreg.QueryValueEx(key, "AutoStart")
                result["auto_start"] = bool(int(value))
            except (OSError, ValueError):
                pass
    except Exception as exc:  # noqa: BLE001
        import sys as _sys
        print(f"[LegacyMCP] Warning: failed to read Service registry: {exc}", file=_sys.stderr)
        return {}

    return result
