"""Unit tests for config loading and validation."""

import pytest
import yaml
from pathlib import Path

from legacy_mcp.config import load_config


@pytest.fixture
def valid_offline_config(tmp_path: Path) -> Path:
    cfg = {
        "mode": "offline",
        "workspace": {
            "forests": [{"name": "contoso.local", "file": "data/contoso.json"}]
        },
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    return p


def test_load_valid_config(valid_offline_config: Path) -> None:
    config = load_config(valid_offline_config)
    assert config["mode"] == "offline"
    assert len(config["workspace"]["forests"]) == 1


def test_missing_file_raises() -> None:
    with pytest.raises(FileNotFoundError):
        load_config("nonexistent.yaml")


def test_invalid_mode_raises(tmp_path: Path) -> None:
    cfg = {"mode": "invalid", "workspace": {"forests": [{"name": "x"}]}}
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    with pytest.raises(ValueError, match="Invalid mode"):
        load_config(p)


def test_missing_workspace_raises(tmp_path: Path) -> None:
    cfg = {"mode": "offline"}
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    with pytest.raises(ValueError, match="workspace"):
        load_config(p)
