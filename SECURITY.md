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
