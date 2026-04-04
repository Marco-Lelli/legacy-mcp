"""Workspace — defines the assessment scope (forests, domains, mode)."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from legacy_mcp.modes.live import LiveConnector
    from legacy_mcp.modes.offline import OfflineConnector


class WorkspaceMode(str, Enum):
    LIVE = "live"
    OFFLINE = "offline"


class ForestRelation(str, Enum):
    STANDALONE = "standalone"
    SOURCE = "source"       # migration scenario: source forest
    DESTINATION = "dest"    # migration scenario: destination forest
    TRUSTED = "trusted"
    SNAPSHOT = "snapshot"   # dynamically loaded snapshot file


@dataclass
class ForestConfig:
    name: str
    relation: ForestRelation = ForestRelation.STANDALONE
    mode: WorkspaceMode | None = None  # per-forest override; None = inherit workspace mode
    module: str | None = None          # optional module identifier (e.g. "ad-core", "ad-pki")
    # Offline Mode
    file: str | None = None
    # Live Mode
    dc: str | None = None
    credentials: str = "gmsa"  # "gmsa" | "env" | "prompt"
    timeout_seconds: int = 30


@dataclass
class Workspace:
    mode: WorkspaceMode
    forests: list[ForestConfig]
    _connectors: dict[str, Any] = field(default_factory=dict, init=False, repr=False)

    @classmethod
    def from_config(cls, config: dict[str, Any]) -> "Workspace":
        mode = WorkspaceMode(config["mode"])
        forests = [
            ForestConfig(
                name=f["name"],
                relation=ForestRelation(f.get("relation", "standalone")),
                mode=WorkspaceMode(f["mode"]) if f.get("mode") else None,
                module=f.get("module"),
                file=f.get("file"),
                dc=f.get("dc"),
                credentials=f.get("credentials", "gmsa"),
                timeout_seconds=int(f.get("timeout_seconds", 30)),
            )
            for f in config["workspace"]["forests"]
        ]
        workspace = cls(mode=mode, forests=forests)
        workspace._init_connectors()
        return workspace

    def _init_connectors(self) -> None:
        for forest in self.forests:
            effective_mode = forest.mode if forest.mode is not None else self.mode
            if effective_mode == WorkspaceMode.OFFLINE:
                from legacy_mcp.modes.offline import OfflineConnector
                if not forest.file:
                    raise ValueError(
                        f"Forest '{forest.name}' requires 'file' in offline mode."
                    )
                self._connectors[forest.name] = OfflineConnector(forest)
            else:
                from legacy_mcp.modes.live import LiveConnector
                if not forest.dc:
                    raise ValueError(
                        f"Forest '{forest.name}' requires 'dc' in live mode."
                    )
                self._connectors[forest.name] = LiveConnector(forest)

    def connector(self, forest_name: str | None = None) -> Any:
        """Return connector for a given forest.

        If forest_name is None and there is exactly one forest, that forest is
        used implicitly.  If there are multiple forests, the caller must
        provide forest_name explicitly.
        """
        if forest_name is None:
            if len(self.forests) > 1:
                names = ", ".join(f.name for f in self.forests)
                raise ValueError(
                    f"forest_name obbligatorio quando sono configurati piu' forest. "
                    f"Forest disponibili: {names}"
                )
            forest_name = self.forests[0].name
        if forest_name not in self._connectors:
            raise KeyError(f"Forest '{forest_name}' not found in workspace.")
        return self._connectors[forest_name]

    @property
    def forest_names(self) -> list[str]:
        return [f.name for f in self.forests]

    @property
    def is_migration(self) -> bool:
        relations = {f.relation for f in self.forests}
        return ForestRelation.SOURCE in relations and ForestRelation.DESTINATION in relations
