"""MCP tools -- create_snapshot, get_snapshot_status, list_snapshots, load_snapshot."""

from __future__ import annotations

import json
import os
import secrets
import sys
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace

from legacy_mcp.storage.loader import KNOWN_SECTIONS
from legacy_mcp.eventlog import writer as eventlog
from legacy_mcp import __version__ as _server_version
from legacy_mcp.tools import snapshot_jobs

# Sections the collector emits as a single dict rather than a list.
_SCALAR_SECTIONS = {"forest", "default_password_policy", "fsmo_roles"}

_DEFAULT_OUTPUT_DIR = Path(r"C:\LegacyMCP-Data\snapshots")


def _run_snapshot_job(
    job_id: str,
    forest_name: str,
    encryption: str,
    dest: Path,
    connector: Any,
    forest_cfg: Any | None,
) -> None:
    try:
        payload: dict[str, Any] = {}
        sections_failed: list[str] = []

        for idx, section in enumerate(KNOWN_SECTIONS, 1):
            snapshot_jobs.update_job_step(job_id, section, idx)
            try:
                rows = connector.query(section)
                if not rows:
                    continue
                if section in _SCALAR_SECTIONS:
                    payload[section] = rows[0]
                else:
                    payload[section] = rows
            except Exception:  # noqa: BLE001
                sections_failed.append(section)

        sections_collected = len(payload)
        forest_module = (forest_cfg.module if forest_cfg else None) or "ad-core"
        collected_by = (
            os.environ.get("LEGACYMCP_AD_USER")
            or os.environ.get("USERNAME")
            or ""
        )

        snapshot: dict[str, Any] = {
            "_metadata": {
                "module": forest_module,
                "version": "1.0",
                "forest": forest_name,
                "collected_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "collector_version": f"legacymcp-live-{_server_version}",
                "collected_by": collected_by,
                "encryption": encryption,
                "sections_collected": sections_collected,
            },
            **payload,
        }

        json_bytes = json.dumps(snapshot, ensure_ascii=False, indent=2).encode("utf-8")
        dest.parent.mkdir(parents=True, exist_ok=True)

        if encryption == "dpapi":
            if sys.platform != "win32":
                snapshot_jobs.fail_job(job_id, "DPAPI encryption is only available on Windows.")
                return
            try:
                import win32crypt  # type: ignore[import]
            except ImportError:
                snapshot_jobs.fail_job(
                    job_id,
                    "win32crypt is not available. Install pywin32 to use DPAPI encryption.",
                )
                return
            data_to_write: bytes = win32crypt.CryptProtectData(
                json_bytes, None, None, None, None, 0
            )
        else:
            data_to_write = json_bytes

        tmp = dest.with_suffix(".tmp")
        tmp.write_bytes(data_to_write)
        os.replace(tmp, dest)

        if encryption == "none":
            eventlog.warn(
                f"Plaintext snapshot written to {dest} "
                "-- classify as Confidential/Restricted"
            )

        snapshot_jobs.complete_job(job_id, str(dest), sections_collected, sections_failed)

    except Exception as exc:  # noqa: BLE001
        snapshot_jobs.fail_job(job_id, str(exc))


def register(mcp: "FastMCP", workspace: "Workspace", *, snapshot_path: str | None = None) -> None:
    effective_snapshot_dir = Path(snapshot_path) if snapshot_path else _DEFAULT_OUTPUT_DIR

    @mcp.tool()
    def create_snapshot(
        forest_name: str,
        encryption: str = "none",
        output_path: str | None = None,
    ) -> dict[str, Any]:
        """Export all available AD data for a forest to a JSON snapshot file.

        The export runs in the background -- this tool returns immediately with a
        job_id. Use get_snapshot_status(job_id) to poll progress and retrieve the
        output path when the job completes.

        The output format is identical to the PowerShell collector JSON, so the
        resulting file can be loaded back into LegacyMCP as an offline workspace
        via load_snapshot.

        Parameters
        ----------
        forest_name:
            The forest to snapshot (use the name returned by list_workspaces).
        encryption:
            "none"     -- plaintext JSON (default). A warning is written to the
                         LegacyMCP EventLog because the file contains sensitive
                         AD data.
            "dpapi"    -- encrypted with Windows DPAPI (win32crypt). The file is
                         saved with a .json.dpapi extension and can only be
                         decrypted by the same Windows user/machine.
            "keyvault" -- not available in the open-source layer; returns an
                         error immediately.
        output_path:
            Full path for the output file. If omitted, the file is written to
            C:\\LegacyMCP-Data\\snapshots\\ with automatic naming:
            <forestname>_YYYYMMDD_HHMMSS_<4hex>.json  (or .json.dpapi for DPAPI).

        Returns {"job_id": "..."} on success, or {"status": "error", ...} for
        parameter validation failures (keyvault, unknown encryption, unknown forest).
        """
        if encryption == "keyvault":
            return {
                "status": "error",
                "forest": forest_name,
                "error": "Key Vault encryption requires LegacyMCP Enterprise",
            }

        if encryption not in ("none", "dpapi"):
            return {
                "status": "error",
                "forest": forest_name,
                "error": (
                    f"Unknown encryption value '{encryption}'. "
                    "Use 'none' or 'dpapi'."
                ),
            }

        try:
            conn = workspace.connector(forest_name)
        except KeyError as exc:
            return {
                "status": "error",
                "forest": forest_name,
                "error": str(exc),
            }

        safe_name = (
            forest_name.replace(".", "-").replace("\\", "-").replace("/", "-")
        )
        ts_suffix = datetime.now().strftime("%Y%m%d_%H%M%S")
        hex_suffix = secrets.token_hex(2)
        job_id = f"{safe_name}_{ts_suffix}_{hex_suffix}"

        if output_path is not None:
            dest = Path(output_path)
        else:
            ext = ".json.dpapi" if encryption == "dpapi" else ".json"
            dest = effective_snapshot_dir / f"{job_id}{ext}"

        forest_cfg = next((f for f in workspace.forests if f.name == forest_name), None)

        snapshot_jobs.create_job(job_id, forest_name, len(KNOWN_SECTIONS))

        thread = threading.Thread(
            target=_run_snapshot_job,
            args=(job_id, forest_name, encryption, dest, conn, forest_cfg),
            daemon=True,
        )
        thread.start()

        return {"job_id": job_id}

    # ------------------------------------------------------------------

    @mcp.tool()
    def get_snapshot_status(job_id: str) -> dict[str, Any]:
        """Check the status of a snapshot job started by create_snapshot.

        Job state is held in memory only and is lost on server restart.

        Parameters
        ----------
        job_id:
            The job identifier returned by create_snapshot.

        Returns the full job dict (status, forest_name, current_step,
        step_index, total_steps, file_path, error, sections_collected,
        sections_failed, started_at, completed_at), or
        {"status": "not_found", "job_id": ...} if the job_id is unknown.
        """
        job = snapshot_jobs.get_job(job_id)
        if job is None:
            return {"status": "not_found", "job_id": job_id}
        return job

    # ------------------------------------------------------------------

    @mcp.tool()
    def list_snapshots(
        path: str = str(effective_snapshot_dir),
    ) -> dict[str, Any]:
        """List snapshot files available in a directory.

        Reads the _metadata block from each JSON snapshot to report forest
        name, timestamp, encryption, and section count without loading the
        full data into memory.  Files with the .json.dpapi extension are
        listed with encryption="dpapi" but are never decrypted.  If the
        directory does not exist the tool returns total=0 without an error.

        Parameters
        ----------
        path:
            Directory to scan (default: C:\\LegacyMCP-Data\\snapshots\\).
        """
        scan_dir = Path(path)
        if not scan_dir.exists() or not scan_dir.is_dir():
            return {"snapshots": [], "total": 0, "path_scanned": str(scan_dir)}

        entries: list[dict[str, Any]] = []
        for f in sorted(scan_dir.iterdir()):
            name = f.name
            if name.endswith(".json.dpapi"):
                enc: str = "dpapi"
                meta: dict[str, Any] = {}
            elif name.endswith(".json"):
                enc = "none"
                try:
                    data = json.loads(f.read_text(encoding="utf-8-sig"))
                    meta = data.get("_metadata", {})
                except Exception:  # noqa: BLE001
                    continue  # skip unreadable / non-snapshot JSON files
            else:
                continue

            size_kb = round(f.stat().st_size / 1024, 1)
            entries.append({
                "path": str(f),
                "forest": meta.get("forest"),
                "timestamp": meta.get("collected_at") or meta.get("timestamp"),
                "encryption": enc,
                "sections_collected": meta.get("sections_collected", 0),
                "size_kb": size_kb,
                "filename": name,
            })

        return {
            "snapshots": entries,
            "total": len(entries),
            "path_scanned": str(scan_dir),
        }

    # ------------------------------------------------------------------

    @mcp.tool()
    def load_snapshot(
        path: str,
        forest_alias: str | None = None,
        encryption: str = "none",
    ) -> dict[str, Any]:
        """Load a snapshot file into the workspace as a queryable forest.

        After a successful load the snapshot appears in list_workspaces() and
        can be queried with any existing tool by passing forest_alias as the
        forest_name argument.

        Parameters
        ----------
        path:
            Full path to the snapshot JSON file.
        forest_alias:
            Name the loaded snapshot will be known as inside the workspace.
            If omitted, the alias is derived from the _metadata as
            "<forest>@<YYYY-MM-DD>", e.g. "contoso.local@2025-03-23".
        encryption:
            "none" (default) -- plaintext JSON.
            "dpapi"          -- DPAPI-encrypted file; requires Windows +
                               pywin32 (not yet implemented in the open-
                               source layer, returns an error).
        """
        from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation
        from legacy_mcp.modes.offline import OfflineConnector

        src = Path(path)

        if not src.exists():
            return {
                "status": "error",
                "forest_alias": None,
                "sections_loaded": 0,
                "message": f"File not found: {path}",
            }

        if encryption == "dpapi":
            return {
                "status": "error",
                "forest_alias": None,
                "sections_loaded": 0,
                "message": (
                    "DPAPI decryption for load_snapshot requires LegacyMCP "
                    "Enterprise or manual pre-decryption."
                ),
            }

        if encryption != "none":
            return {
                "status": "error",
                "forest_alias": None,
                "sections_loaded": 0,
                "message": (
                    f"Unknown encryption '{encryption}'. Use 'none' or 'dpapi'."
                ),
            }

        try:
            data = json.loads(src.read_text(encoding="utf-8-sig"))
        except Exception as exc:  # noqa: BLE001
            return {
                "status": "error",
                "forest_alias": None,
                "sections_loaded": 0,
                "message": f"Failed to read snapshot: {exc}",
            }

        meta = data.get("_metadata", {})
        forest_name = meta.get("forest") or src.stem.split("_")[0]
        timestamp_str = meta.get("collected_at") or meta.get("timestamp", "")
        date_str = timestamp_str[:10] if len(timestamp_str) >= 10 else ""

        if forest_alias is None:
            forest_alias = (
                f"{forest_name}@{date_str}" if date_str else forest_name
            )

        sections_loaded = sum(1 for s in KNOWN_SECTIONS if data.get(s))

        new_forest = ForestConfig(
            name=forest_alias,
            relation=ForestRelation.SNAPSHOT,
            file=str(src),
        )

        with workspace._lock:
            if forest_alias in workspace._connectors:
                return {
                    "status": "error",
                    "forest_alias": forest_alias,
                    "sections_loaded": 0,
                    "message": (
                        f"Forest alias '{forest_alias}' is already loaded in the "
                        "workspace. Use a different alias or reload_workspace to "
                        "refresh."
                    ),
                }
            workspace.forests.append(new_forest)
            workspace._connectors[forest_alias] = OfflineConnector(new_forest)

        return {
            "status": "success",
            "forest_alias": forest_alias,
            "sections_loaded": sections_loaded,
            "message": (
                f"Snapshot loaded. Use '{forest_alias}' as forest_name to "
                "query this snapshot."
            ),
        }
