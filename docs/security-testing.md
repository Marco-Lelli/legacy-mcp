# Security Testing

## Overview

LegacyMCP handles sensitive Active Directory data and connects to critical
infrastructure. The collector exports full AD inventories — user accounts,
group memberships, password policies, trust relationships, PKI topology —
and the MCP server exposes that data to an AI model via tool calls.
This document describes the public security testing plan for the project:
what is tested, at a high level, and how findings will be handled.
Detailed operational procedures, test platforms, and internal runbooks are
kept outside the public repository.

---

## Scope

### MCP Server

- Injection in tool parameters — crafted `forest_name`, `group_name`,
  `sam_account_name` values passed to SQL queries or shell commands
- Authentication and authorisation for deployment profiles B and C —
  API key validation, OAuth2/OIDC token verification, missing or malformed
  credentials
- Rate limiting and resilience to bulk calls — rapid sequential tool
  invocations, large result sets, parallel requests
- Information disclosure in errors — stack traces, internal paths, or
  sensitive data exposed in exception messages returned to the client

### PowerShell Collector

- JSON output integrity — verifying the exported file accurately reflects
  AD state and has not been tampered with in transit
- Authenticode signature verification before execution — ensuring the
  script has not been modified after signing
- Behaviour with insufficient permissions — graceful degradation when the
  running account lacks Domain Admin or remote registry rights; no
  credential exposure in error output

### File JSON

- Loading malformed or manipulated files — truncated JSON, unexpected
  encoding, oversized field values, missing required sections
- SQL injection via JSON values into SQLite — field values containing SQL
  metacharacters passed through `_create_and_insert` and `QueryEngine.query`
- Memory exhaustion with large files — domains with 5000+ users or 10000+
  computers loaded into the in-memory SQLite database

### Deployment Profiles

- **Profile A — localhost (Offline Mode):** attack surface limited to the
  local filesystem; verify no network listener is opened, config file
  permissions, JSON file access controls
- **Profile B — LAN endpoint (Live Mode):** TLS certificate validation,
  API key strength and transmission, absence of plaintext credential
  logging, WinRM channel security
- **Profile C — internet-exposed endpoint:** WAF rule coverage, OAuth2/OIDC
  token validation, MFA enforcement, IP allowlist effectiveness, rate
  limiting under external load

---

## Testing Approach

Security testing is performed progressively as the platform matures,
starting from local and offline scenarios, then extending to live internal
deployments, and finally to internet-exposed enterprise scenarios.
Detailed test cases, tooling choices, execution sequences, and internal test
infrastructure are maintained in a private runbook outside the public repo.

Testing covers validation, robustness, authentication, transport security,
error handling, and safe degradation across the supported deployment
profiles.

---

## Test Results

*Results will be added as testing is performed against stable releases.*

---

## Responsible Disclosure

If you find a vulnerability in LegacyMCP, please contact Marco Lelli
privately before public disclosure to allow time for a fix to be prepared
and released.

- GitHub: [github.com/Marco-Lelli](https://github.com/Marco-Lelli)
- Project: [github.com/Marco-Lelli/legacy-mcp](https://github.com/Marco-Lelli/legacy-mcp)
- Blog: [legacythings.it](https://legacythings.it)
