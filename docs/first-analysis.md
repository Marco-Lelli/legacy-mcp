# First Collection and Analysis

> This guide walks through a first real assessment end to end: running the
> collector, loading the data into LegacyMCP, and asking Claude for an
> analysis. It assumes Profile A (Offline Mode) is already installed — see
> [Getting Started — Profile A](getting-started-a.md) if not.
>
> For Profile B-core (LAN endpoint, no manual collector step), see
> [Getting Started — Profile B-core](getting-started-b-core.md).

---

## Core concepts

**Workspace.** The set of Active Directory environments currently loaded
into LegacyMCP, declared under `workspace:` in `config.yaml`. Each entry is
a **forest** — a name, a module (`ad-core` for the standard inventory), and
either a JSON file (Offline Mode) or a target DC (Live Mode). Claude queries
whatever forests are in the workspace; nothing is collected or connected to
automatically.

**Offline Mode vs. Live Mode.** Offline Mode reads a JSON file produced
ahead of time by the PowerShell collector — no persistent network access to
the customer environment during analysis. Live Mode connects directly to a
Domain Controller over WinRM in real time (Profile B-core only). This guide
covers the Offline Mode path, which is what Profile A uses.

**`Manage-Workspaces.ps1`.** The tool that adds, removes, lists, and
validates forests in `config.yaml` without hand-editing YAML. It lives in
`installer\` and is what you use after the collector has produced a JSON
file, to make LegacyMCP aware of it.

---

## Path A — Offline (collector + local analysis)

### 1. Run the collector

On a domain-joined workstation or server with RSAT installed (does **not**
need to be a Domain Controller):

1. Copy the `collector\` folder to that machine.
2. Open an **elevated** PowerShell session (Run as Administrator) — see
   the elevation note below for why this matters.
3. Run:

```powershell
.\Collect-ADData.ps1 -OutputPath "$env:USERPROFILE\Documents\LegacyMCP-Data\contoso.local_ad-data.json"
```

Minimum required rights: a delegated account following the POLP model is
enough — see [Minimum Permissions](minimum-permissions.md) for the full
matrix (certified in the field: 21/22 PASS). Domain Admin / Enterprise Admin
also works and is the simpler fallback for a first run.

How long it takes depends on the size of the domain — there is no fixed
number. Add `-Verbose` to see per-section timing in the console and in the
companion log file, and to get a sense of which sections dominate the run
time on a given environment.

The script writes one JSON file (default name `<forest>_ad-data.json`, e.g.
`contoso.local_ad-data.json`) and a companion `.log` file with one
timestamped entry per section. See the OUTPUT FORMAT section in
`collector\README.txt` for the full list of top-level keys.

> **Store the JSON outside the repository, in a dedicated folder** —
> `%USERPROFILE%\Documents\LegacyMCP-Data\` is the recommended convention.
> AD exports are sensitive data and must never be committed to Git. See the
> DATA STORAGE section in `collector\README.txt`.

### 2. If the elevation warning appears

The collector checks this up front and, if the session is not elevated,
prints a warning and continues anyway — it does not stop the collection.
In some AD environments, a non-elevated session cannot read
`userAccountControl`, which silently empties `Enabled`, `PasswordNeverExpires`,
and the Kerberos delegation fields for every user, even when the account
running the collector has adequate AD permissions.

If you see this warning, the safest move for a first collection is to close
the window and re-run Step 1 from an elevated session, rather than analyze
a file that may have those fields blanked out. If you already have a JSON
file collected non-elevated and are seeing an unusual number of `null`
values on those specific fields, that is the likely cause — see
[Troubleshooting](#troubleshooting) below.

### 3. Load the JSON as a workspace

Transfer the JSON file to the machine where LegacyMCP is installed (may be
the same machine), then, from the `installer\` folder:

```powershell
.\Manage-Workspaces.ps1 -Add -Name "contoso.local" -File "C:\Users\<username>\Documents\LegacyMCP-Data\contoso.local_ad-data.json"
```

`-Name` is the label LegacyMCP and Claude will use to refer to this
environment — it does not need to match the forest name exactly, but doing
so avoids confusion. `-File` is the path to the JSON produced in Step 1.
No `-Config` argument is needed for a standard single-install Profile A
setup — the script finds `config.yaml` automatically via the registry.

Restart Claude Desktop after adding a workspace, so the server picks up
the change.

### 4. Verify the workspace is visible

Open a new Claude conversation and ask:

```
What environments do you have available?
```

Claude calls `list_workspaces()` and should list `contoso.local` (or
whatever name you chose) with `mode: offline`. If it does not appear, see
[Troubleshooting](#troubleshooting).

---

## Path B-core — quick note

Profile B-core skips Steps 1–3 above entirely: there is no collector to run
and no JSON to move around. The server connects live to a Domain Controller,
and workspaces are added by DC instead of by file:

```powershell
.\Manage-Workspaces.ps1 -Add -Name contoso.local -DC dc01.contoso.local
```

Everything else — Claude Desktop, example prompts, the MCP tools themselves
— works identically regardless of mode. See
[Getting Started — Profile B-core](getting-started-b-core.md) for the full
server/client setup.

---

## Example prompts for your first analysis

Once the workspace is loaded, these are realistic starting points —
each maps to a specific MCP tool, not a made-up capability:

**Domain Controller inventory:**
```
Give me an inventory of all Domain Controllers in contoso.local — OS
versions, FSMO roles, and Global Catalog status.
```
Calls `get_domain_controllers`.

**Privileged accounts:**
```
Who are the members of Domain Admins, Enterprise Admins, and the other
privileged groups in contoso.local? Flag anything that looks like a
personal account rather than a dedicated admin account.
```
Calls `get_privileged_accounts` (and `get_users` for follow-up detail on
specific accounts).

**SIDHistory (migration remnants):**
```
Are there any user accounts with SIDHistory set in contoso.local? This
usually indicates accounts migrated from another domain that were never
cleaned up.
```
Calls `get_users` with `has_sid_history=true`.

For a broader hygiene overview before drilling into specifics, start with
`get_user_summary` and `get_computer_summary` — see
[MCP Tools Reference](tools-reference.md) for the complete list of tools
and parameters.

> For tips on keeping a session efficient (splitting collection from
> analysis, avoiding the per-turn tool-call limit), see
> [Getting Started — Assessment session tips](getting-started.md#assessment-session-tips).

---

## Troubleshooting

**Many fields come back `null` (Enabled, PasswordNeverExpires, delegation
fields) for users**
The collector session that produced this JSON was very likely not elevated
— see [step 2](#2-if-the-elevation-warning-appears) above. Re-run the
collector from an elevated PowerShell session, then replace the workspace
entry — `-Add` rejects a name that already exists, so remove it first:

```powershell
.\Manage-Workspaces.ps1 -Remove -Name "contoso.local"
.\Manage-Workspaces.ps1 -Add -Name "contoso.local" -File "C:\path\to\the\new\file.json"
```

**Added a workspace but Claude still doesn't see it**
Restart Claude Desktop completely (quit from the system tray, not just
close the window) — the server only reads `config.yaml` at startup. If it
still doesn't appear, run `.\Manage-Workspaces.ps1 -Validate` to confirm
the entry was written correctly and the JSON file path resolves.

**Claude stops mid-report with a tool-call limit message**
This is expected on large environments within a single turn. Type
`Continue` — the data already collected is still in memory, so this does
not trigger new tool calls. See
[Assessment session tips](getting-started.md#assessment-session-tips) for
the collection/analysis split that avoids this in the first place.

For setup-level issues (server not appearing as running, JSON not loading),
see the Troubleshooting section in
[Getting Started — Profile A](getting-started-a.md#troubleshooting).
