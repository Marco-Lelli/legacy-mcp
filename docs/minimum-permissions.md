# Minimum Permissions — LegacyMCP Live Mode

> This document describes the minimum set of permissions required for a service account
> to run LegacyMCP in Live Mode (Profile B-core). It covers the delegation matrix,
> the rationale for each delegation, known limitations, and the scripts that automate setup.

---

## Overview

LegacyMCP Live Mode connects to Domain Controllers via Kerberos over WinRM HTTPS.
The service account requires a specific set of delegations — no more, no less.
This document defines the certified POLP (Principle of Least Privilege) baseline.

**Prerequisites before applying delegations:**

- The service account must already exist in the domain. The scripts do not create
  accounts — use your organization's standard process and naming conventions.
- `Set-LegacyMCPPermissions.ps1` must be run as a member of **Domain Admins**
  (or equivalent). If not, the script prints the delegation table and exits with code 2.
- The target Domain Controller must be reachable from the machine running the script.

---

## Delegation Matrix

| # | Delegation | Type | Scope |
|---|---|---|---|
| 1 | Remote Management Users | Domain Local Group | AD replication — one operation |
| 2 | Event Log Readers | Domain Local Group | AD replication — one operation |
| 3 | WMI `root\MicrosoftDFS` — Execute Methods, Enable Account, Remote Enable | Local ACL (WMI namespace) | Applied on each DC individually |
| 4 | `CN=Password Settings Container,CN=System,<DomainDN>` — GenericRead, InheritanceType All | LDAP ACE | AD replication — one operation |
| 5 | `CN=MicrosoftDNS,DC=DomainDnsZones,<DomainDN>` — GenericRead | LDAP ACE | AD replication — one operation |
| 6 | `CN=MicrosoftDNS,DC=ForestDnsZones,<DomainDN>` — GenericRead | LDAP ACE | AD replication — one operation |
| 7 | `CN=MicrosoftDNS,CN=System,<DomainDN>` — GenericRead | LDAP ACE | AD replication — one operation |

AD group memberships and LDAP ACLs replicate automatically to all Domain Controllers
in the forest. WMI namespace ACLs are local to each DC and must be applied
individually — `Set-LegacyMCPPermissions.ps1` iterates over all DCs via
`Get-ADDomainController -Filter *`.

---

## Why Each Delegation

### 1. Remote Management Users

Enables WinRM access to the Domain Controller via Kerberos. Required for:

- `Invoke-Command` — used by Live Mode to run PowerShell remotely on each DC
- `Get-WindowsFeature` — DC role and feature inventory
- `Get-CimInstance` over WSMan — installed software inventory

Standard WinRM access without this group membership fails with `Access Denied`.
The group is scoped to WinRM — it does not grant interactive logon or other
elevated rights.

### 2. Event Log Readers

Grants read access to the `Application` and `System` event logs on the DC.
Required for `Get-WinEvent` in Live Mode.

The `Security` event log cannot be delegated granularly — reading it requires
local `Administrators` membership, which is deliberately not granted. LegacyMCP
does not require Security log access. See [Known Limitations](#known-limitations).

### 3. WMI `root\MicrosoftDFS`

Required to query DFSR (Distributed File System Replication) state for SYSVOL
monitoring. LegacyMCP reads `DfsrReplicatedFolderInfo` from this namespace to
determine the SYSVOL replication mechanism and health state.

The three rights granted — Execute Methods, Enable Account, Remote Enable — are
the minimum required for remote WMI queries. Full WMI control is not granted.

This ACL is local to each DC (WMI namespace security is not replicated via AD).
`Set-LegacyMCPPermissions.ps1` applies it to every DC in the forest.

### 4. CN=Password Settings Container — GenericRead, InheritanceType All

Required to enumerate Fine-Grained Password Policies (PSOs) via
`Get-ADFineGrainedPasswordPolicy`.

The Password Settings Container (`CN=Password Settings Container,CN=System`) is
protected by default — domain users cannot read PSO objects without explicit
delegation. `InheritanceType All` ensures the delegation covers the container
and all PSO child objects.

Without this delegation, `Get-ADFineGrainedPasswordPolicy` returns an empty
result set without raising an error — the omission is silent and hard to diagnose.

### 5. CN=MicrosoftDNS,DC=DomainDnsZones — GenericRead

Required to read DNS zones stored in the domain partition of Active Directory.
LegacyMCP enumerates zones and records from this partition.

In most environments, `Get-DnsServerZone` via RPC works without this delegation.
The LDAP ACE is added for robustness in environments where DNS queries are routed
directly to the LDAP partition rather than via the DNS RPC interface.

### 6. CN=MicrosoftDNS,DC=ForestDnsZones — GenericRead

Required to read DNS zones stored in the forest partition, which includes the
`_msdcs` zone (Domain Controller locator records, SRV records, GUIDs).

Same rationale as delegation 5. Both partitions are required for complete
DNS inventory.

### 7. CN=MicrosoftDNS,CN=System — GenericRead

Required for DNS queries routed through the `System` container rather than the
application partitions. Some DNS RPC paths resolve zones via this container.

Added as a defense-in-depth measure: in environments with non-standard DNS
partition configurations, the absence of this ACE may cause silent read failures
on zone enumeration.

---

## Known Limitations

These behaviors are expected and documented. They are not bugs.

### dc_services — PermissionDenied on Windows Server 2012 R2

`get_dc_services` may return `Status: PermissionDenied` on Windows Server 2012 R2.
The Service Control Manager (SCM) does not support granular delegation for remote
service enumeration on this OS version — reading the service list via
`Get-CimInstance Win32_Service` over a remote CimSession requires local
`Administrators` membership on 2012 R2.

This is a platform limitation, not a LegacyMCP bug. On Windows Server 2016 and
later, `Remote Management Users` is sufficient. The field test on 2012 R2 confirms
T18 FAIL by design (21/22 PASS).

### Security Event Log — not delegable

Reading the `Security` event log requires local `Administrators` membership.
This right is deliberately not granted. LegacyMCP does not collect Security log data.

### w32tm TimeSource — may return null

The NTP time source may return `null` or a non-descriptive string in some
configurations. This is a data availability limitation, not a permissions issue.

### NTDS paths — may return null

NTDS database and log paths may return `null` when queried without `Administrators`
rights in some configurations. Expected behavior.

---

## Scripts Reference

### Set-LegacyMCPPermissions.ps1

Applies all 7 delegations. Idempotent — safe to run multiple times.

```powershell
.\Set-LegacyMCPPermissions.ps1 -ServiceAccountName svc_legacymcp `
    -Domain contoso.local -DCHostName dc01.contoso.local
```

Exit codes: `0` all applied or already present — `1` one or more failed —
`2` not Domain Admin (no changes made).

### Remove-LegacyMCPPermissions.ps1

Revokes all 7 delegations. Idempotent. Run before decommissioning the service account.

```powershell
.\Remove-LegacyMCPPermissions.ps1 -ServiceAccountName svc_legacymcp `
    -Domain contoso.local -DCHostName dc01.contoso.local
```

Exit codes: `0` all removed or already absent — `1` one or more failed —
`2` not Domain Admin (no changes made).

### Test-LegacyMCPPermissions.ps1

Verifies that the service account has all required permissions. Run interactively
**as the service account** (not as Domain Admin) to simulate the runtime Kerberos token.

```powershell
.\Test-LegacyMCPPermissions.ps1 -DCHostName dc01.contoso.local -Domain contoso.local
```

Expected result: **21/22 PASS** — T18 (CimSession WSMan services) fails by design
on Windows Server 2012 R2. All 22 tests pass on Windows Server 2016 and later.

---

## Environment Notes

The delegation matrix and scripts have been certified on:

- **Windows Server 2012 R2** with WMF 5.1 — 21/22 PASS (T18 fail by design)

Expected to work on Windows Server 2016, 2019, 2022, and 2025 with all 22 tests
passing. Full certification on 2016+ is planned for a future release.
