# Changelog

All notable changes to this project will be documented in this file.

## [0.1.1] - 2026-03-28

### Added
- Deployment profiles (A / B-core / B-enterprise / C) replacing global `mode` field
- Per-forest `module` field for heterogeneous workspace support
- Mixed live + offline workspace support (profile B-core default)
- Configurable `server.snapshot_path` in config.yaml
- Configurable `server.host` binding (default 127.0.0.1, use 0.0.0.0 for LAN)
- New `docs/deployment-profiles.md` with full architectural reference
- Snapshot system: `create_snapshot`, `list_snapshots`, `load_snapshot`
- Backward compatibility: deprecated global `mode` field with warning

### Fixed
- `list_workspaces` now correctly reports per-forest effective mode override

### Changed
- 257 unit tests (from 241)
- CLAUDE.md updated with deployment profiles, module system, snapshot bridge

## [0.1.0] - 2026-03-28

### Added
- 27 MCP tools covering all core AD sections (Offline Mode and Live Mode)
- Streamable HTTP transport (Profilo A/B/C)
- Snapshot system (create, list, load)
- Paginated responses on all tools
- PowerShell collector v1.3 with safe export (pre-check, post-check JSON validation)
- Live Mode with Kerberos authentication over WinRM HTTPS
- 241 unit tests
- Security by Design documentation (10 principles)
- Public documentation: README, getting-started.md, beyond-webster.md
