# Disclaimer

LegacyMCP is provided for Active Directory assessment
and documentation purposes only.

## Read-Only by Design

LegacyMCP is strictly read-only. It never creates,
modifies, or deletes any Active Directory object.
This is a deliberate architectural decision, not a
technical limitation. Any modification to the codebase
that enables write operations is the sole responsibility
of the party making that modification.

## Authorized Use Only

This software must only be used against Active Directory
environments that you own or have explicit written
authorization to assess. Unauthorized use against
systems you do not have permission to access may
violate applicable laws and regulations.

## No Warranty

This software is provided "as is", without warranty
of any kind, express or implied. The authors and
contributors accept no responsibility for damages
arising from the use or misuse of this software.

## Active Development

LegacyMCP is under active development. The software may exhibit
unexpected behavior, incomplete features, or breaking changes between
versions. It is not yet recommended for production environments without
prior validation in a test setup.

If you encounter unexpected behavior, please open an issue at:
https://github.com/Marco-Lelli/legacy-mcp/issues

Include the following in your report:
- LegacyMCP version (git commit hash)
- Operating system and Python version
- Target Windows Server version
- Steps to reproduce the issue
- Relevant log output

## Data Handling

The JSON files produced by the LegacyMCP collector
contain sensitive Active Directory configuration data.
These files must be handled as confidential information,
transmitted only over encrypted channels, and deleted
when no longer needed. The authors accept no
responsibility for damages arising from improper
handling of collector output files.

## Third-Party Components

LegacyMCP builds upon the foundational work of Carl
Webster's ADDS_Inventory.ps1
(https://github.com/CarlWebster/Active-Directory-V3).
All third-party components retain their original
licenses and attributions.

---

*LegacyMCP is an open source project by Marco Lelli,
Head of Identity at Impresoft 4ward.*
*Repository: https://github.com/Marco-Lelli/legacy-mcp*
*Blog: https://legacythings.it*
