# LegacyMCP Setup Reference

Complete reference for `installer/Setup-LegacyMCP.ps1`.

> `Setup-LegacyMCP.ps1` is the unified setup script that replaces the legacy
> `Install-LegacyMCP.ps1`, `Uninstall-LegacyMCP.ps1`, `Setup-LegacyMCPClient.ps1`,
> and `Config-LegacyMCP.ps1` scripts.

For step-by-step installation guides see:
- [Getting Started — Profile A](getting-started-a.md)
- [Getting Started — Profile B-core](getting-started-b-core.md)

---

## Syntax

```powershell
.\Setup-LegacyMCP.ps1 -Profile <profile> [-Role <role>] [-Mode <mode>] [options]
.\Setup-LegacyMCP.ps1 -Gui
```

---

## Common Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-Profile` | string | yes* | — | Deployment profile: `A`, `B-core`, `B-enterprise`, `C` |
| `-Role` | string | Profile B/C | — | Machine role: `Server` or `Client` (not applicable for Profile A) |
| `-Mode` | string | no | `Install` | Operation: `Install`, `Configure`, `Repair`, `Uninstall` |
| `-Gui` | switch | no | — | Launch the interactive WinForms wizard instead of CLI. When specified, all other parameters except those passed by the wizard are ignored |
| `-Version` | string | no | — | Install a specific version from PyPI (e.g. `-Version 0.2.2`). Ignored when `-DevInstall` is specified |
| `-DevInstall` | switch | no | — | Install from the local source tree in editable mode (`pip install -e .`) instead of PyPI. Requires the full repository; not available from ZIP release |
| `-Purge` | switch | no | — | Deep removal during Uninstall: removes registry keys and all data directories. Prompts for confirmation ("Type YES"). See N-INST-1 below |

\* `-Profile` is not required when `-Gui` is used; the wizard prompts for it.

### Elevation rules

| Profile / Role | Elevation |
|---|---|
| Profile A (Install, Uninstall) | Must run as **normal user** — not Administrator |
| Profile B Server | Must run as **Administrator** |
| Profile B Client | Must run as **normal user** — not Administrator |

---

## Profile A Parameters

All parameters are optional overrides. Defaults use `%LOCALAPPDATA%\LegacyMCP\`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-InstallPath` | string | `%LOCALAPPDATA%\LegacyMCP` | Root installation directory for the virtual environment |
| `-ConfigPath` | string | `%LOCALAPPDATA%\LegacyMCP\config\config.yaml` | Path for `config.yaml` |
| `-DataPath` | string | `%USERPROFILE%\Documents\LegacyMCP-Data` | Default data directory for AD JSON files |

Registry: `HKCU:\SOFTWARE\LegacyMCP`

---

## Profile B-core Server Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-ServiceAccount` | string | Install only | — | Service account in `DOMAIN\name$` (gMSA) or `DOMAIN\name` format |
| `-ApiKey` | string | no | auto-generated | Externally managed API key. Minimum 16 characters. If not specified, the installer generates one automatically |
| `-Port` | int | no | `8000` | Listening port. Used during Install; use `-Mode Configure -Port` to change post-install |
| `-SnapshotPath` | string | no | `%ProgramData%\LegacyMCP\snapshots` | Directory for snapshot files |
| `-LogPath` | string | no | `%ProgramData%\LegacyMCP\logs` | Directory for server log files |
| `-CertFile` | string | no* | — | Path to an external TLS certificate in PEM format |
| `-CertKeyFile` | string | no* | — | Path to the corresponding unencrypted private key in PEM format |

\* `-CertFile` and `-CertKeyFile` are mutually mandatory: provide both or neither.
If the key file is encrypted, export an unencrypted copy first:
```
openssl rsa -in encrypted.key -out unencrypted.key
```
The installer encrypts the key automatically with DPAPI-NG after import.

Registry: `HKLM:\SOFTWARE\LegacyMCP`

---

## Profile B-core Client Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `-ServerUrl` | string | yes | Full URL of the LegacyMCP server including `/mcp` suffix (e.g. `https://SERVER:8000/mcp`) |
| `-CaCertPath` | string | yes | Path to the server TLS certificate (`server.crt`) for `NODE_EXTRA_CA_CERTS` |

The installer prompts for the API key interactively (not passed on the command line).

---

## Configure Mode Parameters

Use `-Mode Configure` to update settings on an existing installation without reinstalling.

### Profile B-core Server only

| Parameter | Description |
|-----------|-------------|
| `-SnapshotPath <path>` | Change the snapshot directory. New directory is created and ACLs applied. Existing snapshots are not moved |
| `-Port <int>` | Change the listening port. Updates registry, `config.yaml`, and Windows Firewall rule. Prompts for confirmation. Service restarts automatically |
| `-RotateApiKey` | Generate a new API key. The new key is printed once in the console — copy it immediately. All clients must be updated. Service must restart after this change |
| `-RotateCert` | Generate a new self-signed TLS certificate. DPAPI-NG key blob in registry is updated. Service restarts automatically. Distribute the new `server.crt` to all clients |
| `-CertFile <path>` / `-CertKeyFile <path>` | Use a corporate CA certificate instead of a self-signed one. Recommended over copying files manually. Must be passed together — see [TLS Certificate Setup](tls-certificate-setup.md) |

---

## Modes

| Mode | Description |
|------|-------------|
| `Install` | Full installation: venv, package, config, service (Profile B), Claude Desktop config (Profile A) |
| `Configure` | Update settings on an existing installation. Supports `-Port`, `-SnapshotPath`, `-RotateApiKey`, `-RotateCert` for Profile B Server |
| `Repair` | **Not yet implemented.** Accepted by the parameter's `ValidateSet` but every profile/role branch currently throws "Mode 'Repair' is not yet implemented" — roadmap item, not yet usable |
| `Uninstall` | Remove the installation. Default behavior preserves configuration. Add `-Purge` for complete removal |

---

## Examples

### Profile A — Install

```powershell
# Graphical wizard
.\Setup-LegacyMCP.ps1 -Gui

# CLI, latest version from PyPI
.\Setup-LegacyMCP.ps1 -Profile A -Mode Install

# Pin a specific version
.\Setup-LegacyMCP.ps1 -Profile A -Mode Install -Version 0.2.2

# Install from local source (development/field testing)
.\Setup-LegacyMCP.ps1 -Profile A -Mode Install -DevInstall
```

### Profile A — Uninstall

```powershell
# Standard: preserves config
.\Setup-LegacyMCP.ps1 -Profile A -Mode Uninstall

# Deep clean: removes config, registry, and all data
.\Setup-LegacyMCP.ps1 -Profile A -Mode Uninstall -Purge
```

### Profile B-core Server — Install

```powershell
# gMSA account (recommended)
.\Setup-LegacyMCP.ps1 -Profile B-core -Role Server -Mode Install `
    -ServiceAccount "CONTOSO\svc_legacymcp$"

# Domain account
.\Setup-LegacyMCP.ps1 -Profile B-core -Role Server -Mode Install `
    -ServiceAccount "CONTOSO\svc_legacymcp"

# With version pin
.\Setup-LegacyMCP.ps1 -Profile B-core -Role Server -Mode Install `
    -ServiceAccount "CONTOSO\svc_legacymcp$" -Version 0.2.2

# With external certificate
.\Setup-LegacyMCP.ps1 -Profile B-core -Role Server -Mode Install `
    -ServiceAccount "CONTOSO\svc_legacymcp$" `
    -CertFile "C:\certs\server.crt" -CertKeyFile "C:\certs\server.key"
```

### Profile B-core Server — Configure

```powershell
# Rotate API key
.\Setup-LegacyMCP.ps1 -Profile B-core -Role Server -Mode Configure -RotateApiKey

# Rotate TLS certificate
.\Setup-LegacyMCP.ps1 -Profile B-core -Role Server -Mode Configure -RotateCert

# Change snapshot path
.\Setup-LegacyMCP.ps1 -Profile B-core -Role Server -Mode Configure `
    -SnapshotPath "D:\LegacyMCP\snapshots"

# Change port
.\Setup-LegacyMCP.ps1 -Profile B-core -Role Server -Mode Configure -Port 9000
```

### Profile B-core Client — Install

```powershell
.\Setup-LegacyMCP.ps1 -Profile B-core -Role Client -Mode Install `
    -ServerUrl "https://SERVER_IP:8000/mcp" `
    -CaCertPath "C:\path\to\server.crt"
```

---

## Installer Log

Every execution of `Setup-LegacyMCP.ps1` produces a timestamped log file:

```
installer\logs\setup-YYYYMMDD-HHmmss.log
```

The log captures the full installer output including step results, warnings,
and errors. Useful for diagnosing installation failures, especially on machines
where endpoint protection may quarantine files silently.

Log files are excluded from git (`installer/logs/*.log` in `.gitignore`).
The `installer/logs/` directory is tracked via `.gitkeep`.

---

## Known Limitations

| Note | Description |
|------|-------------|
| N-INST-1 | **Purge Profile A with B-core Client co-installed**: Profile A and Profile B-core Client share the same `%LOCALAPPDATA%\LegacyMCP\` path. Running `-Mode Uninstall -Purge` for Profile A removes the B-core Client configuration (API key, certificate, `mcp-remote-live.bat`). Open Claude Desktop after purge to verify, then re-run the B-core Client install if needed |
| N-INST-2 | Multiple instances on the same machine are not supported. Only one LegacyMCP service can be registered under the `LegacyMCP` service name |
| N-INST-3 | Profile A must not run as Administrator. Running elevated places the venv and config in the Administrator profile, making them invisible to Claude Desktop running as the normal account |
| N-INST-4 | Profile B-core Server requires Python installed **for all users** (not per-user). The installer aborts with an explicit error if user-scope Python is detected. The service account cannot access a user-scope venv |
