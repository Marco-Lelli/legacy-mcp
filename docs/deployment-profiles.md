# Deployment Profiles

## Overview

LegacyMCP supports four deployment profiles. The profile is declared in `config.yaml`
and determines:

- The default mode for all forests in the workspace (`live` or `offline`)
- Whether per-forest mode override is allowed
- The authentication requirements for the MCP server endpoint

The code is identical across all profiles. What changes is the configuration file
and the deployment environment.

---

## Profile A — Local

**Use case:** consultant running the MCP server on their own laptop.

| Field | Value |
|-------|-------|
| Default mode | `offline` |
| Per-forest override | not allowed |
| Auth | none (localhost only) |
| Transport | stdio |

In Profile A the MCP server runs as a local process and communicates with Claude Desktop
via stdio. There is no network exposure — the attack surface is zero.

The JSON file produced by the PowerShell collector contains sensitive AD data.
It is classified **Confidential / Restricted**. The consultant is responsible for:

- Encrypted disk (BitLocker or equivalent)
- No sync to unauthorized cloud storage (personal OneDrive, Dropbox, etc.)
- Encrypted transport if the file must be moved (not plaintext email, not unencrypted USB)
- Secure deletion at end of engagement

**Minimal `config.yaml`:**

```yaml
profile: A

workspace:
  forests:
    - name: contoso.local
      module: ad-core
      file: C:/LegacyMCP-Data/contoso.local_ad-core_20260328.json
```

No `server:` block needed in stdio mode.

---

## Profile B-core — Shared LAN

**Use case:** MCP server on a dedicated member server inside the customer network,
shared by a team of consultants.

| Field | Value |
|-------|-------|
| Default mode | `live` |
| Per-forest override | allowed |
| Auth | team API key |
| Transport | Streamable HTTP (HTTPS) |

**Architectural rule:** the MCP server must never run on a Domain Controller.
It runs on a dedicated member server with network access to the DCs on port 5986
(WinRM HTTPS). This is an architectural requirement, not a recommendation.

Per-forest override is allowed. A forest can declare `mode: offline` to load a
pre-collected JSON instead of querying live — useful for modules that do not support
live mode, or for loading historical snapshots alongside a live forest.

**`config.yaml` with mixed forest types:**

```yaml
profile: B-core

workspace:
  forests:
    - name: contoso.local
      module: ad-core
      dc: dc01.contoso.local
      credentials: gmsa

    - name: contoso.local-pki
      module: ad-pki
      mode: offline           # this module does not support live
      file: data/contoso-pki.json

    - name: contoso.local-snapshot-2025
      relation: snapshot
      module: ad-core
      mode: offline
      file: data/contoso-snapshot-20250318.json

server:
  host: 0.0.0.0   # required: bind on all interfaces for LAN access
  port: 8000
  ssl_certfile: certs/server.crt
  ssl_keyfile:  certs/server.key
```

**`server.host` note:** uvicorn binds to `127.0.0.1` by default and is not reachable
from the network without `host: 0.0.0.0`. This must be set explicitly in Profile B.
Restrict access at the firewall level. TLS is strongly recommended.

---

## Profile B-enterprise — Shared LAN with Audit

Same deployment as B-core. Adds individual identity authentication and a full
audit trail.

| Field | Value |
|-------|-------|
| Default mode | `live` |
| Per-forest override | allowed |
| Auth | per-user authenticated identity |
| Transport | Streamable HTTP (HTTPS) |

Every operation is traceable to a specific consultant identity. Required for
clients with compliance or audit requirements.

The `config.yaml` structure is identical to B-core. Authentication is configured
separately — refer to internal deployment documentation.

---

## Profile C — Remote / SaaS

**Use case:** MCP server accessible to consultants without VPN, over the internet.

| Field | Value |
|-------|-------|
| Default mode | `offline` |
| Per-forest override | not allowed |
| Auth | strong authentication — mandatory |
| Transport | Streamable HTTP (HTTPS) behind reverse proxy |

In Profile C, Live Mode is not supported. AD data is collected offline via the
PowerShell collector and uploaded to the server through LegacyMCP Portal.
The data never leaves the client network until exported as a JSON file.

Authentication is mandatory and enforced at the network layer. Refer to internal
deployment documentation for requirements.

**Minimal `config.yaml`:**

```yaml
profile: C

workspace:
  forests:
    - name: contoso.local
      module: ad-core
      file: data/contoso.json    # uploaded via LegacyMCP Portal

server:
  host: 127.0.0.1   # bind to localhost; reverse proxy terminates TLS externally
  port: 8080
```

---

## Module System

Each forest in the workspace optionally declares a `module` field identifying
the type of data it contains.

```yaml
- name: contoso.local
  module: ad-core       # optional metadata field
  file: data/contoso.json
```

### Core module

The LegacyMCP Core layer includes the `ad-core` module, covering the full AD
inventory as defined by Carl Webster's ADDS_Inventory.ps1 — queryable via natural
language through 27 MCP tools.

### Enterprise modules

Additional modules are available in the LegacyMCP Enterprise layer.
Each module is independent — no forced dependencies between modules.
A workspace can contain forests with different modules.

Each JSON includes a `_metadata` block with at minimum:
- `module` — module identifier
- `collected_at` — ISO 8601 UTC timestamp of collection
- `collector_version` — version of the collector that produced the file

### Live Mode support

Each module defines in its own documentation whether it supports `mode: live`
in Profile B. The `ad-core` module supports live. Other modules define support
case by case.

---

## Snapshots as a Bridge Between Profiles

Snapshots produced in Profile B can be reused in Profile A and Profile C.

**Profile B → Profile A:**
Export a snapshot from a live workspace. Load it in Profile A for local
consultation or temporal comparison against a previous assessment.

```yaml
# Profile A workspace loading a snapshot from a Profile B session
profile: A

workspace:
  forests:
    - name: contoso.local-live
      module: ad-core
      file: data/contoso-live-20260328.json

    - name: contoso.local-prev
      relation: snapshot
      module: ad-core
      file: data/contoso-prev-20250318.json
```

**Profile B → Profile C:**
The snapshot is the transport format toward the Portal in Profile C.
The JSON produced by the live assessment in Profile B is uploaded to Portal
and made available to the Profile C workspace.

A snapshot is a JSON in the same format as the offline collector output.
It is loadable in any offline workspace regardless of the profile that produced it.

---

## config.yaml Reference

| Field | Scope | Allowed values | Default | Notes |
|-------|-------|----------------|---------|-------|
| `profile` | global | `A`, `B-core`, `B-enterprise`, `C` | `A` | Replaces `mode` |
| `mode` | global | `live`, `offline` | — | Deprecated since v0.1.4 — use `profile` |
| `server.host` | server | any IP / `0.0.0.0` | `127.0.0.1` | Set `0.0.0.0` for Profile B |
| `server.port` | server | integer | `8000` | — |
| `server.snapshot_path` | server | directory path | `C:\LegacyMCP-Data\snapshots\` | Default output dir for `create_snapshot` when `output_path` is not specified |
| `server.ssl_certfile` | server | file path | — | Both or neither with ssl_keyfile |
| `server.ssl_keyfile` | server | file path | — | Both or neither with ssl_certfile |
| `forest.module` | per forest | free string | — | Optional metadata, e.g. `ad-core` |
| `forest.mode` | per forest | `live`, `offline` | inherited | Override only in B-core / B-enterprise |
| `forest.relation` | per forest | `standalone`, `source`, `dest`, `trusted`, `snapshot` | `standalone` | — |
| `forest.file` | per forest | file path | — | Required in offline mode |
| `forest.dc` | per forest | hostname / FQDN | — | Required in live mode |
| `forest.credentials` | per forest | `gmsa`, `env` | `gmsa` | `env` reads LEGACYMCP_AD_USER / LEGACYMCP_AD_PASSWORD |
| `forest.timeout_seconds` | per forest | integer | `30` | WinRM operation timeout |
