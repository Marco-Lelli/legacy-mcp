"""Unit tests for LiveConnector.enumerate_dcs() and collect_dc_inventory()."""

from __future__ import annotations

import json
import subprocess
from unittest.mock import MagicMock, patch

import pytest

from legacy_mcp.modes.live import LiveConnector
from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, Workspace


@pytest.fixture
def forest() -> ForestConfig:
    return ForestConfig(
        name="contoso.local",
        relation=ForestRelation.STANDALONE,
        dc="dc01.contoso.local",
    )


@pytest.fixture
def connector(forest: ForestConfig) -> LiveConnector:
    return LiveConnector(forest)


# ---------------------------------------------------------------------------
# enumerate_dcs
# ---------------------------------------------------------------------------

class TestEnumerateDcs:

    def test_single_dc_forest_string_wrapped_in_list(
        self, connector: LiveConnector
    ) -> None:
        # PS returns a bare string (not an array) when only one DC exists.
        with patch.object(connector, "run_ps", return_value="dc01.contoso.local"):
            result = connector.enumerate_dcs()
        assert result == ["dc01.contoso.local"]

    def test_multi_dc_forest_list_returned_as_is(
        self, connector: LiveConnector
    ) -> None:
        dcs = ["dc01.contoso.local", "dc02.contoso.local", "dc03.contoso.local"]
        with patch.object(connector, "run_ps", return_value=dcs):
            result = connector.enumerate_dcs()
        assert result == dcs

    def test_exception_falls_back_to_entry_point_dc(
        self, connector: LiveConnector
    ) -> None:
        with patch.object(
            connector, "run_ps", side_effect=RuntimeError("WinRM error")
        ):
            result = connector.enumerate_dcs()
        assert result == ["dc01.contoso.local"]


# ---------------------------------------------------------------------------
# collect_dc_inventory
# ---------------------------------------------------------------------------

class TestCollectDcInventory:

    def test_all_dcs_reachable_returns_full_result(
        self, connector: LiveConnector
    ) -> None:
        dcs = ["dc01.contoso.local", "dc02.contoso.local"]
        dc1_row = {
            "DC": "dc01.contoso.local",
            "Status": "OK",
            "Features": [{"name": "AD-Domain-Services", "display_name": "AD DS"}],
        }
        dc2_row = {"DC": "dc02.contoso.local", "Status": "OK", "Features": []}

        def _run_ps_on(dc_fqdn: str, script: str):
            return [dc1_row] if dc_fqdn == "dc01.contoso.local" else [dc2_row]

        with patch.object(connector, "enumerate_dcs", return_value=dcs):
            with patch.object(connector, "_run_ps_on", side_effect=_run_ps_on):
                result = connector.collect_dc_inventory("dc_windows_features")

        assert len(result) == 2
        assert result[0]["DC"] == "dc01.contoso.local"
        assert result[1]["DC"] == "dc02.contoso.local"
        assert not any("warning" in r for r in result)

    def test_one_dc_unreachable_produces_fallback_entry(
        self, connector: LiveConnector
    ) -> None:
        dcs = ["dc01.contoso.local", "dc02.contoso.local"]
        dc1_row = {"DC": "dc01.contoso.local", "Status": "OK", "Features": []}

        def _run_ps_on(dc_fqdn: str, script: str):
            if dc_fqdn == "dc01.contoso.local":
                return [dc1_row]
            raise RuntimeError("Connection refused")

        with patch.object(connector, "enumerate_dcs", return_value=dcs):
            with patch.object(connector, "_run_ps_on", side_effect=_run_ps_on):
                result = connector.collect_dc_inventory("dc_windows_features")

        assert len(result) == 2
        dc2_result = next(r for r in result if r.get("DC") == "dc02.contoso.local")
        assert dc2_result["Status"] == "Unreachable"
        assert dc2_result["Features"] == []

    def test_more_than_10_dcs_prepends_warning_entry(
        self, connector: LiveConnector
    ) -> None:
        dcs = [f"dc{i:02d}.contoso.local" for i in range(1, 12)]  # 11 DCs
        dc_row = {"DC": "dc01.contoso.local", "Status": "OK", "Features": []}

        with patch.object(connector, "enumerate_dcs", return_value=dcs):
            with patch.object(connector, "_run_ps_on", return_value=[dc_row]):
                result = connector.collect_dc_inventory("dc_windows_features")

        warning_entries = [r for r in result if "warning" in r]
        assert len(warning_entries) == 1
        assert "11" in warning_entries[0]["warning"]
        # 11 DC rows + 1 warning entry
        assert len(result) == 12

    def test_warning_mentions_forest_contains(
        self, connector: LiveConnector
    ) -> None:
        dcs = [f"dc{i:02d}.contoso.local" for i in range(1, 12)]

        with patch.object(connector, "enumerate_dcs", return_value=dcs):
            with patch.object(connector, "_run_ps_on", return_value=[]):
                result = connector.collect_dc_inventory("dc_services")

        warning = next(r for r in result if "warning" in r)
        assert "Forest contains" in warning["warning"]

    def test_unreachable_fallback_fields_match_section_services(
        self, connector: LiveConnector
    ) -> None:
        dcs = ["dc01.contoso.local"]

        with patch.object(connector, "enumerate_dcs", return_value=dcs):
            with patch.object(
                connector, "_run_ps_on", side_effect=RuntimeError("timeout")
            ):
                result = connector.collect_dc_inventory("dc_services")

        assert result[0]["Status"] == "Unreachable"
        assert result[0]["Services"] == []
        assert "Features" not in result[0]

    def test_unreachable_fallback_fields_match_section_software(
        self, connector: LiveConnector
    ) -> None:
        dcs = ["dc01.contoso.local"]

        with patch.object(connector, "enumerate_dcs", return_value=dcs):
            with patch.object(
                connector, "_run_ps_on", side_effect=RuntimeError("timeout")
            ):
                result = connector.collect_dc_inventory("dc_installed_software")

        assert result[0]["Status"] == "Unreachable"
        assert result[0]["Software"] == []
        assert "Features" not in result[0]


# ---------------------------------------------------------------------------
# credentials propagation through Workspace.from_config()
# ---------------------------------------------------------------------------

class TestCredentialsPropagation:

    def test_credentials_gmsa_propagated_from_config(self) -> None:
        cfg = {
            "mode": "live",
            "workspace": {
                "forests": [
                    {"name": "house.local", "dc": "dc01.house.local", "credentials": "gmsa"}
                ]
            },
        }
        workspace = Workspace.from_config(cfg)
        assert workspace.forests[0].credentials == "gmsa"

    def test_credentials_default_is_gmsa_when_omitted(self) -> None:
        cfg = {
            "mode": "live",
            "workspace": {
                "forests": [{"name": "house.local", "dc": "dc01.house.local"}]
            },
        }
        workspace = Workspace.from_config(cfg)
        assert workspace.forests[0].credentials == "gmsa"

    def test_credentials_env_propagated_from_config(self) -> None:
        cfg = {
            "mode": "live",
            "workspace": {
                "forests": [
                    {"name": "house.local", "dc": "dc01.house.local", "credentials": "env"}
                ]
            },
        }
        workspace = Workspace.from_config(cfg)
        assert workspace.forests[0].credentials == "env"


# ---------------------------------------------------------------------------
# _run_ps_on — subprocess execution
# ---------------------------------------------------------------------------

class TestRunPsOn:

    def test_valid_json_list_returned(self, connector: LiveConnector) -> None:
        expected = [{"Name": "dc01", "Site": "Default"}]
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=0,
                stdout=json.dumps(expected).encode(),
                stderr=b"",
            )
            result = connector._run_ps_on("dc01.contoso.local", "Get-ADDomain | ConvertTo-Json")
        assert result == expected

    def test_nonzero_returncode_raises_runtime_error(self, connector: LiveConnector) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=1,
                stdout=b"",
                stderr=b"Access is denied.",
            )
            with pytest.raises(RuntimeError, match="PowerShell error"):
                connector._run_ps_on("dc01.contoso.local", "some script")

    def test_empty_stdout_returns_empty_list(self, connector: LiveConnector) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=0,
                stdout=b"",
                stderr=b"",
            )
            result = connector._run_ps_on("dc01.contoso.local", "some script")
        assert result == []

    def test_null_stdout_returns_empty_list(self, connector: LiveConnector) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=0,
                stdout=b"null",
                stderr=b"",
            )
            result = connector._run_ps_on("dc01.contoso.local", "some script")
        assert result == []

    def test_timeout_raises_runtime_error(self, connector: LiveConnector) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.side_effect = subprocess.TimeoutExpired(
                cmd=["powershell.exe"], timeout=30
            )
            with pytest.raises(RuntimeError, match="timeout"):
                connector._run_ps_on("dc01.contoso.local", "some script")

    def test_stderr_included_in_error_message(self, connector: LiveConnector) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=1,
                stdout=b"",
                stderr=b"Cannot find module ServerManager.",
            )
            with pytest.raises(RuntimeError, match="Cannot find module ServerManager"):
                connector._run_ps_on("dc01.contoso.local", "some script")


# ---------------------------------------------------------------------------
# run_ps — entry-point DC delegation
# ---------------------------------------------------------------------------

class TestRunPs:

    def test_delegates_to_run_ps_on_with_entry_point_dc(
        self, connector: LiveConnector
    ) -> None:
        with patch.object(connector, "_run_ps_on", return_value=[{"x": 1}]) as mock:
            result = connector.run_ps("Get-ADForest | ConvertTo-Json")
        mock.assert_called_once_with("dc01.contoso.local", "Get-ADForest | ConvertTo-Json")
        assert result == [{"x": 1}]
