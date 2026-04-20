# Security Policy

## Supported Versions

Only the latest release of LegacyMCP is actively maintained and receives security fixes.

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Use GitHub's [private vulnerability reporting](../../security/advisories/new) to submit a report. 
You will receive a response within 7 days.

## Scope

**In scope:**
- LegacyMCP server (Python)
- Collector (PowerShell)
- Installer scripts

**Out of scope:**
- The Active Directory environment where LegacyMCP is deployed
- The underlying Windows infrastructure (OS, WinRM, networking)
- Third-party dependencies (report those directly to their maintainers)

## Security Design Notes

LegacyMCP is designed with security as a core principle:
- The MCP server must never run on a Domain Controller
- Authentication uses Bearer API key over HTTPS (Profile B)
- NTLM is explicitly unsupported — Kerberos only for Live Mode
- API keys are stored using Windows DPAPI

## Known Advisories

### OX Security — MCP STDIO RCE (April 2026)

LegacyMCP is **not affected**.

This advisory targets MCP clients that accept user-supplied STDIO server
configurations. LegacyMCP is an MCP server and never accepts external server
configurations. Profile B-core uses Streamable HTTP over HTTPS with Bearer
authentication — not STDIO over the network.

### CVE-2025-6514 — mcp-remote OAuth endpoint injection (CVSS 9.6)

**Profile A**: not affected — `mcp-remote` is not used.

**Profile B-core**: addressed in commit 48df1f3.
- The `mcp-remote` client is pinned to version 0.1.38 (patched in >= 0.1.16).
- The OAuth metadata endpoint no longer derives `authorization_endpoint`
  from request input.
- Transport is HTTPS with a pinned certificate.

**Profile B-enterprise** (roadmap): not affected — `authorization_endpoint`
will point to Microsoft Entra ID, outside LegacyMCP's control surface.

**Recommended action for operators already deployed on Profile B-core**:
re-run `Setup-LegacyMCPClient.ps1` to refresh `mcp-remote-live.ps1`
with the pinned mcp-remote version, or manually update the version in
your existing `mcp-remote-live.ps1`.
