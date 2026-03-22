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


def test_server_block_parsed(tmp_path: Path) -> None:
    cfg = {
        "mode": "offline",
        "workspace": {
            "forests": [{"name": "contoso.local", "file": "data/contoso.json"}]
        },
        "server": {"host": "0.0.0.0", "port": 8080},
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    config = load_config(p)
    assert config["server"]["host"] == "0.0.0.0"
    assert config["server"]["port"] == 8080


def test_server_block_optional(tmp_path: Path, valid_offline_config: Path) -> None:
    """Config without a server: block loads without error."""
    config = load_config(valid_offline_config)
    assert config.get("server") is None


def test_create_server_host_port_from_config(tmp_path: Path) -> None:
    """create_server passes host/port from config file to FastMCP."""
    from legacy_mcp.server import create_server

    fixture = Path("tests/fixtures/contoso-sample.json")
    cfg = {
        "mode": "offline",
        "workspace": {
            "forests": [{"name": "contoso.local", "file": str(fixture)}]
        },
        "server": {"host": "0.0.0.0", "port": 9000},
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    mcp = create_server(p)
    assert mcp.settings.host == "0.0.0.0"
    assert mcp.settings.port == 9000


def test_create_server_cli_overrides_config(tmp_path: Path) -> None:
    """CLI host/port arguments override the config file values."""
    from legacy_mcp.server import create_server

    fixture = Path("tests/fixtures/contoso-sample.json")
    cfg = {
        "mode": "offline",
        "workspace": {
            "forests": [{"name": "contoso.local", "file": str(fixture)}]
        },
        "server": {"host": "0.0.0.0", "port": 9000},
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    mcp = create_server(p, host="192.168.1.10", port=8443)
    assert mcp.settings.host == "192.168.1.10"
    assert mcp.settings.port == 8443


def test_create_server_defaults_without_server_block(tmp_path: Path) -> None:
    """Without a server: block, FastMCP built-in defaults are used."""
    from legacy_mcp.server import create_server

    fixture = Path("tests/fixtures/contoso-sample.json")
    cfg = {
        "mode": "offline",
        "workspace": {
            "forests": [{"name": "contoso.local", "file": str(fixture)}]
        },
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    mcp = create_server(p)
    assert mcp.settings.host == "127.0.0.1"
    assert mcp.settings.port == 8000


# ---------------------------------------------------------------------------
# TLS / SSL config tests
# ---------------------------------------------------------------------------


def test_ssl_both_fields_accepted(tmp_path: Path) -> None:
    """Config with both ssl_certfile and ssl_keyfile loads without error."""
    cfg = {
        "mode": "offline",
        "workspace": {
            "forests": [{"name": "contoso.local", "file": "data/contoso.json"}]
        },
        "server": {
            "host": "0.0.0.0",
            "port": 8443,
            "ssl_certfile": "certs/server.crt",
            "ssl_keyfile": "certs/server.key",
        },
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    config = load_config(p)
    assert config["server"]["ssl_certfile"] == "certs/server.crt"
    assert config["server"]["ssl_keyfile"] == "certs/server.key"


def test_ssl_only_certfile_raises(tmp_path: Path) -> None:
    """Providing ssl_certfile without ssl_keyfile raises ValueError."""
    cfg = {
        "mode": "offline",
        "workspace": {
            "forests": [{"name": "contoso.local", "file": "data/contoso.json"}]
        },
        "server": {"ssl_certfile": "certs/server.crt"},
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    with pytest.raises(ValueError, match="ssl_certfile and server.ssl_keyfile"):
        load_config(p)


def test_ssl_only_keyfile_raises(tmp_path: Path) -> None:
    """Providing ssl_keyfile without ssl_certfile raises ValueError."""
    cfg = {
        "mode": "offline",
        "workspace": {
            "forests": [{"name": "contoso.local", "file": "data/contoso.json"}]
        },
        "server": {"ssl_keyfile": "certs/server.key"},
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    with pytest.raises(ValueError, match="ssl_certfile and server.ssl_keyfile"):
        load_config(p)


def test_ssl_absent_no_error(tmp_path: Path, valid_offline_config: Path) -> None:
    """Config without any SSL fields loads cleanly."""
    config = load_config(valid_offline_config)
    server_cfg = config.get("server", {})
    assert server_cfg.get("ssl_certfile") is None
    assert server_cfg.get("ssl_keyfile") is None


def test_create_server_tls_attached(tmp_path: Path) -> None:
    """create_server attaches resolved TLS paths to mcp._tls_certfile/keyfile."""
    from legacy_mcp.server import create_server

    fixture = Path("tests/fixtures/contoso-sample.json")
    cfg = {
        "mode": "offline",
        "workspace": {
            "forests": [{"name": "contoso.local", "file": str(fixture)}]
        },
        "server": {
            "ssl_certfile": "certs/server.crt",
            "ssl_keyfile": "certs/server.key",
        },
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    mcp = create_server(p)
    assert mcp._tls_certfile == "certs/server.crt"
    assert mcp._tls_keyfile == "certs/server.key"


def test_create_server_no_tls_attributes_are_none(tmp_path: Path) -> None:
    """Without ssl config, _tls_certfile and _tls_keyfile are None."""
    from legacy_mcp.server import create_server

    fixture = Path("tests/fixtures/contoso-sample.json")
    cfg = {
        "mode": "offline",
        "workspace": {
            "forests": [{"name": "contoso.local", "file": str(fixture)}]
        },
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    mcp = create_server(p)
    assert mcp._tls_certfile is None
    assert mcp._tls_keyfile is None
