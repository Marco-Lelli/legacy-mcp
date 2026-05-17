# Code Signing Policy

Free code signing provided by [SignPath.io](https://about.signpath.io),
certificate by [SignPath Foundation](https://signpath.org).

## Team

| Role | Members |
|------|---------|
| Author & Approver | [Marco-Lelli](https://github.com/Marco-Lelli) |
| Reviewers | All authors; pull requests from external contributors require review before merge |

## Signed Artifacts

The following artifacts are signed in each release:

- `collector/Collect-ADData.ps1`
- `collector/modules/*.psm1`
- `installer/Setup-LegacyMCP.ps1`
- `installer/modules/LegacyMCP.Common.psm1`
- `installer/modules/LegacyMCP.Python.psm1`
- `installer/modules/LegacyMCP.Service.psm1`
- `installer/modules/LegacyMCP.Certs.psm1`
- `installer/modules/LegacyMCP.Config.psm1`
- `installer/modules/LegacyMCP.Client.psm1`
- `installer/Manage-Workspaces.ps1`
- `installer/mcp-remote-live.ps1`

Signing is applied to all PowerShell scripts distributed in release packages.
The Python server (`src/`) is not signed — it is distributed as source code
and installed via `pip` / `pyproject.toml`.

## Privacy

This program will not transfer any information to other networked systems
unless specifically requested by the user or the person installing or
operating it.

## Verification

To verify the signature of a downloaded script:

```powershell
Get-AuthenticodeSignature .\Setup-LegacyMCP.ps1
```

A valid signature will show `SignerCertificate` issued by `SignPath Foundation`.

## Note

Code signing via SignPath Foundation is currently in the application process.
Releases prior to the signing approval are unsigned. Once approved,
all future releases will include signed PowerShell artifacts.
