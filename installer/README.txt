LegacyMCP -- Installer
======================

Version: 0.1.x
Location: installer\

This directory contains the scripts needed to install, configure, and
uninstall LegacyMCP on Windows.

-------------------------------------------------------------------------------
FILES
-------------------------------------------------------------------------------

  Install-LegacyMCP.ps1     Main installer. Supports -Profile A and -Profile B.
  Uninstall-LegacyMCP.ps1   Removes service, EventLog source, and registry keys.
  Config-LegacyMCP.ps1      Read, set, and validate registry configuration.
  Manage-Workspaces.ps1     Add, remove, list, validate, and repair workspaces.
  tools\nssm.exe            NSSM service manager (Profile B only). See below.
  README.txt                This file.

-------------------------------------------------------------------------------
PREREQUISITES
-------------------------------------------------------------------------------

All profiles:
  - Windows 10 / Windows Server 2016 or later
  - Python 3.10 or later (https://python.org)
  - PowerShell 5.1 or later (pre-installed on Windows 10/Server 2016+)

Profile B only:
  - Administrator privileges on the target server
  - nssm.exe present in installer\tools\ (see NSSM section below)
  - WinRM HTTPS enabled on all Domain Controllers (port 5986)
  - Network access from this server to all target DCs
  - Service account with "Log on as a service" right (SeServiceLogonRight)
    * gMSA accounts (ending with $): right is granted automatically by AD
    * Standard domain accounts: must be granted explicitly (see below)

Recommended for the collector (offline mode):
  - PowerShell 5.1 with Active Directory module (RSAT)
  - Domain member machine or account with read access to AD

-------------------------------------------------------------------------------
QUICK START -- PROFILE A (local, offline, consultant's machine)
-------------------------------------------------------------------------------

  1. Open PowerShell (no Administrator required).

  2. Run:
       cd <install-root>\installer
       .\Install-LegacyMCP.ps1 -DeployProfile A

  3. The installer will:
       - Create a Python virtual environment in <install-root>\.venv
       - Install the LegacyMCP package
       - Copy config\config.example-A.yaml to config\config.yaml
       - Write the registry keys
       - Register the EventLog source (requires elevation prompt if UAC active)
       - Print the JSON block to add to claude_desktop_config.json

  4. Edit config\config.yaml to point to your JSON data files.

  5. Restart Claude Desktop.

-------------------------------------------------------------------------------
QUICK START -- PROFILE B (shared LAN, Windows service)
-------------------------------------------------------------------------------

  1. Open PowerShell as Administrator.

  2. Place nssm.exe in installer\tools\ (see NSSM section below).

  3. Run:
       cd <install-root>\installer
       .\Install-LegacyMCP.ps1 -DeployProfile B -ServiceAccount CONTOSO\legacymcp$

  4. Edit config\config.yaml:
       - Set profile: B-core
       - Set host: 0.0.0.0 under server:
       - Add forest entries with dc: and credentials: gmsa

  5. Start the service:
       Start-Service LegacyMCP

  6. Configure your MCP client to connect to:
       http://<server-ip>:8000/mcp

-------------------------------------------------------------------------------
PROFILE B -- SERVICE ACCOUNT AND SeServiceLogonRight
-------------------------------------------------------------------------------

LegacyMCP runs as a Windows service under a dedicated service account.
The account must have the "Log on as a service" Windows right (SeServiceLogonRight).

Recommended: gMSA (Group Managed Service Account)
  gMSA accounts (name ends with $) receive SeServiceLogonRight automatically
  when they are added to the Windows service via NSSM. No manual grant needed.
  Example:
    .\Install-LegacyMCP.ps1 -DeployProfile B -ServiceAccount CONTOSO\legacymcp$

Standard domain account (non-gMSA):
  The installer checks SeServiceLogonRight automatically during Phase 5.

  Case 1 -- Installer is running as Administrator (recommended):
    The installer grants SeServiceLogonRight automatically using secedit.
    A [WARN] is shown. Verify the grant in secpol.msc before production use.

  Case 2 -- Installer is NOT running as Administrator:
    The installer shows [FAIL] and exits. Grant the right manually:
      1. Open: secpol.msc
      2. Navigate to: Local Policies > User Rights Assignment
      3. Open: "Log on as a service"
      4. Add the service account.
      5. Re-run the installer, or start the service manually.

  Case 3 -- secedit check fails (e.g. restricted policy environment):
    The installer shows [WARN] and continues. Verify in secpol.msc.

Validating the right after installation:
    .\Config-LegacyMCP.ps1 -Validate
  The -Validate command checks SeServiceLogonRight for the configured account
  and reports [OK] or [WARN].

-------------------------------------------------------------------------------
CONFIGURATION MANAGEMENT
-------------------------------------------------------------------------------

Read current registry configuration:
  .\Config-LegacyMCP.ps1 -Get

Change a value:
  .\Config-LegacyMCP.ps1 -Set Port 9000
  .\Config-LegacyMCP.ps1 -Set Transport streamable-http
  .\Config-LegacyMCP.ps1 -Set ConfigPath "C:\LegacyMCP\config\config.yaml"

Validate configuration coherence:
  .\Config-LegacyMCP.ps1 -Validate

-------------------------------------------------------------------------------
WORKSPACE MANAGEMENT
-------------------------------------------------------------------------------

List mounted forests:
  .\Manage-Workspaces.ps1 -List

Add an offline forest:
  .\Manage-Workspaces.ps1 -Add -Name contoso.local -File "C:\Data\contoso.json"

Add a live forest:
  .\Manage-Workspaces.ps1 -Add -Name house.local -DC dc01.house.local

Remove a forest (JSON file is preserved):
  .\Manage-Workspaces.ps1 -Remove -Name contoso.local

Validate all forests:
  .\Manage-Workspaces.ps1 -Validate

Repair missing metadata in JSON files:
  .\Manage-Workspaces.ps1 -RepairMetadata

-------------------------------------------------------------------------------
UNINSTALL
-------------------------------------------------------------------------------

  Open PowerShell as Administrator, then run:
    .\Uninstall-LegacyMCP.ps1

  This removes:
    - The LegacyMCP Windows service (Profile B)
    - The EventLog source
    - All registry keys under HKLM\SOFTWARE\LegacyMCP\

  This does NOT remove:
    - config\config.yaml
    - Log files
    - JSON data files (AD exports)

  JSON data files are classified Confidential/Restricted. Delete them
  securely using cipher /w or a certified file shredder when no longer needed.

-------------------------------------------------------------------------------
NSSM -- Non-Sucking Service Manager
-------------------------------------------------------------------------------

NSSM is required only for Profile B. It is not bundled in the repository.

Download:
  https://nssm.cc/release/nssm-2.24.zip

Steps:
  1. Download nssm-2.24.zip from the URL above.
  2. Extract nssm.exe from nssm-2.24\win64\nssm.exe (64-bit) or
     nssm-2.24\win32\nssm.exe (32-bit, uncommon).
  3. Place nssm.exe in installer\tools\.
  4. Verify the SHA256 hash before use (see below).

SHA256 hash of nssm.exe (nssm-2.24, win64):
  F689EE9AF94B00E9E3F0BB072B34CAAF207F32DCB4F5782FC9CA351DF9A06C97
  Expected: <sha256-of-nssm-2.24-win64-nssm.exe>

  Verify with PowerShell:
    Get-FileHash installer\tools\nssm.exe -Algorithm SHA256

  Official hashes are published at: https://nssm.cc/download

-------------------------------------------------------------------------------
REGISTRY KEYS
-------------------------------------------------------------------------------

  HKLM\SOFTWARE\LegacyMCP\
    InstallPath     REG_SZ      Absolute path to install root
    Version         REG_SZ      Installed version (e.g. 0.1.3)
    ConfigPath      REG_SZ      Absolute path to config.yaml
    LogPath         REG_SZ      Absolute path to log directory
    Profile         REG_SZ      A | B-core | B-enterprise | C
    Transport       REG_SZ      stdio | streamable-http
    Port            REG_DWORD   Server port (default 8000)

  HKLM\SOFTWARE\LegacyMCP\Service\
    AutoStart       REG_DWORD   0 = manual, 1 = automatic

-------------------------------------------------------------------------------
SECURITY NOTES
-------------------------------------------------------------------------------

  - LegacyMCP is read-only: it never creates or modifies Active Directory
    objects. This is an architectural constraint, not a technical limitation.

  - JSON data files exported by the collector contain a complete snapshot of
    your Active Directory environment. Treat them as Confidential/Restricted:
      * Keep them on encrypted storage (BitLocker).
      * Do not sync to personal cloud services (OneDrive personal, Dropbox).
      * Use secure transfer when moving files (not plain email or USB).
      * Delete securely after the engagement.

  - For Profile B, use a gMSA (Group Managed Service Account) as the service
    account. Never run the service as LocalSystem or a Domain Admin account.

  - Never install LegacyMCP on a Domain Controller. Use a dedicated member
    server. This is an architectural rule, not a recommendation.

  - TLS is strongly recommended for Profile B. Configure ssl_certfile and
    ssl_keyfile in config.yaml and ensure a valid certificate is in place.

-------------------------------------------------------------------------------
