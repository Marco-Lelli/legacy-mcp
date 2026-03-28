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
# Deployment profile tests
# ---------------------------------------------------------------------------


def test_profile_A_loads(tmp_path: Path) -> None:
    """Profile A loads and sets effective mode to offline."""
    cfg = {
        "profile": "A",
        "workspace": {
            "forests": [{"name": "contoso.local", "file": "data/contoso.json"}]
        },
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    config = load_config(p)
    assert config["profile"] == "A"
    assert config["mode"] == "offline"


def test_profile_A_live_forest_raises(tmp_path: Path) -> None:
    """Profile A does not allow per-forest mode override."""
    cfg = {
        "profile": "A",
        "workspace": {
            "forests": [{"name": "live-forest", "mode": "live", "dc": "dc01.contoso.local"}]
        },
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    with pytest.raises(ValueError, match="mode override is not allowed"):
        load_config(p)


def test_profile_C_live_forest_raises(tmp_path: Path) -> None:
    """Profile C does not allow per-forest mode override."""
    cfg = {
        "profile": "C",
        "workspace": {
            "forests": [{"name": "live-forest", "mode": "live", "dc": "dc01.contoso.local"}]
        },
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    with pytest.raises(ValueError, match="mode override is not allowed"):
        load_config(p)


def test_profile_Bcore_offline_forest_ok(tmp_path: Path) -> None:
    """Profile B-core allows per-forest mode override to offline."""
    cfg = {
        "profile": "B-core",
        "workspace": {
            "forests": [
                {"name": "live-forest", "dc": "dc01.contoso.local"},
                {"name": "offline-forest", "mode": "offline", "file": "data/offline.json"},
            ]
        },
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    config = load_config(p)
    assert config["profile"] == "B-core"
    assert config["mode"] == "live"
    assert config["workspace"]["forests"][1]["mode"] == "offline"


def test_profile_invalid_raises(tmp_path: Path) -> None:
    """Invalid profile value raises ValueError."""
    cfg = {
        "profile": "X",
        "workspace": {
            "forests": [{"name": "contoso.local", "file": "data/contoso.json"}]
        },
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    with pytest.raises(ValueError, match="Invalid profile"):
        load_config(p)


def test_server_snapshot_path_parsed(tmp_path: Path) -> None:
    """snapshot_path in server: block is accessible in the loaded config."""
    cfg = {
        "profile": "A",
        "workspace": {
            "forests": [{"name": "contoso.local", "file": "data/contoso.json"}]
        },
        "server": {"snapshot_path": r"C:\LegacyMCP-Data\snapshots"},
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    config = load_config(p)
    assert config["server"]["snapshot_path"] == r"C:\LegacyMCP-Data\snapshots"


def test_retrocompat_mode_field_warns(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    """Legacy 'mode' field without 'profile' loads with a deprecation warning."""
    import logging
    cfg = {
        "mode": "offline",
        "workspace": {
            "forests": [{"name": "contoso.local", "file": "data/contoso.json"}]
        },
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    with caplog.at_level(logging.WARNING, logger="legacy_mcp.config"):
        config = load_config(p)
    assert config["mode"] == "offline"
    assert "Deprecated" in caplog.text


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


# ---------------------------------------------------------------------------
# Per-forest mode override tests
# ---------------------------------------------------------------------------


def test_mixed_mode_config_valid(tmp_path: Path) -> None:
    """Global offline + one forest with mode: live passes config validation."""
    cfg = {
        "mode": "offline",
        "workspace": {
            "forests": [
                {"name": "offline-forest", "file": "data/offline.json"},
                {"name": "live-forest", "mode": "live", "dc": "dc01.live.local"},
            ]
        },
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    config = load_config(p)
    forests = config["workspace"]["forests"]
    assert forests[0].get("mode") is None
    assert forests[1]["mode"] == "live"


def test_forest_invalid_mode_raises(tmp_path: Path) -> None:
    """Per-forest mode with an invalid value raises ValueError."""
    cfg = {
        "mode": "offline",
        "workspace": {
            "forests": [
                {"name": "bad-forest", "mode": "hybrid", "file": "data/x.json"},
            ]
        },
    }
    p = tmp_path / "config.yaml"
    p.write_text(yaml.dump(cfg))
    with pytest.raises(ValueError, match="invalid mode"):
        load_config(p)


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
