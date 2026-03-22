"""MCP tool -- create_snapshot: export a forest dataset to a JSON snapshot file."""

from __future__ import annotations

import json
import sys
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace

from legacy_mcp.storage.loader import KNOWN_SECTIONS
from legacy_mcp.eventlog import writer as eventlog

# Sections the collector emits as a single dict rather than a list.
_SCALAR_SECTIONS = {"forest", "default_password_policy", "fsmo_roles"}

_DEFAULT_OUTPUT_DIR = Path(r"C:\LegacyMCP-Data\snapshots")


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def create_snapshot(
        forest_name: str,
        encryption: str = "none",
        output_path: str | None = None,
    ) -> dict[str, Any]:
        """Export all available AD data for a forest to a JSON snapshot file.

        Use this tool to persist a live or offline dataset to disk -- for
        example to archive a point-in-time assessment, hand off data to a
        colleague, or refresh an existing offline JSON file with updated data.

        The output format is identical to the PowerShell collector JSON, so the
        resulting file can be loaded back into LegacyMCP as an offline workspace.

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
                         error.
        output_path:
            Full path for the output file. If omitted, the file is written to
            C:\\LegacyMCP-Data\\snapshots\\ with automatic naming:
            <forestname>_YYYYMMDD_HHMMSS.json  (or .json.dpapi for DPAPI).

        Returns a status dict: status, path, forest, sections_collected,
        sections_failed, encryption, timestamp.
        """
        timestamp = datetime.now().isoformat(timespec="seconds")

        # ------------------------------------------------------------------
        # Validate encryption parameter up front.
        # ------------------------------------------------------------------
        if encryption == "keyvault":
            return {
                "status": "error",
                "path": None,
                "forest": forest_name,
                "sections_collected": 0,
                "sections_failed": [],
                "encryption": "keyvault",
                "timestamp": timestamp,
                "error": "Key Vault encryption requires LegacyMCP Enterprise",
            }

        if encryption not in ("none", "dpapi"):
            return {
                "status": "error",
                "path": None,
                "forest": forest_name,
                "sections_collected": 0,
                "sections_failed": [],
                "encryption": encryption,
                "timestamp": timestamp,
                "error": (
                    f"Unknown encryption value '{encryption}'. "
                    "Use 'none' or 'dpapi'."
                ),
            }

        # ------------------------------------------------------------------
        # Resolve destination path.
        # ------------------------------------------------------------------
        if output_path is not None:
            dest = Path(output_path)
        else:
            safe_name = (
                forest_name.replace(".", "-").replace("\\", "-").replace("/", "-")
            )
            ts_suffix = datetime.now().strftime("%Y%m%d_%H%M%S")
            ext = ".json.dpapi" if encryption == "dpapi" else ".json"
            dest = _DEFAULT_OUTPUT_DIR / f"{safe_name}_{ts_suffix}{ext}"

        # ------------------------------------------------------------------
        # Resolve connector.
        # ------------------------------------------------------------------
        try:
            conn = workspace.connector(forest_name)
        except KeyError as exc:
            return {
                "status": "error",
                "path": None,
                "forest": forest_name,
                "sections_collected": 0,
                "sections_failed": [],
                "encryption": encryption,
                "timestamp": timestamp,
                "error": str(exc),
            }

        # ------------------------------------------------------------------
        # Collect all sections with graceful degradation.
        # ------------------------------------------------------------------
        payload: dict[str, Any] = {}
        sections_failed: list[str] = []

        for section in KNOWN_SECTIONS:
            try:
                rows = conn.query(section)
                if not rows:
                    continue
                # Replicate collector format: scalar sections are a single dict.
                if section in _SCALAR_SECTIONS:
                    payload[section] = rows[0]
                else:
                    payload[section] = rows
            except Exception:  # noqa: BLE001
                sections_failed.append(section)

        sections_collected = len(payload)

        snapshot: dict[str, Any] = {
            "_metadata": {
                "generated_by": "LegacyMCP",
                "version": "1.0",
                "timestamp": timestamp,
                "forest": forest_name,
                "mode": "live_snapshot",
                "encryption": encryption,
            },
            **payload,
        }

        # ------------------------------------------------------------------
        # Serialize and write (with optional DPAPI encryption).
        # ------------------------------------------------------------------
        json_bytes = json.dumps(snapshot, ensure_ascii=False, indent=2).encode("utf-8")

        try:
            dest.parent.mkdir(parents=True, exist_ok=True)

            if encryption == "dpapi":
                if sys.platform != "win32":
                    return {
                        "status": "error",
                        "path": None,
                        "forest": forest_name,
                        "sections_collected": sections_collected,
                        "sections_failed": sections_failed,
                        "encryption": encryption,
                        "timestamp": timestamp,
                        "error": "DPAPI encryption is only available on Windows.",
                    }
                try:
                    import win32crypt  # type: ignore[import]
                except ImportError:
                    return {
                        "status": "error",
                        "path": None,
                        "forest": forest_name,
                        "sections_collected": sections_collected,
                        "sections_failed": sections_failed,
                        "encryption": encryption,
                        "timestamp": timestamp,
                        "error": (
                            "win32crypt is not available. "
                            "Install pywin32 to use DPAPI encryption."
                        ),
                    }
                encrypted = win32crypt.CryptProtectData(
                    json_bytes, None, None, None, None, 0
                )
                dest.write_bytes(encrypted)
            else:
                dest.write_bytes(json_bytes)
                eventlog.warn(
                    f"Plaintext snapshot written to {dest} "
                    "-- classify as Confidential/Restricted"
                )

        except Exception as exc:  # noqa: BLE001
            return {
                "status": "error",
                "path": None,
                "forest": forest_name,
                "sections_collected": sections_collected,
                "sections_failed": sections_failed,
                "encryption": encryption,
                "timestamp": timestamp,
                "error": f"Failed to write snapshot: {exc}",
            }

        return {
            "status": "success",
            "path": str(dest),
            "forest": forest_name,
            "sections_collected": sections_collected,
            "sections_failed": sections_failed,
            "encryption": encryption,
            "timestamp": timestamp,
        }
