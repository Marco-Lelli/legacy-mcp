"""Configuration loading and validation."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import yaml


def load_config(path: str | Path) -> dict[str, Any]:
    """Load configuration from a YAML file.

    Environment variables override config values when prefixed with LEGACYMCP_.
    Example: LEGACYMCP_MODE=live overrides config['mode'].
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
    mode = config.get("mode")
    if mode not in ("live", "offline"):
        raise ValueError(f"Invalid mode '{mode}'. Must be 'live' or 'offline'.")

    if "workspace" not in config:
        raise ValueError("Config missing required 'workspace' section.")

    forests = config["workspace"].get("forests", [])
    if not forests:
        raise ValueError("Workspace must define at least one forest.")

    valid_modes = {"live", "offline"}
    for f in forests:
        forest_mode = f.get("mode")
        if forest_mode is not None and forest_mode not in valid_modes:
            raise ValueError(
                f"Forest '{f.get('name', '?')}': invalid mode '{forest_mode}'."
                " Must be 'live' or 'offline'."
            )

    server_cfg = config.get("server", {})
    ssl_certfile = server_cfg.get("ssl_certfile")
    ssl_keyfile = server_cfg.get("ssl_keyfile")
    if bool(ssl_certfile) != bool(ssl_keyfile):
        raise ValueError(
            "server.ssl_certfile and server.ssl_keyfile must both be set or both be absent."
        )
