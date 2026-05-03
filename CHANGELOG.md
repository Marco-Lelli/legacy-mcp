# Changelog

All notable changes to this project will be documented in this file.

## [0.2.1] - 2026-05-03 "Snap-and-Forget"

### New features

- `create_snapshot` is now asynchronous: returns a `job_id` immediately and
  runs the export in a background thread. No more waiting.
- New tool `get_snapshot_status(job_id)` — poll progress in real time with
  a step counter (e.g. "schema 3/34"), retrieve the output path on completion.
- New tool `get_fsp` — query Foreign Security Principals with optional
  `orphaned_only` filter.
- `get_user_summary` extended with three new counters: `no_last_logon`,
  `primary_group_not_domain_users`, `cannot_change_password`.
- `get_users` extended with three new filters matching the new summary counters.
- Snapshot path is now configurable via installer (`-SnapshotPath`) and
  manageable post-install via `Config-LegacyMCP.ps1 -Set SnapshotPath`.

### Collector

- Collector v1.6.3: all AD sections now delegated to dedicated PSM1 modules.
  Previously inline sections: schema, fsmo_roles, groups, group_members,
  gpo_links, blocked_inheritance, fsp, computers.
- Group member count bug fixed: `Members.Count` was silently truncated at
  1500 (LDAP page limit). Now uses `Get-ADGroupMember | Measure-Object`.
- `CannotChangePassword` field added to user collection.

### Security

- OAuth2 Host header injection fix (CVE-2025-6514 related): `authorization_endpoint`
  now derived from server config, not from the HTTP request `Host` header.
- `mcp-remote` pinned to `0.1.38` in `mcp-remote-live.ps1`.
- CI workflow: `permissions: contents: read` added.

### Documentation

- `CLAUDE.md` updated: POLP baseline, async snapshot behavior, repo structure,
  resolved known issues removed.
- New `docs/tools-reference.md`: all 38 MCP tools documented with parameters,
  return shape, and example prompts.

### Bug fixes

- `PrimaryGroupID` deserialization bug in Live Mode: PowerShell returns it as
  `Object[]` — normalized to integer via `_get_primary_group_id()` helper.

## [0.2.0] - 2026-04-25 "Least Privilege"

### Added

- `Set-LegacyMCPPermissions.ps1`: idempotent POLP delegation script --
  configures 7 delegations required for Live Mode on the target domain
  (task #42)
- `Remove-LegacyMCPPermissions.ps1`: idempotent POLP revocation script --
  mirrors Set-LegacyMCPPermissions.ps1 (task #43)
- `docs/minimum-permissions.md`: public POLP matrix -- rationale for each
  delegation, known limitations, and field-certification results (task #51)
- RSAT-AD-PowerShell and RSAT-DNS-Server added as mandatory Live Mode
  prerequisites with blocking pre-flight check in `Install-LegacyMCP.ps1`
  (task #76)

### Changed

- Live Mode migrated from pywinrm/winkerberos to subprocess PowerShell
  (`Invoke-Command`) -- removes native WinRM dependency, simplifies
  Kerberos authentication (task #70)
- DPAPI-NG decryption migrated from `dpapi-ng` Python library to subprocess
  PowerShell (`ConvertFrom-DpapiNGSecret`) (task #65)
- Live Mode alignment round 2: 5 field-certified fixes across dc_services,
  dc_network_config, sysvol, dns, dns_forwarders -- snapshot now covers
  32/32 sections (task #73)
- Collector bumped to v1.6.2: fix msDFSR-Flags mapping in
  `DomainControllers.psm1` (0/16/32/48 -> Start/Prepared/Redirected/
  Eliminated)

### Security

- CVE-2025-6514: `oauth.py` Host header injection eliminated -- `base_url`
  now derived from server config, not request input; `mcp-remote` pinned
  to version 0.1.38
- POLP matrix field-certified: 7 delegations, 21/22 PASS (T18 fail by
  design on Windows Server 2012 R2)

### Breaking Changes

- API key storage format changed from REG_BINARY (DPAPI machine-scope) to
  REG_SZ Base64 (DPAPI-NG). Fresh install required -- existing Profile B
  deployments must re-run `Setup-LegacyMCPClient.ps1`.

### Tests

- 398 tests passing

## [0.1.8] - 2026-04-15 "All-you-can DC"

### Added

- DC Inventory multi-DC support in Live Mode: `get_dc_features`,
  `get_dc_services`, `get_dc_software` now collect from all Domain Controllers
  in the forest, not only the configured entry-point DC
- `LiveConnector.run_ps_on(dc_fqdn, script)` — opens a dedicated WinRM session
  to any DC FQDN with full retry/backoff support
- `LiveConnector.enumerate_dcs()` — queries the entry-point DC for the full
  list of DC FQDNs in the forest; falls back to entry-point DC on error
- `LiveConnector.collect_dc_inventory(section)` — sequential multi-DC
  collection with per-DC soft degradation and >10 DC warning
- DC Inventory collector reporting: found/collected/failed count output for all
  DC inventory functions in `DomainControllers.psm1`
- `PRINCIPLES.md` published in repository root — 17 project principles
- Community Standards: `CODE_OF_CONDUCT.md`, `SECURITY.md`, issue templates,
  PR template; private vulnerability reporting enabled

### Changed

- Collector version bumped to v1.6.1 (DC inventory reporting)
- Principle 17 updated: field testing requirement extended to all Live Mode
  changes, not only Profile B

### Fixed

- AP-1 noted: `PSComputerName`/`RunspaceId`/`PSShowComputerName` residual
  fields in `loader.py` — tracked for dedicated session

## [0.1.7] "Field Notes" — 2026-04-14

### Added
- DC Inventory: three new MCP tools and collector sections per Domain Controller
  - `get_dc_features` — installed Windows Server roles
  - `get_dc_services` — running and auto-start services
  - `get_dc_software` — installed software from registry
  - Collector v1.6: `dc_windows_features`, `dc_services`, `dc_installed_software`
  - Live Mode: all three tools work via WinRM (local execution on DC)
  - Backward compatible: collector < v1.6 returns `_note` instead of exception
- SIDHistory collection in collector and `has_sid_history` filter in `get_users`
- `mcp-remote-live.ps1` added to installer folder and signed artifacts list

### Fixed
- Bug MW-A: Manage-Workspaces.ps1 config.yaml resolved from $PSScriptRoot/registry
  instead of current working directory
- Bug MW-B: Manage-Workspaces.ps1 -Add normalizes JSON paths to forward slashes
- Bug MW-C: Manage-Workspaces.ps1 -Add no longer writes mode: field in Profile A
- Bug SC-A: Setup-LegacyMCPClient.ps1 now copies mcp-remote-live.ps1 to client folder

### Changed
- README Requirements restructured by machine role (collector/server/consultant)
- docs/getting-started-a.md: ZIP download as alternative to git clone; Git removed
  from prerequisites
- docs/getting-started-b-core.md: client setup instructions for standalone folder
  (no repository required); fixed -ServerUrl to include /mcp suffix
- mcp-remote-live.ps1 misleading "ADAPT" comment replaced with correct note
- docs/getting-started.md restructured with entry point, profile table, common
  prerequisites and assessment tips (session #9)

## [0.1.6] - 2026-04-10 "Open Doors"

### Added
- `.github/workflows/ci.yml`: GitHub Actions CI — pytest on ubuntu-latest +
  PSScriptAnalyzer lint and zip packaging on windows-latest
- `.github/workflows/release.yml`: GitHub Actions Release — automated zip
  artifacts on version tags, published to GitHub Releases
- `docs/code-signing-policy.md`: SignPath Foundation application in progress
- Badge "code signing SignPath" in README

### Changed
- README: deployment profiles diagram updated to A / B-core / B-enterprise / C
- README: "four deployment profiles" in Security by Design and
  Built for enterprise sections
- Full documentation review: `getting-started-a.md`, `getting-started-b-core.md`,
  `tls-certificate-setup.md`, `CONTRIBUTING.md`, `LICENSES.md`,
  `CLAUDE.md` (rewritten in English), `collector/README.txt`,
  `pyproject.toml` (version, cryptography dep, repository URL)
- `client/mcp-remote-live.ps1`: generic placeholders (no real credentials)

### Fixed
- `tests/unit/test_collector_format.py`: use `PureWindowsPath` for Windows
  path validation on Linux CI
- CI: excluded `PSAvoidUsingConvertToSecureStringWithPlainText` from
  PSScriptAnalyzer (intentional DPAPI pattern)

### Tests
- 341 tests passing

## [0.1.5] - 2026-04-08 "Secure Channel"

### Added
- `src/legacy_mcp/oauth.py`: minimal OAuth stub — discovery, /authorize PKCE
  auto-approve, /register dynamic client registration, /token dual grant
  (authorization_code + client_credentials)
- `client/mcp-remote-live.ps1`: DPAPI user-scope wrapper, $ServerUrl and
  $CaCertPath parameters
- `client/mcp-remote-live.bat`: Claude Desktop entry point (generated by Setup)
- `installer/Setup-LegacyMCPClient.ps1`: consultant onboarding script —
  generates .legacymcp-key (DPAPI), mcp-remote-live.bat, updates
  claude_desktop_config.json

### Fixed
- `src/legacy_mcp/auth.py`: added /authorize to OAuth exempt paths
- `src/legacy_mcp/server.py`: _run_with_tls() now wraps serve() in
  async with mcp.session_manager.run()
- `src/legacy_mcp/config_registry.py`: CryptUnprotectData correct signature
  (5 arguments, flag 0x04)
- `installer/Setup-LegacyMCPClient.ps1`: fixed UTF-8 BOM, JSON
  double-escaping, NODE_EXTRA_CA_CERTS inheritance

### Docs
- `docs/deployment-profiles.md`: Profile B client section updated with
  BAT entry point architecture and rationale

### Tests
- 341 tests passing (+16 since v0.1.4)

## [0.1.4] - 2026-04-05 "Easter Prize"

### Fixed
- Installer: NSSM absolute paths for Python executable and AppDirectory
- Installer: AppParameters now includes --config and --transport streamable-http
- Installer: venv skip logic corrected — pip install always runs, -Force recreates venv
- Installer: SeServiceLogonRight automatic verification and grant for Profile B non-gMSA accounts
- Installer: LocalSystem downgraded from [FAIL] to [WARN] in Config -Validate
- Manage-Workspaces: StrictMode-safe metadata access via Get-JsonProperty helper
- Manage-Workspaces: -RepairMetadata no longer crashes on JSON without _metadata
- Manage-Workspaces: -Add accepts valid JSON without _metadata (WARN instead of FAIL)
- Manage-Workspaces: -List and -Validate correct severity on missing _metadata
- EventLog: source "LegacyMCP-Server" separated from log name "LegacyMCP"
- workspace.py: forest_name required on multi-forest workspace (explicit ValueError)
- i18n: all residual Italian strings translated to English

### Tested
- Profile A: 8 test blocks validated end-to-end on development PC
- Profile B: 5 test blocks validated end-to-end on LORENZO (house.local, WS2012R2)
- 286 pytest tests green

## [0.1.3] - 2026-03-30 "Collector Speaks"

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

## [0.1.2] - 2026-03-29 "Collector Metadata & EventLog"

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

## [0.1.1] - 2026-03-28 "Deployment Profiles & Snapshots"

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

## [0.1.0] - 2026-03-28 "First Light"

### Added
- 27 MCP tools covering all core AD sections (Offline Mode and Live Mode)
- Streamable HTTP transport (Profile A/B/C)
- Snapshot system (create, list, load)
- Paginated responses on all tools
- PowerShell collector v1.3 with safe export (pre-check, post-check JSON validation)
- Live Mode with Kerberos authentication over WinRM HTTPS
- 241 unit tests
- Security by Design documentation (10 principles)
- Public documentation: README, getting-started.md, beyond-webster.md
