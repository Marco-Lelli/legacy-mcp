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
