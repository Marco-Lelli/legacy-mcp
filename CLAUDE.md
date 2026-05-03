# LegacyMCP — CLAUDE.md

## What this project is

LegacyMCP is a Model Context Protocol (MCP) server for on-premises Active Directory.
It exposes AD data as tools that Claude and other LLMs can query directly —
enabling AI-powered assessment of any Active Directory environment.

The project is open source (MIT license) with a proprietary enterprise layer
maintained by Impresoft 4ward. The open boundary follows the scope of
Carl Webster's ADDS_Inventory.ps1 (https://github.com/CarlWebster/Active-Directory-V3).

Repository: https://github.com/Marco-Lelli/legacy-mcp
Author: Marco Lelli, Head of Identity — Impresoft 4ward (https://www.4ward.it)
Blog: https://legacythings.it

---

## Repository Structure
legacy-mcp/
├── collector/              # PowerShell offline data collector
│   ├── Collect-ADData.ps1
│   ├── README.txt
│   └── modules/            # PS helper modules per AD area
├── config/                 # config templates for profiles A / B / C
├── docs/                   # architecture and documentation
├── client/                 # consultant client scripts
│   ├── mcp-remote-live.ps1   # DPAPI wrapper for mcp-remote
│   ├── mcp-remote-live.bat   # Claude Desktop entry point (generated, gitignored)
│   ├── .legacymcp-key        # DPAPI-encrypted API key (generated, gitignored)
│   └── certs/                # server TLS certificate (gitignored)
├── installer/              # PowerShell installer and permission scripts
├── src/legacy_mcp/         # MCP server — Python
│   ├── server.py           # FastMCP entrypoint
│   ├── config.py           # YAML config loader and validation
│   ├── auth.py             # ASGI middleware — API key validation (Profile B)
│   ├── oauth.py            # OAuth 2.0 stub — discovery, PKCE, client_credentials
│   ├── workspace/          # scope and connector management
│   ├── modes/              # live.py and offline.py
│   ├── storage/            # JSON → SQLite ingestion and query helpers
│   ├── tools/              # MCP tool registration (one file per AD area)
│   │   ├── workspace_info.py
│   │   ├── forest.py
│   │   ├── domains.py
│   │   ├── dcs.py
│   │   ├── sysvol.py
│   │   ├── sites.py
│   │   ├── users.py
│   │   ├── groups.py
│   │   ├── computers.py
│   │   ├── ous.py
│   │   ├── gpo.py
│   │   ├── trusts.py
│   │   ├── fgpp.py
│   │   ├── dns.py
│   │   ├── pki.py
│   │   ├── snapshot.py
│   │   ├── snapshot_jobs.py
│   │   └── fsp.py
│   ├── eventlog/           # Windows EventLog writer
│   └── service/            # Windows Service wrapper
├── status/                 # session state and project tracking (ST-*.md)
└── tests/
    ├── fixtures/           # contoso-sample.json (synthetic AD for tests)
    ├── unit/
    └── integration/

---

## Operating Modes

### Live Mode

Connects directly to Domain Controllers via WinRM over HTTPS (port 5986).
Requires a service account with specific delegated permissions (not Domain Admin)
and Kerberos authentication. See docs/minimum-permissions.md for the certified
minimum-privilege baseline.
Data is queried in real time — no collector script, no JSON export.

Infrastructure prerequisites:
- WinRM HTTPS listener active on each target DC (port 5986)
- TLS 1.2 enabled (not default on Windows Server 2012 R2 — enable via registry)
- Valid certificate on each DC (internal CA or self-signed)
- MCP server on a dedicated member server — never on a Domain Controller

### Offline Mode

A PowerShell collector exports AD data to a structured JSON file.
The MCP server loads the JSON into in-memory SQLite for efficient querying.
No network access to the AD environment is required during analysis.

The JSON file is the transport format — readable, verifiable, portable.
SQLite is an internal implementation detail — never exposed to the caller.

---

## Deployment Profiles

The `profile` field in `config.yaml` determines the default mode,
per-forest override permission, and authentication requirements.

| Profile | Default mode | Override | Auth | Notes |
|---------|-------------|----------|------|-------|
| A | offline | no | none | Consultant's local machine |
| B-core | live | yes | Team API key | Shared LAN server |
| B-enterprise | live | yes | Per-user Entra ID | LAN with audit requirements |
| C | offline | no | Strong — mandatory | Internet / SaaS |

For full profile documentation see [docs/deployment-profiles.md](docs/deployment-profiles.md).

### Profile A — Local

MCP server runs as a local process on the consultant's machine.
Communication via stdio — no network exposure, zero attack surface.
No authentication required.

The JSON produced by the collector is classified Confidential/Restricted.
Store outside the repository. Never commit to git. Delete at end of engagement.

Minimal `config.yaml`:

```yaml
profile: A

workspace:
  forests:
    - name: contoso.local
      module: ad-core
      file: C:/LegacyMCP-Data/contoso.local_ad-data.json
```

### Profile B-core — Shared LAN

MCP server runs on a dedicated member server inside the customer network.
Accessible over HTTPS from consultant machines via mcp-remote.
Authentication via shared API key (DPAPI-encrypted, never in plaintext).

**Architectural rule**: the MCP server must never run on a Domain Controller.

```yaml
profile: B-core

workspace:
  forests:
    - name: contoso.local
      module: ad-core
      dc: dc01.contoso.local
      credentials: gmsa

server:
  host: 0.0.0.0
  port: 8000
  ssl_certfile: certs/server.crt
  ssl_keyfile: certs/server.key
```

### config.yaml — deprecated fields

The global `mode:` field at the root level is deprecated since v0.1.4.
Use `profile:` for the deployment profile and, if needed, per-forest `mode:`
for individual overrides. The server emits a warning if `mode:` is detected
at root level.

---

## Module System

Each forest in the workspace optionally declares a `module` field
identifying the type of data it contains (e.g. `ad-core`, `ad-pki`).

Modules are independent — no forced dependencies between them.
Every JSON includes a `_metadata` block with `module`, `collected_at`,
and `collector_version`.

The Core layer includes the `ad-core` module, covering the full AD
inventory as defined by Carl Webster's ADDS_Inventory.ps1.
Additional modules are available in the enterprise layer.

### PS artefact fields

PowerShell remoting (`Invoke-Command`) injects `PSComputerName`,
`RunspaceId`, `PSShowComputerName` into output objects. These are not part
of the LegacyMCP data model and are stripped in two places:

1. Collector PS1 — `Select-Object -ExcludeProperty` before serialization
2. `loader.py` — `_strip_ps_artefacts()` scoped to DC Inventory sections
   (`dc_windows_features`, `dc_services`, `dc_installed_software`)

Any new module that uses `Invoke-Command` must apply both touch points.
Extend `_DC_INVENTORY_NESTED_FIELDS` in `loader.py` for each new section.

---

## Snapshots as Bridge Between Profiles

Snapshots produced in Profile B can be reused in Profile A and Profile C.

- **Profile B → Profile A**: export a snapshot from a live workspace,
  load it locally for consultation or historical comparison.
- **Profile B → Profile C**: the snapshot is the transport format toward
  the Portal in Profile C.

A snapshot is a JSON in the same format as the offline collector output —
loadable in any offline workspace regardless of the profile that produced it.

### Async snapshot execution

`create_snapshot` runs asynchronously and returns a `job_id` immediately.
Use `get_snapshot_status(job_id)` to poll progress and retrieve the output
path when the job completes. Job state is held in memory only and is lost
on server restart.

---

## Security by Design

1. **Read-only by design** — LegacyMCP never creates, modifies, or deletes
   any AD object. Architectural decision, not a technical limitation.

2. **Least privilege** — minimum rights required. In Offline Mode,
   no live AD credentials are needed at all.

3. **Sensitive data stays local** — in Offline Mode, AD data never leaves
   the client network. JSON files are classified Confidential/Restricted.

4. **Strong authentication for exposed endpoints** — three deployment profiles
   with increasing security requirements.

5. **TLS on all non-localhost endpoints** — no plaintext traffic outside
   localhost under any deployment profile.

6. **Credentials never in plaintext** — gMSA for service accounts.
   Never in config files, environment variables, or logs.

7. **Code integrity** — signed PowerShell collector, signed releases,
   SHA256 hashes published for all release artifacts.

8. **Full auditability** — dedicated Windows EventLog, every operation
   logged with who requested what, when, and on which objects.
   SIEM and Sentinel compatible.

9. **Unified data format** — Live Mode snapshots and Offline Mode JSON
   files share the same format. Full interoperability between modes.

10. **Safe degradation** — partial data is always explicit. Unreachable
    Domain Controllers are flagged, never silently skipped.

11. **MCP server never on a Domain Controller** — run on a dedicated
    member server. Architectural rule, not a recommendation.

---

## What NOT to do

- Do not use NTLM as transport or fallback — deprecated, not supported
- Do not write to the Application EventLog — always use the dedicated log
- Do not hardcode credentials — always use gMSA or external configuration
- Do not modify AD objects in the Core layer — read-only is absolute
- Do not use PowerShell older than 5.1
- Do not expose the MCP server on the internet without WAF and strong
  authentication with MFA
- Do not install the MCP server on a Domain Controller
- In PowerShell files, use ASCII-only characters — no em dashes, curly
  quotes, or any character above U+007F. PowerShell on Windows reads
  files without BOM using the system ANSI code page (CP1252) and
  misinterprets multi-byte UTF-8 sequences, causing hard-to-diagnose
  parse errors
- Do not implement anything that conflicts with PRINCIPLES.md without
  an explicit architectural discussion first

---

## Technical Requirements

### PowerShell
- Minimum: PowerShell 5.1 (Windows Management Framework 5.1)
- Optional: PowerShell 7.x
- Coverage: Windows Server 2012 R2 with WMF 5.1 through Windows Server 2025

### MCP Server
- Language: Python 3.10+
- Framework: FastMCP
- Internal data format: JSON (transport) + SQLite in-memory (querying)

### Active Directory authentication
- Preferred: gMSA (Group Managed Service Account)
- Alternative: domain account with explicit credentials via environment
  variables `LEGACYMCP_AD_USER` / `LEGACYMCP_AD_PASSWORD`

### Windows Service
- LegacyMCP can be installed as a Windows service via the installer
- Service manager: NSSM (bundled in `installer/tools/`)
- Automatic restart on crash

### EventLog
- Dedicated log: "LegacyMCP" (not the generic Application log)
- Source name: "LegacyMCP-Server"
- Setup required once: run `scripts/Register-EventLog.ps1` as Administrator
- If not registered, the server continues to function but emits a warning
  on the first failed EventLog write

### Performance Counters
- Not yet implemented — planned for a future release

---

## Git Rules

- Always run `git status` and show the full list of staged files before
  any commit
- Never run `git commit` or `git push` without explicit user confirmation
- Always use absolute paths in configuration files (YAML, JSON) unless
  explicitly requested otherwise
- Always run `pytest` after code changes before committing

---

## Session baseline

At the beginning of every new Claude Code session:
1. Read `PRINCIPLES.md` in the repository root — these are the non-negotiable
   design principles that govern every implementation decision.
2. Read `status/ST-status.md` from the repository.
3. Use it as the primary baseline for project status, recent decisions,
   open tasks, constraints, and next steps.
4. Do not assume prior chat memory is available.
5. If something is unclear or missing, say so explicitly before proceeding.