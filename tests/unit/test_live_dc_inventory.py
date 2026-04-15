"""Unit tests for LiveConnector.enumerate_dcs() and collect_dc_inventory()."""

from __future__ import annotations

from unittest.mock import patch

import pytest

from legacy_mcp.modes.live import LiveConnector
from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation


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
            with patch.object(connector, "run_ps_on", side_effect=_run_ps_on):
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
            with patch.object(connector, "run_ps_on", side_effect=_run_ps_on):
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
            with patch.object(connector, "run_ps_on", return_value=[dc_row]):
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
            with patch.object(connector, "run_ps_on", return_value=[]):
                result = connector.collect_dc_inventory("dc_services")

        warning = next(r for r in result if "warning" in r)
        assert "Forest contains" in warning["warning"]

    def test_unreachable_fallback_fields_match_section_services(
        self, connector: LiveConnector
    ) -> None:
        dcs = ["dc01.contoso.local"]

        with patch.object(connector, "enumerate_dcs", return_value=dcs):
            with patch.object(
                connector, "run_ps_on", side_effect=RuntimeError("timeout")
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
                connector, "run_ps_on", side_effect=RuntimeError("timeout")
            ):
                result = connector.collect_dc_inventory("dc_installed_software")

        assert result[0]["Status"] == "Unreachable"
        assert result[0]["Software"] == []
        assert "Features" not in result[0]
