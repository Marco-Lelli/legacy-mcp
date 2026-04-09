# LegacyMCP — Architecture

## Overview

LegacyMCP is a Model Context Protocol (MCP) server that exposes Active Directory
data as tools queryable by Claude and other LLMs.

```
Claude Desktop / MCP Client
        │
        │ MCP protocol (stdio / HTTP)
        ▼
  ┌─────────────┐
  │  server.py  │  FastMCP entrypoint — registers all tools
  └──────┬──────┘
         │
  ┌──────▼──────┐
  │  tools/     │  One module per AD area (forest, dcs, users, ...)
  └──────┬──────┘
         │
  ┌──────▼──────────────────────────────┐
  │           Workspace                  │
  │  (mode, forest list, connectors)     │
  └──────┬──────────────┬───────────────┘
         │              │
  ┌──────▼──────┐  ┌────▼────────┐
  │ Offline     │  │  Live       │
  │ Connector   │  │  Connector  │
  └──────┬──────┘  └────┬────────┘
         │              │
  ┌──────▼──────┐  ┌────▼────────────────┐
  │ JSON → SQLite│  │ WinRM → PowerShell  │
  │ (storage/)  │  │ → Domain Controller │
  └─────────────┘  └─────────────────────┘
```

## Key Design Decisions

### Read-only — always
No tool in the Core layer writes to AD. This is an architectural constraint,
not a configuration option.

### Mode separation
Offline and Live connectors implement the same interface (`query`, `scalar`).
Tools do not know which mode is active — they call `workspace.connector(forest_name)`.

### Multi-scope workspace
A single MCP server instance can hold connectors for multiple forests simultaneously.
Each tool accepts an optional `forest_name` parameter; if omitted, the first forest is used.

### Graceful degradation
DC-level failures (WinRM timeouts, unreachable hosts) are caught per-DC.
Partial data is returned with a status field. Failures are logged to the dedicated EventLog.

### JSON as transport, SQLite as engine
The collector exports a single JSON file per forest.
The MCP server ingests it into in-memory SQLite for efficient filtering.
SQLite is never exposed to the caller — it is an internal implementation detail.

## Deployment Profiles

| Profile | Mode    | Network        | Auth                     |
|---------|---------|----------------|--------------------------|
| A       | Offline | None           | Local API key / localhost |
| B       | Live    | Internal LAN   | gMSA + HTTPS             |
| C       | Offline | Internet       | WAF + OAuth2 + MFA       |

## Component Map

```
src/legacy_mcp/
├── server.py           MCP server entrypoint
├── config.py           YAML config loader + validation
├── auth.py             ASGI middleware — API key validation (Profile B)
├── oauth.py            OAuth 2.0 stub — discovery, PKCE, client_credentials
├── workspace/          Scope and connector management
├── modes/
│   ├── live.py         WinRM + PowerShell execution
│   └── offline.py      JSON file loading
├── storage/
│   ├── loader.py       JSON → SQLite ingestion
│   └── queries.py      SQLite query helpers
├── tools/              MCP tool registration (one file per AD area)
├── eventlog/           Windows EventLog writer (dedicated log)
└── service/            Windows Service wrapper

collector/
├── Collect-ADData.ps1  PowerShell offline data collector (main script)
└── modules/            PS helper modules per AD area
```
