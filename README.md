# LegacyMCP

> Active Directory MCP Server for AI-powered assessment

LegacyMCP brings the power of AI to Active Directory on-premises environments.
It exposes AD data as tools that Claude and other LLMs can query directly —
turning a static assessment script into an interactive, intelligent conversation
with your infrastructure.

No more 200-page Word documents that nobody reads.
Ask questions, get answers, understand your AD.

---

## Why LegacyMCP

Active Directory is still the backbone of most enterprise environments.
Despite the cloud push, AD on-prem is very much alive — and largely invisible
to modern AI tooling.

LegacyMCP fills that gap.

It was born out of a real consulting need: the Identity team at
[Impresoft 4ward](https://www.4ward.it/) runs AD assessments for
enterprise clients regularly. The goal was to make that process faster,
smarter, and more useful — and to share the result with the community.

---

## Two modes, one interface

**Live Mode**
Connects directly to Domain Controllers via WinRM and PowerShell.
Real-time data, ideal for internal admins or consultants with direct
network access.

**Offline Mode**
A PowerShell collector exports AD data to a structured JSON file.
The MCP server loads and queries that data locally — no network access
required during analysis. Perfect for remote consulting scenarios.

---

## Multi-scope Workspace

LegacyMCP understands that real-world assessments are rarely simple:

- Single domain — limited access, no Enterprise Admin required
- Full forest — global view with Enterprise Admin
- Multiple forests — separate environments, independent analysis
- Migration scenarios — source/destination mapping, SIDHistory tracking,
  naming conflict detection

---

## What it covers

LegacyMCP Core covers everything in Carl Webster's legendary
ADDS_Inventory script (https://github.com/CarlWebster/Active-Directory-V3) 
— now queryable via natural language:

- Forest and domain configuration
- Optional AD features (Recycle Bin, etc.)
- AD Schema — custom objects and attributes
- Domain Controllers, FSMO roles, local settings (NTP, registry)
- Event Log configuration per DC
- SYSVOL state and replication
- Sites, site links, replication topology
- Users — counts, states, privileged accounts
- Groups — privileged groups, nested membership
- Organizational Units — full OU tree
- GPO Inventory — list, OU links, blocked inheritance
- Trust relationships — type, direction, SIDHistory
- Fine-Grained Password Policies
- DNS configuration on Domain Controllers
- PKI / CA Discovery — Certification Authorities from AD

---

## Enterprise layer

Impresoft 4ward maintains a proprietary enterprise layer on top of
LegacyMCP Core:

- **DHCP Analysis** — autodiscovery via Authorized DHCP Servers or manual list
- **GPO Analysis** — deep analysis powered by GPOzaurr
- **AD Security Analysis** — inspired by PingCastle
- **AD Health Check** — misconfigurations, replication issues, best practices
- **PKI Configuration Analysis** — detailed CA config, templates, CRL, AIA,
  chain of trust
- **PKI Security Analysis** — misconfigurations, security best practices
- **ESC Analysis** — certificate template vulnerability assessment (ESC1-ESC8)
- **DOCX generation** — automated assessment documents from corporate templates

Interested? Get in touch.

---

## Built for enterprise environments

- **gMSA support** — no password management headaches
- **Windows Service** — install, forget, monitor
- **Dedicated EventLog** — full audit trail, SIEM-ready
- **Performance Counters** — heartbeat and DC reachability monitoring
- **Graceful degradation** — partial data is better than no data
- **Three deployment profiles** — local offline, internal network,
  internet-facing with WAF

---

## Requirements

- PowerShell 5.1 or later (PS 7.x supported)
- Windows Server 2012 R2 and later
- Python 3.10+
- Claude Desktop or any MCP-compatible client

---

## Author

**Marco Lelli**
Head of Identity — [Impresoft 4ward](https://www.4ward.it/)
Microsoft Identity specialist with 25+ years in enterprise IT infrastructure.

📖 Follow the build story on [Legacy Things](https://legacythings.it) —
a technical blog about the legacy mechanisms that still run the world.

---

## License

MIT — free to use, modify, and distribute.
See [LICENSE](LICENSE) for details.