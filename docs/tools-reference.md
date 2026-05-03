# LegacyMCP -- MCP Tools Reference

Complete reference for all MCP tools exposed by the LegacyMCP server.
For setup and deployment, see [getting-started-a.md](getting-started-a.md) (Profile A) or [getting-started-b-core.md](getting-started-b-core.md) (Profile B-core).

---

## Workspace

Tools for discovering available data sources, managing the workspace, and working with snapshots.

---

### list_workspaces

Return the list of all forests available in the current workspace.

Call this tool at the start of every session to discover what data is available before running any other query. The response includes each forest name, its operating mode (live/offline), its role in the assessment, and whether its data source loaded without errors.

Use the `name` field from this response as the `forest_name` argument for any other tool that accepts it.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| *(none)* | | | | |

**Returns**

A list of forest entries, each with: `name`, `mode` (live/offline), `relation` (standalone/source/destination), `loaded` (bool), `error` (null or message). Live mode entries also include `dc` (target DC or "auto-discover").

**Example prompts**

- "What forests are available in this workspace?"
- "Is the contoso.local data loaded?"
- "List all available environments before starting the assessment."

---

### reload_workspace

Reload JSON data from disk for every forest without restarting Claude Desktop.

Use this after the PowerShell collector has produced a new JSON file and you want the server to pick up the updated data immediately. Each forest connector cache is cleared and the JSON is re-read from disk.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| *(none)* | | | | |

**Returns**

Same format as `list_workspaces`: name, mode, relation, loaded, error for each forest. A failure on one forest does not prevent the others from reloading.

**Example prompts**

- "Reload the workspace after I drop the new collector JSON."
- "Refresh the data without restarting."

---

### list_snapshots

List snapshot files available in a directory.

Reads the `_metadata` block from each JSON snapshot to report forest name, timestamp, encryption, and section count without loading the full data into memory. DPAPI-encrypted files are listed but not decrypted.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `path` | str | no | `C:\LegacyMCP-Data\snapshots\` | Directory to scan |

**Returns**

`{ snapshots: [...], total: int, path_scanned: str }`. Each snapshot entry includes: `path`, `forest`, `timestamp`, `encryption`, `sections_collected`, `size_kb`, `filename`.

**Example prompts**

- "List all available snapshots."
- "What snapshots do we have for contoso.local?"
- "List snapshots in D:\Exports\snapshots."

---

### create_snapshot

Export all available AD data for a forest to a JSON snapshot file.

The export runs in the background. This tool returns immediately with a `job_id`. Use `get_snapshot_status(job_id)` to poll progress and retrieve the output path when the job completes.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | yes | -- | Forest to snapshot (use the name from `list_workspaces`) |
| `encryption` | str | no | `"none"` | `"none"` (plaintext JSON) or `"dpapi"` (Windows DPAPI, Windows only) |
| `output_path` | str | no | auto-named under `C:\LegacyMCP-Data\snapshots\` | Full path for the output file |

**Returns**

`{ job_id: "..." }` on success. `{ status: "error", ... }` for validation failures (unknown forest, unsupported encryption).

**Example prompts**

- "Take a snapshot of contoso.local."
- "Export the current AD state to a file I can load offline."
- "Create a DPAPI-encrypted snapshot of contoso.local to C:\Exports\snap.json.dpapi."

---

### get_snapshot_status

Check the status of a snapshot job started by `create_snapshot`.

Job state is held in memory only and is lost on server restart.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `job_id` | str | yes | -- | Job identifier returned by `create_snapshot` |

**Returns**

Full job dict including: `status` (running/completed/failed), `forest_name`, `current_step`, `step_index`, `total_steps`, `file_path`, `error`, `sections_collected`, `sections_failed`, `started_at`, `completed_at`. Returns `{ status: "not_found", job_id: ... }` if the job ID is unknown.

**Example prompts**

- "Check the status of snapshot job contoso-local_20250428_143012_a1b2."
- "Is the snapshot done yet?"

---

### load_snapshot

Load a snapshot file into the workspace as a queryable forest.

After a successful load, the snapshot appears in `list_workspaces()` and can be queried with any existing tool by passing `forest_alias` as the `forest_name` argument.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `path` | str | yes | -- | Full path to the snapshot JSON file |
| `forest_alias` | str | no | derived from metadata as `<forest>@<YYYY-MM-DD>` | Name the loaded snapshot will be known as inside the workspace |
| `encryption` | str | no | `"none"` | `"none"` (plaintext JSON) or `"dpapi"` (not yet implemented in the open-source layer) |

**Returns**

`{ status: "success"/"error", forest_alias: str, sections_loaded: int, message: str }`.

**Example prompts**

- "Load the snapshot at C:\LegacyMCP-Data\snapshots\contoso_20250428.json."
- "Load the old snapshot as contoso-old so I can compare it with the live data."

---

## Forest & Domains

---

### get_forest_info

Return forest-level information: name, functional level, schema version, FSMO roles (SchemaMaster, DomainNamingMaster), sites, domains, global catalogs, SPN suffixes, UPN suffixes, application partitions, and tombstone lifetime.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |

**Returns**

A single dict with all forest-level fields.

**Example prompts**

- "What is the forest functional level of contoso.local?"
- "Show me the schema version and FSMO roles for this forest."
- "Are there any non-default UPN suffixes configured?"

---

### get_optional_features

Return the list of optional AD features and their enabled state (e.g. Recycle Bin, Privileged Access Management).

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |

**Returns**

A list of feature dicts with name and enabled state.

**Example prompts**

- "Is the AD Recycle Bin enabled in contoso.local?"
- "Which optional AD features are active?"

---

### get_domains

Return all domains in the forest with their configuration: DNS name, NetBIOS name, domain SID, functional level, FSMO role holders, allowed DNS suffixes, and machine account quota.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `200` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`.

**Example prompts**

- "List all domains in the contoso.local forest."
- "What is the domain functional level of child.contoso.local?"

---

### get_default_password_policy

Return the Default Domain Password Policy for a given domain, including minimum length, complexity, lockout thresholds, and history.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `domain` | str | no | all domains | Filter by domain DNS name |
| `forest_name` | str | no | first forest in workspace | Target forest |

**Returns**

A single dict with password policy fields, or empty dict if not found.

**Example prompts**

- "What is the default password policy for contoso.local?"
- "What is the lockout threshold configured on the domain?"

---

### get_fsmo_roles

Return the current FSMO role holders: Schema Master, Domain Naming Master, PDC Emulator, RID Master, Infrastructure Master -- per domain.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |

**Returns**

A dict with all five FSMO role holders.

**Example prompts**

- "Which DC holds the PDC Emulator role?"
- "Show me all FSMO role placements in contoso.local."
- "Is the RID Master on a healthy DC?"

---

### get_schema_extensions

Return custom schema classes and attributes added to the AD schema beyond the default Microsoft base schema. The collector caps collection at 500 objects.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `200` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`.

**Example prompts**

- "Are there any third-party schema extensions in this forest?"
- "List all custom schema classes beyond the default AD schema."

---

### get_schema_product_presence

Return schema-based product presence detection. Checks for LAPS (legacy and Windows), Exchange, SCCM/ConfigMgr, Lync/Skype for Business, and Azure AD Connect schema extensions.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |

**Returns**

A dict with boolean values for each product (`laps_legacy`, `laps_windows`, `exchange`, `sccm`, `lync`, `aad_connect`).

**Example prompts**

- "Is LAPS deployed in contoso.local?"
- "Is Azure AD Connect configured in this forest?"
- "Which Microsoft products have extended the AD schema?"

---

## Domain Controllers

---

### get_domain_controllers

Return all Domain Controllers in the forest with OS version, IP address, GC/RODC status, site, reachability state, LDAP/SSL ports, FSMO roles held, and Server Core detection.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `100` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`.

**Example prompts**

- "List all DCs in contoso.local."
- "Which DCs are running Windows Server 2012 R2?"
- "Are there any Read-Only Domain Controllers?"

---

### get_dc_features

Return installed Windows Server roles for each Domain Controller. Each item contains the DC hostname, status, and a nested list of installed roles.

Requires collector v1.6 or later.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `dc_name` | str | no | all DCs | Filter to a specific DC hostname |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `50` | Max items to return (one entry per DC) |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`. Each item has `DC`, `Status`, and `Features` (list of `{ name, display_name }`).

**Example prompts**

- "What roles are installed on DC01?"
- "Which DCs have the DNS Server role installed?"

---

### get_dc_services

Return services that are Running or have Startup Type Auto for each Domain Controller.

Requires collector v1.6 or later.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `dc_name` | str | no | all DCs | Filter to a specific DC hostname |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `50` | Max items to return (one entry per DC) |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`. Each item has `DC`, `Status`, and `Services` (list with name, status, startup type).

**Example prompts**

- "What services are running on all DCs?"
- "Are there any non-standard auto-start services on DC01?"

---

### get_dc_software

Return installed software from the registry of each Domain Controller. Registry data may include stale entries from incomplete uninstalls.

Requires collector v1.6 or later.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `dc_name` | str | no | all DCs | Filter to a specific DC hostname |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `50` | Max items to return (one entry per DC) |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`. Each item has `DC`, `Status`, and `Software` (list of `{ name, version, vendor, install_date }`).

**Example prompts**

- "What software is installed on the Domain Controllers?"
- "Is any DC running third-party antivirus software?"

---

### get_dc_file_locations

Return AD database file locations for each Domain Controller: NTDS database path, log files path, and SYSVOL path -- read from the registry via WinRM.

Note: DIT file size is not reported (requires local Administrators).

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `dc_name` | str | no | all DCs | Filter to a specific DC hostname |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `50` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`. Each item has `DC`, database path, log path, and SYSVOL path.

**Example prompts**

- "Where is the NTDS database stored on each DC?"
- "Are all DCs storing SYSVOL in the default location?"

---

### get_dc_network_config

Return network adapter configuration for each Domain Controller: IP addresses (IPv4 and IPv6), DNS server IPs, default gateway, and DHCP status -- per IP-enabled adapter.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `dc_name` | str | no | all DCs | Filter to a specific DC hostname |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `50` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`. Each item has `DC` and per-adapter network fields.

**Example prompts**

- "Are any DCs configured with DHCP instead of a static IP?"
- "What DNS servers are configured on DC01?"

---

### get_ntp_config

Return NTP configuration from the registry of each DC: NtpServer, Type, AnnounceFlags, poll intervals, VMICTimeProvider state, and current time source.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `100` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`.

**Example prompts**

- "Is the PDC Emulator configured to sync with an external NTP source?"
- "Show me the NTP configuration across all DCs."

---

### get_eventlog_config

Return EventLog configuration for each DC: log name, max size, retention, and overflow behavior. Covers all enabled logs except Security (Security log ACL not delegable without local Administrators).

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `100` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`.

**Example prompts**

- "What is the maximum size configured for the System event log on DCs?"
- "Are any DCs configured to overwrite events when the log is full?"

---

### get_sysvol_state

Return SYSVOL replication state per DC: replication mechanism (FRS or DFSR), synchronization status, and any reported errors.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `100` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`.

**Example prompts**

- "Is SYSVOL replication using FRS or DFSR?"
- "Are there any SYSVOL synchronization errors on the DCs?"
- "Has the DFSR migration been completed on all DCs?"

---

## Sites & Replication

---

### get_sites

Return all AD sites with their associated subnets and DCs.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `200` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`. Each item includes site name, subnets, and associated DCs.

**Example prompts**

- "How many sites are configured in contoso.local?"
- "Which sites have no DCs assigned?"
- "List all subnets and their associated site."

---

### get_site_links

Return all site links with cost, replication interval, schedule, and transport protocol (IP or SMTP).

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `200` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`.

**Example prompts**

- "Are there any site links using SMTP transport?"
- "What replication interval is configured between the London and Paris sites?"
- "Show me all site links with cost greater than 100."

---

## Users

---

### get_user_summary

Return user counts by state: total, enabled, disabled, locked out, password-never-expires, password-not-required, delegation configured, accounts inactive for 90+ days, accounts with no logon date, accounts with non-standard primary group, and accounts that cannot change their password.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |

**Returns**

A dict with counts and percentages for each user state category. `no_last_logon`, `primary_group_not_domain_users`, and `cannot_change_password` include sub-counts and percentages.

**Example prompts**

- "Give me a user hygiene overview for contoso.local."
- "How many accounts have passwords that never expire?"
- "What percentage of enabled users have never logged on?"

---

### get_users

Return AD user accounts with semantic filters to keep responses small on large environments.

All filters are combinable and applied in sequence. Use `get_user_summary` first for totals, then `get_users` with specific filters for focused findings.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `enabled` | bool | no | `null` (all) | `true` = enabled only, `false` = disabled only |
| `admin_count` | bool | no | `null` (all) | `true` = AdminCount=1 (SDProp-protected), `false` = without AdminCount |
| `stale_only` | bool | no | `false` | Only accounts with no logon in 90+ days or never logged on |
| `delegation_only` | bool | no | `false` | Only accounts with any Kerberos delegation configured |
| `password_never_expires` | bool | no | `null` (all) | `true` = PasswordNeverExpires set |
| `locked_out` | bool | no | `null` (all) | `true` = locked-out accounts only |
| `has_sid_history` | bool | no | `null` (all) | `true` = accounts with non-empty SIDHistory |
| `no_last_logon` | bool | no | `false` | Only accounts that have never logged on |
| `primary_group_not_domain_users` | bool | no | `false` | Only accounts with PrimaryGroupID != 513 |
| `cannot_change_password` | bool | no | `false` | Only accounts where the user cannot change their password |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `200` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`. `total` reflects the filtered count before pagination.

**Example prompts**

- "List all enabled accounts with passwords that never expire."
- "Show me stale accounts that are also members of privileged groups (admin_count=true, stale_only=true)."
- "Which enabled accounts have never logged on?"

---

### get_user_by_name

Return the full record for a single user looked up by SamAccountName.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `sam_account_name` | str | yes | -- | SamAccountName to look up |
| `forest_name` | str | no | first forest in workspace | Target forest |

**Returns**

Full user record dict, or `null` if not found.

**Example prompts**

- "Show me the full account details for jdoe."
- "Is jsmith's account enabled and when did they last log in?"

---

### get_privileged_accounts

Return accounts that are members of privileged groups (Domain Admins, Enterprise Admins, Schema Admins, Administrators).

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `200` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`.

**Example prompts**

- "Who are the Domain Admins in contoso.local?"
- "Are there any service accounts in privileged groups?"
- "Which privileged accounts have stale passwords? Cross with get_users(stale_only=true, admin_count=true)."

---

## Groups

---

### get_groups

Return AD groups with category (Security/Distribution), scope (Global/DomainLocal/Universal), and member count.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `50` | Max items to return (records are heavy -- Members field is embedded JSON) |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`.

**Example prompts**

- "How many security groups are there in contoso.local?"
- "List all Universal security groups."

---

### get_group_members

Return the direct members of a specific group. For privileged groups, prefer `get_privileged_groups` which provides recursive nested expansion.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `group_name` | str | yes | -- | Group SamAccountName or display name |
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `50` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`. Each item includes `GroupName`, `MemberSamAccountName`, `MemberDisplayName`, `MemberObjectClass`, `MemberDistinguishedName`, `MemberEnabled`.

**Example prompts**

- "Who are the members of the HelpDesk group?"
- "List all members of the VPN-Users group including their enabled status."

---

### get_privileged_groups

Return membership of privileged groups with full nested resolution: Domain Admins, Enterprise Admins, Schema Admins, Administrators, Account Operators, Backup Operators, Print Operators, Server Operators.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |

**Returns**

A list of group membership records with nested expansion.

**Example prompts**

- "Who has Domain Admin rights in contoso.local?"
- "Are there any nested groups in the Domain Admins group?"
- "List all members of Backup Operators and check if any are stale with get_users(stale_only=true)."

---

## Computers

---

### get_computer_summary

Return a summary of computer accounts: total count, enabled vs disabled, OS breakdown, stale machines (no logon in 90+ days), CNOs (Cluster Name Objects), VCOs (Virtual Computer Objects), and computers with delegation configured.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |

**Returns**

A dict with counts and an `os_breakdown` dict mapping OS name to count.

**Example prompts**

- "Give me an OS inventory for contoso.local."
- "How many stale computer accounts are there?"
- "Are there any computers with unconstrained delegation configured?"

---

### get_computers

Return AD computer accounts with OS, last logon, password age, and Kerberos delegation flags.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `enabled` | bool | no | `null` (all) | `true` = enabled only, `false` = disabled only |
| `stale_only` | bool | no | `false` | Only computers with no logon in 90+ days or never logged on |
| `delegation_only` | bool | no | `false` | Only computers with any Kerberos delegation configured |

**Returns**

A flat list of computer account records (not paginated).

**Example prompts**

- "List all enabled computers running Windows 7 or Windows XP."
- "Show me computer accounts with unconstrained delegation."
- "Which computers haven't authenticated in the last 90 days?"

---

## Organizational Units & GPO

---

### get_ous

Return the complete OU tree with distinguished names, parent OU, and whether inheritance is blocked.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `100` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`.

**Example prompts**

- "Show me the OU structure of contoso.local."
- "Which OUs have GPO inheritance blocked?"

---

### get_gpos

Return all GPOs with display name, GUID, status (enabled/disabled), and creation/modification dates.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `100` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`.

**Example prompts**

- "How many GPOs are configured in contoso.local?"
- "Are there any disabled GPOs that can be cleaned up?"
- "Which GPOs were modified in the last 30 days?"

---

### get_gpo_links

Return GPO links to OUs, sites, and the domain root, including link enabled state and enforcement.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `100` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`. One row per GPO per target OU -- complex environments can have thousands of rows.

**Example prompts**

- "Which GPOs are linked to the Domain Controllers OU?"
- "Are there any enforced GPO links?"
- "Show me all GPO links that are currently disabled."

---

### get_blocked_inheritance_ous

Return OUs with GPO inheritance blocked.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `100` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`.

**Example prompts**

- "Which OUs have GPO inheritance blocked?"
- "Are there any unexpected GPO inheritance blocks outside of the standard workstation OU?"

---

## Trusts & Security

---

### get_trusts

Return all trust relationships: type (External/Forest/Shortcut/Realm), direction (Bidirectional/Inbound/Outbound), transitivity, SID filtering, and SIDHistory state.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `200` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`.

**Example prompts**

- "What trust relationships does contoso.local have?"
- "Are there any trusts without SID filtering enabled?"
- "Is there a trust to an external Kerberos realm?"

---

### get_fgpp

Return all Fine-Grained Password Policies (PSOs) with precedence, password settings (min length, complexity, history, age), lockout settings, and the groups/users they apply to.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `200` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`.

**Example prompts**

- "Are there any Fine-Grained Password Policies configured?"
- "What password requirements apply to the Domain Admins group?"
- "Which service accounts have a custom lockout policy?"

---

### get_fsp

Return Foreign Security Principals (FSPs) from the AD forest. Orphaned FSPs (IsOrphaned=True) are principals whose SID can no longer be resolved, typically indicating a removed trust or a deleted external account.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `orphaned_only` | bool | no | `false` | If `true`, return only FSPs that could not be resolved (IsOrphaned=True) |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `200` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`.

**Example prompts**

- "Are there any orphaned Foreign Security Principals in contoso.local?"
- "List all FSPs to identify cross-domain access grants."
- "Show me orphaned FSPs that may be stale trust remnants."

---

## DNS & PKI

---

### get_dns_zones

Return DNS zones hosted on Domain Controllers: zone name, type (Primary/Secondary/Stub/Forwarder), AD-integrated flag, and replication scope.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `200` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`.

**Example prompts**

- "What DNS zones are hosted by the Domain Controllers?"
- "Are all DNS zones AD-integrated?"
- "Is there a split-DNS configuration in contoso.local?"

---

### get_dns_forwarders

Return DNS forwarder configuration per DC.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |

**Returns**

A flat list of per-DC forwarder configuration records.

**Example prompts**

- "Which DNS servers are the DCs forwarding to?"
- "Are all DCs using the same DNS forwarders?"
- "Is any DC forwarding to a public DNS resolver?"

---

### get_certification_authorities

Return Certification Authorities registered in AD (CN=Enrollment Services, CN=Public Key Services), including CA common name and Distinguished Name.

Note: detailed PKI configuration analysis is in the Enterprise layer.

**Parameters**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `forest_name` | str | no | first forest in workspace | Target forest |
| `offset` | int | no | `0` | Pagination offset |
| `limit` | int | no | `200` | Max items to return |

**Returns**

Paginated result: `{ items, total, offset, limit, has_more }`.

**Example prompts**

- "How many Certification Authorities are registered in contoso.local?"
- "What is the DN of the Enterprise CA?"
- "Is there more than one CA configured in this forest?"
