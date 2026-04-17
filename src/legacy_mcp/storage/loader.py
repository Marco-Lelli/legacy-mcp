"""JSON → SQLite loader for Offline Mode."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path


# Sections expected in the collector JSON output.
KNOWN_SECTIONS = [
    "forest",
    "optional_features",
    "schema",
    "domains",
    "default_password_policy",
    "dcs",
    "fsmo_roles",
    "eventlog_config",
    "ntp_config",
    "sysvol",
    "sites",
    "site_links",
    "users",
    "privileged_accounts",
    "groups",
    "privileged_groups",
    "group_members",
    "ous",
    "gpos",
    "gpo_links",
    "blocked_inheritance",
    "trusts",
    "fgpp",
    "dns",
    "dns_forwarders",
    "computers",
    "pki",
    "dc_windows_features",
    "dc_services",
    "dc_installed_software",
    "schema_products",
    "fsp",
    "dc_file_locations",
    "dc_network_config",
]


# ---------------------------------------------------------------------------
# PowerShell remoting artefact stripping
# ---------------------------------------------------------------------------
# Invoke-Command injects PSComputerName, PSShowComputerName, RunspaceId into
# every returned object. These fields are not part of the LegacyMCP data model
# and must be removed before the data enters storage.
#
# The primary strip happens at source in the collector PS1 via
# Select-Object -ExcludeProperty. This function is a safety net at load time.
#
# Extend _DC_INVENTORY_NESTED_FIELDS when adding a new module that uses
# Invoke-Command — both this list and the collector PS1 must be updated.

_PS_ARTEFACT_FIELDS: frozenset[str] = frozenset({
    "PSComputerName", "PSShowComputerName", "RunspaceId",
})

# Maps each DC Inventory section to the field that holds nested PS output objects.
_DC_INVENTORY_NESTED_FIELDS: dict[str, str] = {
    "dc_windows_features": "Features",
    "dc_services": "Services",
    "dc_installed_software": "Software",
}


def _strip_ps_artefacts(section: str, rows: list[dict]) -> None:
    """Remove PowerShell remoting artefact fields from nested objects in-place.

    Only applied to DC Inventory sections where Invoke-Command is used.
    No-op if the fields are absent — safe to call unconditionally.
    """
    nested_field = _DC_INVENTORY_NESTED_FIELDS.get(section)
    if nested_field is None:
        return
    for row in rows:
        items = row.get(nested_field)
        if not isinstance(items, list):
            continue
        for item in items:
            if isinstance(item, dict):
                for key in _PS_ARTEFACT_FIELDS:
                    item.pop(key, None)


class JsonLoader:
    """Loads a collector JSON file into an in-memory SQLite database."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> sqlite3.Connection:
        with self.path.open(encoding="utf-8-sig") as fh:
            data = json.load(fh)

        db = sqlite3.connect(":memory:")
        db.row_factory = sqlite3.Row

        for section in KNOWN_SECTIONS:
            rows = data.get(section)
            if not rows:
                continue
            if isinstance(rows, dict):
                rows = [rows]
            _strip_ps_artefacts(section, rows)
            _create_and_insert(db, section, rows)

        db.commit()
        return db


def _create_and_insert(
    db: sqlite3.Connection, table: str, rows: list[dict]
) -> None:
    if not rows:
        return

    columns = list(rows[0].keys())
    col_defs = ", ".join(f'"{c}" TEXT' for c in columns)
    db.execute(f'CREATE TABLE IF NOT EXISTS "{table}" ({col_defs})')

    placeholders = ", ".join("?" for _ in columns)
    for row in rows:
        values = [_serialize(row.get(c)) for c in columns]
        db.execute(f'INSERT INTO "{table}" VALUES ({placeholders})', values)


def _serialize(value: object) -> str | None:
    if value is None:
        return None
    if isinstance(value, (dict, list)):
        return json.dumps(value)
    return str(value)
