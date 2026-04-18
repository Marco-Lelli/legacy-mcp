"""Windows registry configuration reader for LegacyMCP.

Reads HKLM\\SOFTWARE\\LegacyMCP\\ at server startup when no --config CLI
argument is provided.  On non-Windows platforms (or when the registry key is
absent) returns an empty dict so the caller falls back to the file-system
default without any error.

Priority applied by the caller: CLI > registry > default.
"""

from __future__ import annotations

import sys

_REGISTRY_KEY = r"SOFTWARE\LegacyMCP"
_SERVICE_SUBKEY = r"SOFTWARE\LegacyMCP\Service"


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
            try:
                encrypted_b64, _ = winreg.QueryValueEx(key, "ApiKey")
                if encrypted_b64:
                    import base64  # noqa: PLC0415
                    import dpapi_ng  # noqa: PLC0415
                    blob = base64.b64decode(encrypted_b64)
                    plaintext = dpapi_ng.ncrypt_unprotect_secret(blob)
                    result["api_key"] = plaintext.decode("utf-8")
            except OSError:
                pass  # key absent -- Profile A or not yet configured
            except ImportError:
                pass  # dpapi-ng not installed
            except Exception as exc:  # noqa: BLE001
                import sys as _sys
                print(
                    f"[LegacyMCP] Warning: failed to decrypt ApiKey: {exc}",
                    file=_sys.stderr,
                )

    except Exception as exc:  # noqa: BLE001
        import sys as _sys
        print(f"[LegacyMCP] Warning: failed to read registry: {exc}", file=_sys.stderr)
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
