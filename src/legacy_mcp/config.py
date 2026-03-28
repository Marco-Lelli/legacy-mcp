"""Configuration loading and validation."""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Any

import yaml

_logger = logging.getLogger(__name__)

# Profile -> (default_mode, allows_per_forest_override)
_VALID_PROFILES = {"A", "B-core", "B-enterprise", "C"}
_PROFILE_CONFIG: dict[str, tuple[str, bool]] = {
    "A":            ("offline", False),
    "B-core":       ("live",    True),
    "B-enterprise": ("live",    True),
    "C":            ("offline", False),
}


def load_config(path: str | Path) -> dict[str, Any]:
    """Load configuration from a YAML file.

    Environment variables override config values when prefixed with LEGACYMCP_.
    Example: LEGACYMCP_PROFILE=B-core overrides config['profile'].
    """
    config_path = Path(path)
    if not config_path.exists():
        raise FileNotFoundError(f"Config file not found: {config_path}")

    with config_path.open(encoding="utf-8") as fh:
        config = yaml.safe_load(fh) or {}

    _apply_env_overrides(config)
    _validate(config)
    return config


def _apply_env_overrides(config: dict[str, Any]) -> None:
    prefix = "LEGACYMCP_"
    for key, value in os.environ.items():
        if key.startswith(prefix):
            config_key = key[len(prefix):].lower()
            config[config_key] = value


def _validate(config: dict[str, Any]) -> None:
    profile = config.get("profile")
    mode = config.get("mode")

    if profile is not None:
        if profile not in _VALID_PROFILES:
            raise ValueError(
                f"Invalid profile '{profile}'."
                f" Must be one of: {', '.join(sorted(_VALID_PROFILES))}."
            )
        default_mode, allows_override = _PROFILE_CONFIG[profile]
        config["mode"] = default_mode
        profile_label: str | None = profile
    elif mode is not None:
        if mode not in ("live", "offline"):
            raise ValueError(f"Invalid mode '{mode}'. Must be 'live' or 'offline'.")
        _logger.warning(
            "Deprecated: global 'mode' field. Use 'profile' instead."
        )
        allows_override = True  # legacy behaviour: no override restriction
        profile_label = None
    else:
        # Neither profile nor mode: default to Profile A
        config["profile"] = "A"
        config["mode"] = "offline"
        allows_override = False
        profile_label = "A"

    if "workspace" not in config:
        raise ValueError("Config missing required 'workspace' section.")

    forests = config["workspace"].get("forests", [])
    if not forests:
        raise ValueError("Workspace must define at least one forest.")

    valid_modes = {"live", "offline"}
    for f in forests:
        forest_mode = f.get("mode")
        if forest_mode is not None:
            if forest_mode not in valid_modes:
                raise ValueError(
                    f"Forest '{f.get('name', '?')}': invalid mode '{forest_mode}'."
                    " Must be 'live' or 'offline'."
                )
            if not allows_override:
                raise ValueError(
                    f"Forest '{f.get('name', '?')}': mode override is not allowed"
                    f" in profile '{profile_label}'."
                )

    server_cfg = config.get("server", {})
    ssl_certfile = server_cfg.get("ssl_certfile")
    ssl_keyfile = server_cfg.get("ssl_keyfile")
    if bool(ssl_certfile) != bool(ssl_keyfile):
        raise ValueError(
            "server.ssl_certfile and server.ssl_keyfile must both be set or both be absent."
        )
