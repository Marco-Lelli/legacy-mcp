"""Unit tests for LiveConnector.enumerate_dcs() and collect_dc_inventory().

Mocks for _run_ps_on/run_ps/run_ps_local now use realistic CLIXML for stderr
(task #141, Fase 2) instead of b"" or plain text -- the gap flagged in
Fase 1's analysis: the pre-#141 mocks did not reflect what powershell.exe
-EncodedCommand actually produces on stderr, so they never exercised the
real CLIXML shape at all. _clixml_bytes() below builds a stderr blob in that
real shape, verified against actual powershell.exe output during Fase 1.
"""

from __future__ import annotations

import json
import subprocess
from unittest.mock import MagicMock, patch

import pytest

from legacy_mcp.modes.live import LiveConnector, _validate_dc_fqdn
from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, Workspace


def _clixml_bytes(*, warnings: list[str] | None = None, errors: list[str] | None = None) -> bytes:
    """Build a realistic CLIXML stderr blob, matching the shape
    powershell.exe -EncodedCommand actually produces (task #141)."""
    parts = [
        "#< CLIXML",
        '<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04">',
        '<Obj S="progress" RefId="0"><TN RefId="0"><T>System.Management.Automation.PSCustomObject</T>'
        "<T>System.Object</T></TN><MS><I64 N=\"SourceId\">1</I64><PR N=\"Record\">"
        '<AV>Preparing modules for first use.</AV><AI>0</AI><Nil /><PI>-1</PI><PC>-1</PC>'
        '<T>Completed</T><SR>-1</SR><SD> </SD></PR></MS></Obj>',
    ]
    for w in warnings or []:
        parts.append(f'<S S="warning">{w}</S>')
    for e in errors or []:
        parts.append(f'<S S="Error">{e}_x000D__x000A_</S>')
    parts.append("</Objs>")
    return "\n".join(parts).encode("utf-8")


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
        # run_ps() now returns (rows, warnings) -- task #141.
        with patch.object(connector, "run_ps", return_value=("dc01.contoso.local", [])):
            result = connector.enumerate_dcs()
        assert result == ["dc01.contoso.local"]

    def test_multi_dc_forest_list_returned_as_is(
        self, connector: LiveConnector
    ) -> None:
        dcs = ["dc01.contoso.local", "dc02.contoso.local", "dc03.contoso.local"]
        with patch.object(connector, "run_ps", return_value=(dcs, [])):
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

        # (rows, warnings) tuple and **kwargs to accept section= -- task #141.
        # A signature mismatch here would raise TypeError inside the try/except
        # in collect_dc_inventory() and silently exercise the "unreachable"
        # fallback path instead of this test's intended success path, without
        # the test itself failing (found exactly this happening while fixing
        # this file -- these mocks previously accepted only (dc_fqdn, script)).
        def _run_ps_on(dc_fqdn: str, script: str, **kwargs):
            row = dc1_row if dc_fqdn == "dc01.contoso.local" else dc2_row
            return [row], []

        with patch.object(connector, "enumerate_dcs", return_value=dcs):
            with patch.object(connector, "_run_ps_on", side_effect=_run_ps_on):
                result = connector.collect_dc_inventory("dc_windows_features")

        assert len(result) == 2
        assert result[0]["DC"] == "dc01.contoso.local"
        assert result[0]["Status"] == "OK"
        # Real content check, not just presence -- confirms this actually
        # took the success path and not a same-shaped fallback.
        assert result[0]["Features"] == [{"name": "AD-Domain-Services", "display_name": "AD DS"}]
        assert result[1]["DC"] == "dc02.contoso.local"
        assert result[1]["Status"] == "OK"
        assert not any("warning" in r for r in result)

    def test_one_dc_unreachable_produces_fallback_entry(
        self, connector: LiveConnector
    ) -> None:
        dcs = ["dc01.contoso.local", "dc02.contoso.local"]
        dc1_row = {"DC": "dc01.contoso.local", "Status": "OK", "Features": []}

        def _run_ps_on(dc_fqdn: str, script: str, **kwargs):
            if dc_fqdn == "dc01.contoso.local":
                return [dc1_row], []
            raise RuntimeError("Connection refused")

        with patch.object(connector, "enumerate_dcs", return_value=dcs):
            with patch.object(connector, "_run_ps_on", side_effect=_run_ps_on):
                result = connector.collect_dc_inventory("dc_windows_features")

        assert len(result) == 2
        dc1_result = next(r for r in result if r.get("DC") == "dc01.contoso.local")
        assert dc1_result["Status"] == "OK"
        dc2_result = next(r for r in result if r.get("DC") == "dc02.contoso.local")
        assert dc2_result["Status"] == "Unreachable"
        assert dc2_result["Features"] == []

    def test_more_than_10_dcs_prepends_warning_entry(
        self, connector: LiveConnector
    ) -> None:
        dcs = [f"dc{i:02d}.contoso.local" for i in range(1, 12)]  # 11 DCs
        dc_row = {"DC": "dc01.contoso.local", "Status": "OK", "Features": []}

        with patch.object(connector, "enumerate_dcs", return_value=dcs):
            with patch.object(connector, "_run_ps_on", return_value=([dc_row], [])):
                result = connector.collect_dc_inventory("dc_windows_features")

        warning_entries = [r for r in result if "warning" in r]
        assert len(warning_entries) == 1
        assert "11" in warning_entries[0]["warning"]
        # 11 DC rows + 1 warning entry, and every DC row must be the real
        # OK row, not an "Unreachable" fallback with the same count.
        assert len(result) == 12
        dc_status_entries = [r for r in result if "DC" in r]
        assert len(dc_status_entries) == 11
        assert all(r["Status"] == "OK" for r in dc_status_entries)

    def test_warning_mentions_forest_contains(
        self, connector: LiveConnector
    ) -> None:
        dcs = [f"dc{i:02d}.contoso.local" for i in range(1, 12)]

        with patch.object(connector, "enumerate_dcs", return_value=dcs):
            with patch.object(connector, "_run_ps_on", return_value=([], [])):
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
# _validate_dc_fqdn — SEC-M1 defense-in-depth validation
# ---------------------------------------------------------------------------

class TestValidateDcFqdn:

    def test_valid_fqdn_passes(self) -> None:
        _validate_dc_fqdn("DC01.example.local")

    def test_valid_short_hostname_passes(self) -> None:
        _validate_dc_fqdn("dc01")

    def test_valid_fqdn_with_hyphens_and_digits_passes(self) -> None:
        _validate_dc_fqdn("eu-dc-02.corp.contoso.com")

    def test_powershell_injection_raises_value_error(self) -> None:
        with pytest.raises(ValueError, match="Invalid DC hostname"):
            _validate_dc_fqdn("DC01.example.local; Remove-Item C:\\")

    def test_subexpression_injection_raises_value_error(self) -> None:
        with pytest.raises(ValueError, match="Invalid DC hostname"):
            _validate_dc_fqdn("$(Get-Process)")

    def test_backtick_raises_value_error(self) -> None:
        with pytest.raises(ValueError, match="Invalid DC hostname"):
            _validate_dc_fqdn("dc01`nWrite-Host x")

    def test_empty_string_raises_value_error(self) -> None:
        with pytest.raises(ValueError, match="Invalid DC hostname"):
            _validate_dc_fqdn("")

    def test_none_raises_value_error(self) -> None:
        with pytest.raises(ValueError, match="Invalid DC hostname"):
            _validate_dc_fqdn(None)  # type: ignore[arg-type]

    def test_too_long_raises_value_error(self) -> None:
        with pytest.raises(ValueError, match="Invalid DC hostname"):
            _validate_dc_fqdn("a" * 254)

    def test_spaces_raise_value_error(self) -> None:
        with pytest.raises(ValueError, match="Invalid DC hostname"):
            _validate_dc_fqdn("dc01 .example.local")

    def test_run_ps_on_rejects_bad_fqdn_before_subprocess(
        self, connector: LiveConnector
    ) -> None:
        # The ValueError must be raised before any subprocess is spawned.
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            with pytest.raises(ValueError, match="Invalid DC hostname"):
                connector._run_ps_on("dc01; Remove-Item C:\\", "some script")
        mock_run.assert_not_called()


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
            rows, warnings = connector._run_ps_on("dc01.contoso.local", "Get-ADDomain | ConvertTo-Json")
        assert rows == expected
        assert warnings == []

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
            rows, warnings = connector._run_ps_on("dc01.contoso.local", "some script")
        assert rows == []
        assert warnings == []

    def test_null_stdout_returns_empty_list(self, connector: LiveConnector) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=0,
                stdout=b"null",
                stderr=b"",
            )
            rows, warnings = connector._run_ps_on("dc01.contoso.local", "some script")
        assert rows == []
        assert warnings == []

    def test_timeout_raises_runtime_error(self, connector: LiveConnector) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.side_effect = subprocess.TimeoutExpired(
                cmd=["powershell.exe"], timeout=30
            )
            with pytest.raises(RuntimeError, match="timeout"):
                connector._run_ps_on("dc01.contoso.local", "some script")

    def test_stderr_included_in_error_message(self, connector: LiveConnector) -> None:
        # Plain-text, non-CLIXML stderr -- exercises _clixml's fallback path
        # (parse_streams finds no Error-stream content, extract_error_message
        # falls back to the raw decoded text). Kept deliberately alongside
        # the realistic-CLIXML tests below, not replaced by them: this is
        # the actual behavior for a stderr that isn't CLIXML at all (e.g. a
        # PowerShell startup failure before CLIXML machinery engages).
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=1,
                stdout=b"",
                stderr=b"Cannot find module ServerManager.",
            )
            with pytest.raises(RuntimeError, match="Cannot find module ServerManager"):
                connector._run_ps_on("dc01.contoso.local", "some script")

    # -----------------------------------------------------------------
    # task #141 -- warnings captured on the success path, realistic CLIXML
    # -----------------------------------------------------------------

    def test_warnings_extracted_from_realistic_clixml_stderr(
        self, connector: LiveConnector
    ) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=0,
                stdout=b"[]",
                stderr=_clixml_bytes(warnings=["11018 users had null userAccountControl"]),
            )
            rows, warnings = connector._run_ps_on("dc01.contoso.local", "Get-ADUser -Filter * | ConvertTo-Json")
        assert rows == []
        assert warnings == ["11018 users had null userAccountControl"]

    def test_multiple_warnings_all_extracted_in_order(self, connector: LiveConnector) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=0,
                stdout=b"[]",
                stderr=_clixml_bytes(warnings=["first warning", "second warning", "third warning"]),
            )
            _rows, warnings = connector._run_ps_on("dc01.contoso.local", "script")
        assert warnings == ["first warning", "second warning", "third warning"]

    def test_no_warnings_when_stderr_has_only_progress_noise(
        self, connector: LiveConnector
    ) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=0,
                stdout=b"[]",
                stderr=_clixml_bytes(),  # progress record only, no <S S="warning">
            )
            _rows, warnings = connector._run_ps_on("dc01.contoso.local", "script")
        assert warnings == []

    def test_every_warning_written_to_eventlog(self, connector: LiveConnector) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run, \
             patch("legacy_mcp.modes.live.eventlog.warn") as mock_eventlog_warn:
            mock_run.return_value = MagicMock(
                returncode=0,
                stdout=b"[]",
                stderr=_clixml_bytes(warnings=["warning A", "warning B"]),
            )
            connector._run_ps_on("dc01.contoso.local", "script", section="users")

        assert mock_eventlog_warn.call_count == 2
        logged = [call.args[0] for call in mock_eventlog_warn.call_args_list]
        assert any("warning A" in msg and "contoso.local/users" in msg for msg in logged)
        assert any("warning B" in msg and "contoso.local/users" in msg for msg in logged)

    # -----------------------------------------------------------------
    # task #141 -- clean error messages from realistic CLIXML on failure
    # -----------------------------------------------------------------

    def test_clean_error_message_extracted_from_realistic_clixml(
        self, connector: LiveConnector
    ) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=1,
                stdout=b"",
                stderr=_clixml_bytes(errors=[
                    "Get-ADUser : The server is not operational",
                    "    + CategoryInfo          : ResourceUnavailable",
                ]),
            )
            with pytest.raises(RuntimeError) as exc_info:
                connector._run_ps_on("dc01.contoso.local", "script")

        message = str(exc_info.value)
        assert "The server is not operational" in message
        # The raw CLIXML markup must NOT leak into the message shown to the
        # caller -- that's the whole point of task #141's failure-path fix.
        assert "<Objs" not in message
        assert "_x000D_" not in message
        assert "#< CLIXML" not in message

    def test_raw_stderr_written_to_eventlog_error_on_failure(
        self, connector: LiveConnector
    ) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run, \
             patch("legacy_mcp.modes.live.eventlog.error") as mock_eventlog_error:
            mock_run.return_value = MagicMock(
                returncode=1,
                stdout=b"",
                stderr=_clixml_bytes(errors=["The server is not operational"]),
            )
            with pytest.raises(RuntimeError):
                connector._run_ps_on("dc01.contoso.local", "script", section="users")

        mock_eventlog_error.assert_called_once()
        logged = mock_eventlog_error.call_args.args[0]
        # EventLog gets the full raw detail (CLIXML markup included) --
        # deliberately NOT the cleaned-up version shown in the exception,
        # so no technical detail is lost even though the exception message
        # is now readable.
        assert "<Objs" in logged
        assert "users" in logged


# ---------------------------------------------------------------------------
# run_ps — entry-point DC delegation
# ---------------------------------------------------------------------------

class TestRunPs:

    def test_delegates_to_run_ps_on_with_entry_point_dc(
        self, connector: LiveConnector
    ) -> None:
        with patch.object(connector, "_run_ps_on", return_value=([{"x": 1}], [])) as mock:
            result = connector.run_ps("Get-ADForest | ConvertTo-Json")
        mock.assert_called_once_with(
            "dc01.contoso.local", "Get-ADForest | ConvertTo-Json", section=None
        )
        assert result == ([{"x": 1}], [])

    def test_section_forwarded_to_run_ps_on(self, connector: LiveConnector) -> None:
        with patch.object(connector, "_run_ps_on", return_value=([], [])) as mock:
            connector.run_ps("script", section="users")
        mock.assert_called_once_with("dc01.contoso.local", "script", section="users")
