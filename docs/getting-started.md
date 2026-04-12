# Getting Started

LegacyMCP is an MCP server that lets Claude query an Active Directory
environment and produce an assessment report. It supports two operating
modes — **Offline Mode** (PowerShell collector exports a JSON file, no
persistent network access required) and **Live Mode** (direct WinRM
connection to Domain Controllers) — and two main deployment profiles:
**Profile A** for a single consultant machine, and **Profile B-core**
for a shared server inside the client network.

---

## Which profile is right for you?

| Profile | Scenario | Guide |
|---------|----------|-------|
| Profile A | Single consultant machine, local offline analysis | [Getting Started — Profile A](getting-started-a.md) |
| Profile B-core | MCP server on a dedicated machine inside the client network, consultant connects remotely | [Getting Started — Profile B-core](getting-started-b-core.md) |

---

## Common prerequisites

- **Python 3.10+** — required on the machine running the MCP server (both profiles)
- **PowerShell 5.1+** — required to run the collector on any domain-joined Windows machine with RSAT; not needed on the analysis machine itself
- **Claude Desktop with Pro plan** — required to use MCP tools ([claude.ai](https://claude.ai))
- **Node.js 18+** — Profile B-core only; required on the consultant machine to run mcp-remote
- **Domain Admin or Enterprise Admin rights** on the target AD environment — required to run the collector

---

## Assessment session tips

Five practices that make sessions more effective, especially on the
Claude Desktop Pro plan which has a per-turn tool-call limit:

1. **Split collection from analysis.** Turn 1: *"Collect all data for
   contoso.local. Do not analyse — just say 'data collected' when done."*
   Turn 2: *"Produce the full report with High/Medium/Low findings."*

2. **One forest per turn.** Multi-forest queries in a single turn hit
   the tool-call limit quickly.

3. **Specific queries over generic ones.** *"Show users with adminCount=1
   and privileged groups with nested members on contoso.local"* uses
   far fewer tool calls than *"Analyse everything."*

4. **The Continue command.** If Claude stops before finishing the report,
   type `Continue`. The data is already in memory — no additional tool
   calls are needed. This resolves the
   *"Claude reached its tool-use limit for this turn"* message.

5. **list_workspaces() first.** Claude calls it automatically at session
   start to confirm what is loaded. If it does not, ask explicitly before
   any other query.

---

## Next steps

- [Profile A setup — local offline analysis](getting-started-a.md)
- [Profile B-core setup — LAN endpoint with HTTPS](getting-started-b-core.md)
