================================================================================
  Collect-ADData.ps1
  LegacyMCP Offline Collector - Active Directory Data Export
  Version 1.5 - March 2026
  Marco Lelli, Impresoft 4ward
================================================================================

SYNOPSIS
--------
  Exports Active Directory configuration data to a structured JSON file
  for offline analysis with LegacyMCP.

  Read-only. No changes are made to the Active Directory environment.


DESCRIPTION
-----------
  Collect-ADData.ps1 collects a comprehensive inventory of an Active Directory
  forest or domain and exports it as a single JSON file. The JSON file is then
  loaded by the LegacyMCP MCP server for analysis with Claude.

  This offline workflow is designed for consultants working remotely or via
  desktop sharing: the script runs in the customer's environment, the JSON
  is exported and brought to the consultant's workstation for analysis.
  No network access to the customer environment is required during analysis.

  The script runs against a single domain. For multi-domain forests, run the
  script once per domain (or once with Enterprise Admin rights to collect
  forest-wide data automatically).

  Collected sections:
    - Forest info, functional levels, schema version, optional features
    - Schema extensions (custom attributes and classes)
    - Domains, default password policies
    - Domain Controllers, FSMO roles
    - EventLog configuration per DC (Application, System, Security)
    - NTP configuration per DC (server, type, advanced W32Time registry keys)
    - SYSVOL replication state (DFSR) per DC
    - Sites and site links
    - Users (with UPN, DN, mail, adminCount, last logon, password info)
    - Privileged accounts (Domain Admins, Enterprise Admins, Schema Admins, etc.)
    - Groups (with DN, adminCount, member count)
    - Privileged group memberships (recursive)
    - Organizational Units, blocked inheritance, GPO links
    - GPO inventory and GPO links
    - Trust relationships
    - Fine-Grained Password Policies
    - DNS zones and forwarders
    - Computer objects (OS, last logon, CNO/VCO detection)
    - PKI / Certification Authority discovery

  DC reachability: if a Domain Controller cannot be contacted for registry-based
  queries (NTP, EventLog), the script records the failure and continues. The
  output JSON marks unreachable DCs explicitly so the analyst knows which data
  is complete and which is partial.


REQUIREMENTS
------------

  PowerShell version:
    Minimum: PowerShell 5.1 (Windows Management Framework 5.1)
    Recommended: PowerShell 5.1 or 7.x

  Modules required:
    ActiveDirectory  — included in RSAT or available on Domain Controllers
    GroupPolicy      — required for GPO inventory (Get-GPO, Get-GPInheritance)
                       included in RSAT Group Policy Management Tools

  RSAT installation (Windows 10 / Windows 11):
    Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
    Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0

  The script does NOT need to run on a Domain Controller.
  It can run from any domain-joined workstation with RSAT installed.

  Elevated session: the script should be run from an elevated PowerShell session
  (Run as Administrator) to ensure remote registry access for NTP and EventLog
  configuration queries.


REQUIRED RIGHTS
---------------

  Minimum — single domain inventory:
    Domain Admin (or delegated read access to all AD objects in the domain)

    Note: without Domain Admin, some sections may return incomplete data.
    Users with unusual ACLs may not be enumerable. NTP and EventLog registry
    queries require at minimum remote registry access on each DC, which
    typically requires Domain Admin.

  Recommended — full forest inventory:
    Enterprise Admin

    Enterprise Admin rights are required to enumerate all domains in the forest
    and to query forest-wide configuration (forest-level optional features,
    cross-domain privileged group memberships, trust relationships between
    domains in different trees).

  gMSA (Group Managed Service Account):
    If running LegacyMCP as a Windows service in Live Mode, a gMSA is the
    recommended account type. The gMSA must be a member of Domain Admins
    (or equivalent delegated group) on each domain in scope.


PARAMETERS
----------

  -OutputPath <string>
      Path to the output JSON file.
      Default: .\<forest>_ad-data.json  (e.g. contoso.local_ad-data.json)
      The forest name is resolved at runtime from the target environment.

      BREAKING CHANGE from v1.4: the default filename is now <forest>_ad-data.json
      instead of ad-data.json. Callers using -OutputPath explicitly are not affected.

      A companion log file is written to the same directory with the same stem
      and a .log extension (e.g. contoso.local_ad-data.log). The log contains
      one timestamped entry per section with counts, and per-section duration
      timings when -Verbose is active.

      If the file already exists, it is renamed with a timestamp suffix
      (e.g. contoso.local_ad-data_backup_20260329_143022.json) before the new
      export is written. The original data is never silently overwritten.
      Use a dedicated folder to keep exports organized by customer and date.

  -Server <string>
      FQDN or NetBIOS name of the Domain Controller to query.
      If omitted, PowerShell auto-discovers the closest DC for the current
      user's domain.

      Use this parameter to target a specific DC, or when running the script
      from a workstation not joined to the target domain (e.g., over VPN
      with explicit DC targeting).

  -Credential <PSCredential>
      Credentials to use for all AD queries.
      If omitted, the script uses the current user context (recommended when
      running as a domain user with appropriate rights, or as a gMSA).

      To build a credential object interactively:
          $cred = Get-Credential


EXAMPLES
--------

  --- Basic usage: current user, auto DC discovery ---

      .\Collect-ADData.ps1

      Runs against the current user's domain. Output saved to
      .\<forest>_ad-data.json (e.g. contoso.local_ad-data.json).
      Log saved alongside as contoso.local_ad-data.log.


  --- Basic usage with verbose timing ---

      .\Collect-ADData.ps1 -Verbose

      Same as above, but adds per-section duration timings to both the console
      and the log file. Useful for diagnosing slow sections (e.g. group_members
      in large environments).


  --- Specify output path ---

      .\Collect-ADData.ps1 -OutputPath C:\Export\contoso-$(Get-Date -Format yyyyMMdd).json

      Saves the output to C:\Export\ with a date-stamped filename.
      Recommended for keeping multiple exports organized.


  --- Target a specific Domain Controller ---

      .\Collect-ADData.ps1 -Server dc01.contoso.local -OutputPath C:\Export\contoso.json

      Useful when auto-discovery selects an unexpected DC, or when collecting
      data from a specific site's DC.


  --- Alternate credentials (single domain) ---

      $cred = Get-Credential contoso\svc-legacymcp
      .\Collect-ADData.ps1 -Credential $cred -OutputPath C:\Export\contoso.json

      Use when running from a workstation not joined to the target domain,
      or when the current user does not have the required rights.


  --- Full forest collection (Enterprise Admin) ---

      $cred = Get-Credential contoso\enterprise-admin
      .\Collect-ADData.ps1 -Server dc01.contoso.local `
          -Credential $cred `
          -OutputPath C:\Export\contoso-forest-$(Get-Date -Format yyyyMMdd).json

      Collects forest-wide data including all domains, cross-domain trust
      relationships, and forest-level optional features.
      Recommended for full AD assessments.


  --- Child domain only (no Enterprise Admin) ---

      $cred = Get-Credential child\domain-admin
      .\Collect-ADData.ps1 -Server dc01.child.contoso.local `
          -Credential $cred `
          -OutputPath C:\Export\child-domain.json

      Scope is limited to the child domain. Forest-level sections (forest
      optional features, cross-forest trusts) will reflect what is visible
      from the child domain's context.


  --- Multi-domain forest: one export per domain ---

      # Forest root
      .\Collect-ADData.ps1 -Server dc01.contoso.local `
          -OutputPath C:\Export\contoso-root.json

      # Child domain
      .\Collect-ADData.ps1 -Server dc01.child.contoso.local `
          -OutputPath C:\Export\contoso-child.json

      Load both JSON files into LegacyMCP with multi-scope workspace
      configuration for cross-domain analysis.


  --- Impresoft 4ward: standard assessment export ---

      $customer = "ClienteXYZ"
      $date     = Get-Date -Format "yyyyMMdd"
      $cred     = Get-Credential

      .\Collect-ADData.ps1 `
          -Server dc01.clientexyz.local `
          -Credential $cred `
          -OutputPath "C:\Impresoft\Assessments\$customer\ad-data-$date.json"

      Recommended naming convention for multi-customer environments.


DATA STORAGE
------------

  Store JSON output files in a dedicated folder OUTSIDE the repository.
  AD data is sensitive — it must never be committed to GitHub.

  Recommended base path:   C:\LegacyMCP-Data\

  Naming convention:
    <domainname>-data.json                    plain export
    <domainname>-data-<yyyyMMdd>.json         date-stamped (recommended)

  Examples:
    C:\LegacyMCP-Data\contoso.local-data-20250317.json
    C:\LegacyMCP-Data\child.contoso.local-data-20250317.json
    C:\LegacyMCP-Data\fabrikam.local-data-20250317.json

  WHY THIS MATTERS
  The JSON file contains the full AD inventory: user accounts, group
  memberships, password policies, trust relationships, PKI topology.
  This is exactly the data an attacker needs to map an environment.

  Rules:
    - Never save JSON files inside the repository working directory.
    - Never commit JSON files to git (add *.json to .gitignore if needed).
    - Never send JSON files via unencrypted channels (email, Teams chat).
    - Treat JSON files with the same classification as the customer's
      Active Directory backup — typically Confidential or Restricted.
    - Delete files when no longer needed for the assessment.

  The repository already includes C:\LegacyMCP-Data\ in .gitignore.
  If using a custom path, add it manually.


OUTPUT FORMAT
-------------

  The script produces a single UTF-8 JSON file.

  Top-level keys in the JSON:
    forest, optional_features, schema, domains, default_password_policy,
    dcs, fsmo_roles, eventlog_config, ntp_config, sysvol, sites, site_links,
    users, privileged_accounts, groups, privileged_groups, group_members,
    ous, gpos, gpo_links, blocked_inheritance, trusts, fgpp, dns,
    dns_forwarders, computers, pki

  Sections that fail entirely (e.g., GPO cmdlets not available) are recorded
  as null with a warning printed to the console. The JSON remains valid and
  loadable by LegacyMCP — missing sections are handled gracefully.

  Typical file size:
    Small domain  (< 500 objects):   1–5 MB
    Medium domain (500–5000 objects): 5–30 MB
    Large domain  (> 5000 objects):  30 MB+

  Users are capped at 5,000 objects. Computer objects are capped at 10,000.
  Adjust the limits in the script if the environment exceeds these thresholds.

  Fields per section (selected):

  users
    SamAccountName, DisplayName, UserPrincipalName, DistinguishedName,
    Mail, Enabled, PasswordNeverExpires, LockedOut, LastLogonDate,
    PasswordLastSet, Description, AdminCount,
    TrustedForDelegation, TrustedToAuthForDelegation, AllowedToDelegateTo

  computers
    Name, DistinguishedName, OperatingSystem, OperatingSystemVersion,
    Enabled, LastLogonDate, PasswordLastSet, Description,
    IsCNO, IsVCO,
    TrustedForDelegation, TrustedToAuthForDelegation, AllowedToDelegateTo

  group_members
    GroupName, MemberSamAccountName, MemberDisplayName,
    MemberObjectClass, MemberDistinguishedName, MemberEnabled
    One row per direct member per group. MemberEnabled is null for
    nested group members (objectClass = group). Groups with no members
    produce no rows.

  gpo_links
    DisplayName, GpoId, Enabled, Enforced, Target, Order
    One row per GPO link per target container (domain root or OU).
    The same GPO linked to multiple OUs appears as multiple rows,
    each with its own Target field.

  eventlog_config (per DC, per log)
    DC, LogName, MaxSizeBytes, OverflowAction
    Note: OverflowAction maps to LogMode values: Circular, Retain,
    AutoBackup. There is no RetentionDays equivalent in the
    Get-WinEvent API.


MULTI-FOREST CONFIGURATION
--------------------------

  When the assessment scope spans multiple forests or multiple standalone
  domains, load all JSON files into LegacyMCP via the workspace section
  of config.yaml. The MCP server merges them into a single SQLite database,
  tagging every object with its source domain for cross-domain queries.

  --- Scenario A: multiple standalone forests (independent customers or BUs) ---

  Each forest is treated as an independent scope. LegacyMCP loads all files
  but does not infer any relationship between them.

      workspace:
        forests:
          - name: contoso.local
            relation: standalone
            module: ad-core
            file: C:\LegacyMCP-Data\contoso.local-data-20250317.json
          - name: fabrikam.local
            relation: standalone
            module: ad-core
            file: C:\LegacyMCP-Data\fabrikam.local-data-20250317.json
          - name: tailspin.local
            relation: standalone
            module: ad-core
            file: C:\LegacyMCP-Data\tailspin.local-data-20250317.json

  Use this when auditing multiple unrelated environments in a single session.
  Claude can compare them but LegacyMCP will not generate migration findings.


  --- Scenario B: migration — source forest and destination forest ---

  Mark one forest as source and one as destination. LegacyMCP enables
  migration-specific queries: objects present in source but not in destination,
  naming conflicts, SIDHistory mapping for already-migrated accounts.

      workspace:
        forests:
          - name: contoso.local
            relation: source
            module: ad-core
            file: C:\LegacyMCP-Data\contoso.local-data-20250317.json
          - name: corp.fabrikam.com
            relation: dest
            module: ad-core
            file: C:\LegacyMCP-Data\corp.fabrikam.com-data-20250317.json

  Mark one forest as relation: source and one as relation: dest.
  LegacyMCP surfaces comparative findings:
    - Users in source without a match in destination
    - Groups with no equivalent in the target
    - SIDHistory entries for already-migrated principals
    - UPN / SAMAccountName conflicts between the two environments


  --- Scenario C: multi-domain forest (one export per domain) ---

  Run the collector once per domain (see EXAMPLES above) and list all
  resulting files under the same forest entry. Use this when Enterprise
  Admin rights were not available and each domain was collected separately.

      workspace:
        forests:
          - name: contoso.local
            relation: standalone
            module: ad-core
            file: C:\LegacyMCP-Data\contoso.local-data-20250317.json
          - name: child.contoso.local
            relation: standalone
            module: ad-core
            file: C:\LegacyMCP-Data\child.contoso.local-data-20250317.json
          - name: eu.contoso.local
            relation: standalone
            module: ad-core
            file: C:\LegacyMCP-Data\eu.contoso.local-data-20250317.json


NOTES
-----

  - NTP and EventLog registry queries connect to each DC individually.
    DCs that are unreachable or have remote registry disabled will be marked
    with null values and a Status field set to "Unreachable" in the output.
    Collection continues on remaining DCs.

  - SYSVOL replication state is queried via WMI (root\MicrosoftDFS).
    Environments still using FRS (File Replication Service) instead of DFSR
    will return "Unknown" for SYSVOL state. FRS migration to DFSR is strongly
    recommended on any domain functional level below Windows Server 2008 R2.

  - GPO sections require the GroupPolicy module. If the module is not
    available, GPO inventory is skipped with a warning. Install RSAT Group
    Policy Management Tools to enable this section.

  - The script does NOT collect DHCP, PKI configuration, or GPO content
    analysis. These are covered by the LegacyMCP Enterprise layer.

  - The JSON output file may contain sensitive information (user accounts,
    group memberships, password policy settings). Handle it according to
    your organization's data classification policy and the customer's
    confidentiality requirements.

  - The script file is ASCII-only. No extended UTF-8 characters (em dashes,
    curly quotes, or any codepoint above U+007F) are used in the source.
    Reason: PowerShell on Windows reads files without a UTF-8 BOM using the
    system ANSI code page (CP1252). Multi-byte UTF-8 sequences are
    misinterpreted as separate characters, which can corrupt string literals
    and cause hard-to-diagnose parse errors. Keep the file ASCII-only when
    editing.


VERSION HISTORY
---------------

  v1.5 - March 2026
    - BREAKING CHANGE: default output filename is now <forest>_ad-data.json
      (e.g. contoso.local_ad-data.json) instead of ad-data.json. Callers
      using -OutputPath explicitly are not affected.
    - Added companion log file: written alongside the JSON with the same stem
      and a .log extension. Contains one timestamped entry per section with
      counts. With -Verbose, includes per-section duration timings.
    - Added Write-CollectorLog function: uniform logging to file and console
      with levels INFO (green), WARN, ERROR (non-terminating), VERBOSE.
      Increments session counters $script:sectionsOK, sectionsWarn,
      sectionsError.
    - Added session header and footer to the log file: forest name, DC,
      output and log paths, start/end timestamps, duration, and section
      summary (OK/Warn/Error counts).
    - Added collection_summary to _metadata in the output JSON: fields
      sections_ok, sections_warn, sections_error, log_file. Allows
      LegacyMCP to surface collection completeness in tool responses.
    - Per-section duration measurement via System.Diagnostics.Stopwatch.
    - Confirmed [CmdletBinding()] present -- -Verbose works as a native switch.

  v1.4 - March 2026
    - Added _metadata block as the first key of the output JSON. Fields:
      module ("ad-core"), version ("1.0"), forest (forest name), collected_at
      (UTC ISO 8601), collector_version ("1.4"), collected_by (DOMAIN\username).
    - Format is identical to the _metadata produced by LegacyMCP Live Mode
      snapshots, enabling interoperability between offline and live workflows.
    - Fixed silent failure in export section: all four export blocks (pre-check,
      build metadata, write file, post-check) are now wrapped in explicit
      try/catch with Write-Status reporting and descriptive throw messages.
      Previously a failure in any block would terminate the script without
      a clear error message due to $ErrorActionPreference = "Stop".

  v1.3 - March 2026
    - Pre-check: if the output file already exists, it is renamed with a
      timestamp suffix (e.g. ad-data_20260327_143000.json) before the new
      export is written. Prevents silent overwrite of previous exports.
    - Export uses -NoClobber to enforce that the rename happened correctly.
    - Post-check: after writing, the output file is read back and parsed as
      JSON to verify integrity. If validation fails, the corrupt file is
      renamed to *_corrupt.json and an exception is thrown.

  v1.2 - March 2025
    - Added group_members section: flat table with one row per direct
      member per group. Fields: GroupName, MemberSamAccountName,
      MemberDisplayName, MemberObjectClass, MemberDistinguishedName,
      MemberEnabled. MemberEnabled is resolved via Get-ADUser /
      Get-ADComputer and is null for nested group members. Handles
      LDAP range retrieval for large groups via Get-ADGroupMember.
    - Fixed gpo_links collection: now iterates all OUs with
      Get-GPInheritance instead of domain root only. Returns all GPO
      links across the entire domain, one row per link per target OU.
      Previously only links on the domain root were collected.

  v1.1 - March 2025
    - Fixed EventLog collection: removed RetentionDays field (property
      does not exist on EventLogConfiguration objects). OverflowAction
      now correctly maps to LogMode (Circular/Retain/AutoBackup).
    - Fixed schema extensions filter: OID-based exclusion of Microsoft
      base schema and Exchange objects. governsID and attributeID added
      to output. Limit raised from 200 to 500.
    - Fixed MemberCount for large groups: replaced $_.Members.Count with
      Get-ADGroupMember, which handles LDAP range retrieval transparently.
      Groups with membership exceeding MaxPageSize (~1500) now return the
      correct count instead of 0.
    - Added Kerberos delegation fields to users and computers:
      TrustedForDelegation, TrustedToAuthForDelegation,
      AllowedToDelegateTo (msDS-AllowedToDelegateTo).

  v1.0 - March 2025
    Initial release.


================================================================================
  LegacyMCP — https://github.com/Marco-Lelli/legacy-mcp
  Impresoft 4ward — https://www.4ward.it/
  Legacy Things — https://legacythings.it
================================================================================
