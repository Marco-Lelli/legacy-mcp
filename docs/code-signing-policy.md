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
- `installer/Install-LegacyMCP.ps1`
- `installer/Uninstall-LegacyMCP.ps1`
- `installer/Config-LegacyMCP.ps1`
- `installer/Manage-Workspaces.ps1`
- `installer/Setup-LegacyMCPClient.ps1`
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
Get-AuthenticodeSignature .\Install-LegacyMCP.ps1
```

A valid signature will show `SignerCertificate` issued by `SignPath Foundation`.

## Note

Code signing via SignPath Foundation is currently in the application process.
Releases prior to the signing approval are unsigned. Once approved,
all future releases will include signed PowerShell artifacts.
