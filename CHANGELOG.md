# Changelog

All notable changes to this project will be documented in this file.

## [0.1.3] - 2026-03-30

### Added
- Collector v1.5: file logging with append mode and session header/footer
- Collector v1.5: native `-Verbose` support for detailed per-section output
- Collector v1.5: `_metadata.collection_summary` block with sections_ok/warn/error counts and log_file path

### Changed
- **BREAKING**: collector default output filename changed from `ad-data.json`
  to `<domain>_ad-data.json` (e.g. `formula.it_ad-data.json`).
  Users passing `-OutputPath` explicitly are not affected.
- Log file derived automatically from output path: same stem, `.log` extension,
  same directory as the script.

### Fixed
- Collector log and JSON files now always created in the script directory,
  not in the user profile when PowerShell working directory differs from
  script location.

## [0.1.2] - 2026-03-29

### Added
- Collector v1.4: `_metadata` block as first key in every JSON output
  (module, version, forest, collected_at UTC, collector_version, collected_by)
- `scripts/Register-EventLog.ps1`: idempotent setup script for Windows
  EventLog source registration, must be run once as Administrator
- Visible warning to stderr when EventLog write fails due to unregistered
  source (shown once per process via `_warned` flag)
- Performance Counter: planned feature, documented in CLAUDE.md as roadmap

### Fixed
- Collector export section: added `try/catch` around `_metadata` build and
  `$export` construction -- previously crashed silently without output file
- Collector encoding: replaced em dash `—` with `--` in PS1 string literals
  to avoid PowerShell 5.1 parsing errors on Windows-1252 systems
- Live Mode snapshot `_metadata`: aligned fields with collector v1.4 format
  (module, collected_at UTC with Z suffix, collector_version, collected_by)
  removed legacy fields `generated_by` and `mode`

### Changed
- 257 unit tests (unchanged)
- `list_snapshots` and `load_snapshot` now read `collected_at` with fallback
  to `timestamp` for backward compatibility with pre-v0.1.2 snapshots

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
