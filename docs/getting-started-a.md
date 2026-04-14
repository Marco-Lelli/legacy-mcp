# Getting Started — Profile A (Offline Mode)

> This guide covers **Profile A** — the simplest deployment scenario:
> a single consultant machine running LegacyMCP locally in Offline Mode.
> No network exposure, no authentication required.
>
> For Profile B-core (LAN endpoint with HTTPS and authentication),
> see [getting-started-b-core.md](getting-started-b-core.md).

LegacyMCP is an MCP server that lets Claude query an Active Directory
environment and produce an assessment report. This guide covers Offline
Mode: you run a PowerShell collector script inside the customer network,
export a JSON file, and analyse it with Claude on your own machine —
no persistent network access required.

---

## Prerequisites

- **Claude Desktop** with a Pro plan — [claude.ai](https://claude.ai)
- **Python 3.10+** — `python --version` to check
- **PowerShell 5.1** on the machine where you will run the collector
  (any domain-joined Windows workstation or server with RSAT installed)
- **Domain Admin** rights on the target domain, or **Enterprise Admin**
  for a full forest collection

---

## Installation

**Option 1 — Download ZIP (no Git required)**

Download the latest release from the
[Releases page](https://github.com/Marco-Lelli/legacy-mcp/releases),
extract `legacymcp-installer.zip` to a folder of your choice, and
open a PowerShell window in that folder.

**Option 2 — Clone with Git**

```bash
git clone https://github.com/Marco-Lelli/legacy-mcp.git
cd legacy-mcp
```

**Both options — create the virtual environment and install:**

```bash
python -m venv .venv
.venv\Scripts\activate        # Windows
# source .venv/bin/activate   # macOS / Linux

pip install -e ".[dev]"
```

Verify the entry point works:

```bash
legacy-mcp --help
```

---

### Optional: register Windows Event Log

Run once as Administrator before starting the server:

```powershell
.\scripts\Register-EventLog.ps1
```

This registers the `LegacyMCP-Server` event source in the `LegacyMCP`
Windows Event Log. Required for the server to log startup, shutdown,
and security events. Safe to run multiple times.

---

## Configure Claude Desktop

Claude Desktop reads MCP server definitions from a JSON config file.

**Location on Windows:**
```
%APPDATA%\Claude\claude_desktop_config.json
```

Add the `legacymcp` entry under `mcpServers`. Use the **absolute path**
to the Python interpreter inside your virtual environment:

```json
{
  "mcpServers": {
    "legacymcp": {
      "command": "C:\\path\\to\\legacy-mcp\\.venv\\Scripts\\python.exe",
      "args": [
        "-m", "legacy_mcp.server",
        "--config", "C:\\path\\to\\legacy-mcp\\config\\config.yaml"
      ]
    }
  }
}
```

Replace `C:\\path\\to\\legacy-mcp` with the actual path where you cloned
the repository. Use double backslashes in JSON.

**Restart Claude Desktop** after saving the file.

To verify: open **Settings → Developer** in Claude Desktop. The
`legacymcp` server should appear with status **running**. If it shows
an error, check the path and restart again.

---

## Quick Start — Test with sample data

The repository includes a synthetic Active Directory fixture at
`tests/fixtures/contoso-sample.json` so you can verify the setup
without running the collector.

**1. Copy the example config:**

**Windows:**
```
copy config\config.example-A.yaml config\config.yaml
```

**macOS / Linux:**
```
cp config/config.example-A.yaml config/config.yaml
```

> When editing `config.yaml`, use forward slashes in file paths even on Windows.

**2. Restart Claude Desktop** to pick up the new config.

**3. Open a new Claude conversation and try:**

```
What environments do you have available?
```

Claude will call `list_workspaces()` and confirm the contoso.local
forest is loaded.

```
Give me a summary of contoso.local — domains, DCs, user counts,
privileged groups.
```

If you get a structured response with AD data, the stack is working.

---

## Real Assessment — Collect AD data

**On the machine with AD access:**

1. Copy the `collector/` folder to a domain-joined workstation or server
   with RSAT installed.

2. Read `collector/README.txt` for the full prerequisite list, required
   rights, and parameter reference.

3. Open an elevated PowerShell session and run:

```powershell
.\Collect-ADData.ps1 -OutputPath C:\LegacyMCP-Data\contoso.local-data-20250318.json
```

   For alternate credentials or a specific DC, see the EXAMPLES section
   in README.txt.

4. Transfer the JSON file to your analysis machine.

**Important:** store JSON files in a dedicated folder **outside** the
repository — `C:\LegacyMCP-Data\` is the recommended convention. AD
exports contain sensitive data and must never be committed to Git.
See the DATA STORAGE section in `collector/README.txt`.

**On your analysis machine:**

5. Update `config/config.yaml` to point to the real JSON:

```yaml
mode: offline
workspace:
  forests:
    - name: contoso.local
      relation: standalone
      file: C:/LegacyMCP-Data/contoso.local-data-20250318.json
```

6. Restart Claude Desktop.

---

## Multi-forest configuration

For assessments covering multiple domains or a migration scenario
(source + destination forest), see the **MULTI-FOREST CONFIGURATION**
section in `collector/README.txt`. It covers:

- Multiple standalone forests
- Migration source/destination with comparative findings
- Multi-domain forest collected domain by domain

---

> For assessment session tips, see [Getting Started](getting-started.md#assessment-session-tips).

---

## Troubleshooting

**Server does not appear as running in Claude Desktop**
- Verify the Python path in `claude_desktop_config.json` is absolute
  and points to the `.venv` interpreter, not a system Python.
- Check that `config/config.yaml` exists and the JSON file paths are
  correct.
- Restart Claude Desktop completely (quit from the system tray).
- Run the server manually to see the error:
  ```bash
  .venv\Scripts\python.exe -m legacy_mcp.server --config config\config.yaml
  ```

**JSON not loading / tool returns empty results**
- The PowerShell collector writes UTF-8 with BOM by default. The loader
  handles this automatically since v0.1. If you are on an older version,
  convert the file:
  ```python
  content = open("data.json", encoding="utf-8-sig").read()
  open("data.json", "w", encoding="utf-8").write(content)
  ```
- Verify the `file:` path in `config.yaml` uses forward slashes and
  points to an existing file.

**Tool-call limit reached mid-session**
- Type `Continue` to resume report generation from memory.
- For large forests, use the two-turn collection/analysis approach
  described in the session tips above.

**PowerShell errors in the collector**
- Confirm PowerShell 5.1: `$PSVersionTable.PSVersion`
- Confirm the ActiveDirectory module is available:
  `Get-Module -ListAvailable ActiveDirectory`
- Install RSAT if missing (Windows 10/11):
  ```powershell
  Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
  Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0
  ```
- Run the session as Administrator for remote registry access (NTP and
  EventLog config queries).

---

## Contributing

Repository: [https://github.com/Marco-Lelli/legacy-mcp](https://github.com/Marco-Lelli/legacy-mcp)

Issues, pull requests, and feedback are welcome.

Background and context on the project: [legacythings.it](https://legacythings.it)
