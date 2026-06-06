# LegacyMCP.Gui.Steps.psm1 -- wizard step screens
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'LegacyMCP.Gui.psm1') -Force -WarningAction SilentlyContinue

function Show-LMStepMode {
    try {
    Clear-LMContent
    Add-LMPageTitle 'Select Profile - Role'

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    $hasBInstall = Test-Path 'HKLM:\SOFTWARE\LegacyMCP'
    $hasAInstall = Test-Path 'HKCU:\SOFTWARE\LegacyMCP'

    $y = 65

    $ctxTxt = 'Running as standard user. B-core Server options are unavailable.'
    if ($isAdmin) { $ctxTxt = 'Running as Administrator. Profile A options are unavailable.' }
    $ctxLbl = New-LMLabel $ctxTxt 20 $y 560
    $ctxLbl.ForeColor = [System.Drawing.Color]::FromArgb(180,80,0)
    if ($isAdmin) { $ctxLbl.ForeColor = [System.Drawing.Color]::FromArgb(0,120,0) }
    $global:LMGui_Content.Controls.Add($ctxLbl)
    $y += 28

    # Profile A -- Install
    $script:_rb0_AI = New-LMRadio 'Profile A -- Install  (local machine, stdio, no auth)' 30 $y $false 500
    $script:_rb0_AI.Enabled = -not $isAdmin
    $global:LMGui_Content.Controls.Add($script:_rb0_AI)
    $y += 20
    $hAITxt = 'Installs LegacyMCP as a local process for Claude Desktop.'
    if ($isAdmin) { $hAITxt = 'Run without admin rights.' }
    $hAI = New-LMLabel $hAITxt 50 $y 480
    $hAI.ForeColor = [System.Drawing.Color]::Gray
    $global:LMGui_Content.Controls.Add($hAI)
    $y += 24

    # Profile A -- Uninstall
    $script:_rb0_AU = New-LMRadio 'Profile A -- Uninstall' 30 $y $false 500
    $script:_rb0_AU.Enabled = (-not $isAdmin) -and $hasAInstall
    $global:LMGui_Content.Controls.Add($script:_rb0_AU)
    $y += 20
    $hAUTxt = 'Removes the local LegacyMCP installation.'
    if     ($isAdmin)          { $hAUTxt = 'Run without admin rights.' }
    elseif (-not $hasAInstall) { $hAUTxt = 'No Profile A installation found.' }
    $hAU = New-LMLabel $hAUTxt 50 $y 480
    $hAU.ForeColor = [System.Drawing.Color]::Gray
    $global:LMGui_Content.Controls.Add($hAU)
    $y += 28

    $global:LMGui_Content.Controls.Add((New-LMSeparator $y)); $y += 12

    # B-core Server -- Install
    $script:_rb0_BSI = New-LMRadio 'B-core Server -- Install  (shared LAN server, HTTPS + API key)' 30 $y $false 500
    $script:_rb0_BSI.Enabled = $isAdmin
    $global:LMGui_Content.Controls.Add($script:_rb0_BSI)
    $y += 20
    $hBSITxt = 'Run as Administrator.'
    if ($isAdmin) { $hBSITxt = 'Installs the MCP server as a Windows service.' }
    $hBSI = New-LMLabel $hBSITxt 50 $y 480
    $hBSI.ForeColor = [System.Drawing.Color]::Gray
    $global:LMGui_Content.Controls.Add($hBSI)
    $y += 24

    # B-core Server -- Configure
    $script:_rb0_BSC = New-LMRadio 'B-core Server -- Configure  (port, credentials, certificate)' 30 $y $false 500
    $script:_rb0_BSC.Enabled = $isAdmin -and $hasBInstall
    $global:LMGui_Content.Controls.Add($script:_rb0_BSC)
    $y += 20
    $hBSCTxt = 'Rotates API key or TLS certificate, updates port or snapshot path.'
    if     (-not $isAdmin)     { $hBSCTxt = 'Run as Administrator.' }
    elseif (-not $hasBInstall) { $hBSCTxt = 'No B-core installation found.' }
    $hBSC = New-LMLabel $hBSCTxt 50 $y 480
    $hBSC.ForeColor = [System.Drawing.Color]::Gray
    $global:LMGui_Content.Controls.Add($hBSC)
    $y += 24

    # B-core Server -- Uninstall
    $script:_rb0_BSU = New-LMRadio 'B-core Server -- Uninstall' 30 $y $false 500
    $script:_rb0_BSU.Enabled = $isAdmin -and $hasBInstall
    $global:LMGui_Content.Controls.Add($script:_rb0_BSU)
    $y += 20
    $hBSUTxt = 'Stops the service, removes files and firewall rule.'
    if     (-not $isAdmin)     { $hBSUTxt = 'Run as Administrator.' }
    elseif (-not $hasBInstall) { $hBSUTxt = 'No B-core installation found.' }
    $hBSU = New-LMLabel $hBSUTxt 50 $y 480
    $hBSU.ForeColor = [System.Drawing.Color]::Gray
    $global:LMGui_Content.Controls.Add($hBSU)
    $y += 28

    $global:LMGui_Content.Controls.Add((New-LMSeparator $y)); $y += 12

    # B-core Client -- Install
    $script:_rb0_BC = New-LMRadio 'B-core Client -- Install  (this PC connects to the LAN server)' 30 $y $false 500
    $script:_rb0_BC.Enabled = -not $isAdmin
    $global:LMGui_Content.Controls.Add($script:_rb0_BC)
    $y += 20
    $hBCTxt = 'Configures Claude Desktop to reach the remote LegacyMCP server.'
    if ($isAdmin) { $hBCTxt = 'Run without admin rights.' }
    $hBC = New-LMLabel $hBCTxt 50 $y 480
    $hBC.ForeColor = [System.Drawing.Color]::Gray
    $global:LMGui_Content.Controls.Add($hBC)

    # Default: first enabled radio button
    $allRbs = @($script:_rb0_AI, $script:_rb0_AU, $script:_rb0_BSI, $script:_rb0_BSC, $script:_rb0_BSU, $script:_rb0_BC)
    $firstEnabled = $allRbs | Where-Object { $_.Enabled } | Select-Object -First 1
    if ($firstEnabled) { $firstEnabled.Checked = $true }

    $global:LMGui_BtnBack.Enabled = $false
    $global:LMGui_BtnNext.Text    = 'Next >'
    $global:LMGui_BtnNext.Enabled = $true

    $global:LMGui_NextAction = {
        if     ($script:_rb0_AI.Checked)  { $global:LMGui_State['Profile'] = 'A';      $global:LMGui_State['Role'] = '';       $global:LMGui_State['Mode'] = 'Install'    }
        elseif ($script:_rb0_AU.Checked)  { $global:LMGui_State['Profile'] = 'A';      $global:LMGui_State['Role'] = '';       $global:LMGui_State['Mode'] = 'Uninstall'  }
        elseif ($script:_rb0_BSI.Checked) { $global:LMGui_State['Profile'] = 'B-core'; $global:LMGui_State['Role'] = 'Server'; $global:LMGui_State['Mode'] = 'Install'    }
        elseif ($script:_rb0_BSC.Checked) { $global:LMGui_State['Profile'] = 'B-core'; $global:LMGui_State['Role'] = 'Server'; $global:LMGui_State['Mode'] = 'Configure'  }
        elseif ($script:_rb0_BSU.Checked) { $global:LMGui_State['Profile'] = 'B-core'; $global:LMGui_State['Role'] = 'Server'; $global:LMGui_State['Mode'] = 'Uninstall'  }
        elseif ($script:_rb0_BC.Checked)  { $global:LMGui_State['Profile'] = 'B-core'; $global:LMGui_State['Role'] = 'Client'; $global:LMGui_State['Mode'] = 'Install'    }
        if ($global:LMGui_State['Profile'] -eq '') {
            [System.Windows.Forms.MessageBox]::Show('No option is available in the current context.','LegacyMCP Setup','OK','Warning') | Out-Null
            return
        }
        & $global:LMGui_NavFn
    }
    } catch { Write-Warning "GUI: error building step screen: $_" }
}

# ---------------------------------------------------------------------------
# Step 2 -- Parameters: Install, Profile B-core (Server)
# ---------------------------------------------------------------------------

function Show-LMStepParamsInstallB {
    try {
    Clear-LMContent
    Add-LMPageTitle 'Parameters > Install Profile B-core'

    $p = $global:LMGui_Content
    $y = 58

    # Detect existing install (-ErrorAction SilentlyContinue handles missing key)
    $existingVersion = $null
    $regProps = Get-ItemProperty -Path 'HKLM:\SOFTWARE\LegacyMCP' -ErrorAction SilentlyContinue
    if ($regProps -and $regProps.InstalledVersion) { $existingVersion = $regProps.InstalledVersion }
    elseif (Test-Path 'HKLM:\SOFTWARE\LegacyMCP')  { $existingVersion = 'unknown' }

    if ($existingVersion) {
        $warnLbl = [System.Windows.Forms.Label]::new()
        $warnLbl.Text      = "Existing installation detected (version: $existingVersion). Choose how to handle credentials:"
        $warnLbl.Location  = [System.Drawing.Point]::new(20, $y)
        $warnLbl.Size      = [System.Drawing.Size]::new(560, 18)
        $warnLbl.ForeColor = [System.Drawing.Color]::FromArgb(180, 80, 0)
        $warnLbl.Font      = [System.Drawing.Font]::new('Tahoma', 8)
        $p.Controls.Add($warnLbl)
        $y += 20

        $script:_B_rbKeep  = New-LMRadio 'Keep existing credentials  (API key + certificate unchanged)' 30 $y $true 500
        $rbRegen = New-LMRadio 'Regenerate all credentials  (clients will need reconfiguration)' 30 ($y+20) $false 500
        $p.Controls.Add($script:_B_rbKeep)
        $p.Controls.Add($rbRegen)
        $y += 46
        $global:LMGui_State['ExistingVersion'] = $existingVersion
    } else {
        $global:LMGui_State['ExistingVersion'] = $null
    }

    $p.Controls.Add((New-LMSeparator $y)); $y += 10

    # Service Account
    $p.Controls.Add((New-LMLabel 'Service Account *' 20 $y))
    $y += 20
    $wmiSvc = Get-CimInstance Win32_Service -Filter "Name='LegacyMCP'" -ErrorAction SilentlyContinue
    $saInit = if     ($global:LMGui_State['ServiceAccount'] -ne '') { $global:LMGui_State['ServiceAccount'] }
              elseif ($wmiSvc -and $wmiSvc.StartName)               { $wmiSvc.StartName }
              else   { '' }
    $script:_B_tbSA = New-LMTextBox $saInit 20 $y 280
    $p.Controls.Add($script:_B_tbSA); $script:_B_errSA = New-LMErrorLabel 310 $y 200; $p.Controls.Add($script:_B_errSA)
    $y += 26

    # Password (hidden for gMSA)
    $pwdPanel = [System.Windows.Forms.Panel]::new()
    $pwdPanel.Location = [System.Drawing.Point]::new(20, $y)
    $pwdPanel.Size     = [System.Drawing.Size]::new(560, 42)
    $pwdPanel.Controls.Add((New-LMLabel 'Service Account Password' 0 0))
    $script:_B_tbPwd = New-LMTextBox '' 0 20 280 -Password
    $pwdPanel.Controls.Add($script:_B_tbPwd)
    $script:_B_hintLbl = New-LMLabel 'gMSA -- no password required' 0 22 260
    $script:_B_hintLbl.ForeColor = [System.Drawing.Color]::Gray
    $script:_B_hintLbl.Visible   = $false
    $pwdPanel.Controls.Add($script:_B_hintLbl)
    $script:_B_errPwd = New-LMErrorLabel 290 20 200; $pwdPanel.Controls.Add($script:_B_errPwd)
    $p.Controls.Add($pwdPanel)

    $script:_B_pwdUpdater = {
        $isGmsa = $script:_B_tbSA.Text.TrimEnd().EndsWith('$')
        $script:_B_tbPwd.Visible   = -not $isGmsa
        $script:_B_hintLbl.Visible = $isGmsa
    }
    $script:_B_tbSA.Add_TextChanged($script:_B_pwdUpdater)
    & $script:_B_pwdUpdater
    $y += 46

    # Port and SnapshotPath
    $p.Controls.Add((New-LMLabel 'Port' 20 $y 60))
    $p.Controls.Add((New-LMLabel 'Snapshot Path' 195 $y 160))
    $y += 20
    $script:_B_tbPort = New-LMTextBox $global:LMGui_State['Port'] 20 $y 160
    $script:_B_errPort = New-LMErrorLabel 20 ($y+22) 160; $p.Controls.Add($script:_B_errPort)
    $script:_B_tbSnap = New-LMTextBox $global:LMGui_State['SnapshotPath'] 200 $y 360
    $p.Controls.Add($script:_B_tbPort); $p.Controls.Add($script:_B_tbSnap)
    $y += 44

    # Version (Profile B supports it; Profile A will stub this)
    $p.Controls.Add((New-LMLabel 'Package version' 20 $y))
    $y += 20
    $script:_B_tbVer = New-LMTextBox $global:LMGui_State['Version'] 20 $y 200
    $p.Controls.Add($script:_B_tbVer); $y += 24

    # API Key groupbox
    $script:_B_gbApi = New-LMGroupBox 'API Key' 20 $y 250 90
    $script:_B_rbApiAuto = New-LMRadio 'Auto-generate  (recommended)' 8 16 $true 224
    $script:_B_rbApiMan  = New-LMRadio 'Set manually:' 8 36 $false 224
    $script:_B_tbApiMan  = New-LMTextBox '' 8 58 224; $script:_B_tbApiMan.Enabled = $false
    $script:_B_gbApi.Controls.Add($script:_B_rbApiAuto); $script:_B_gbApi.Controls.Add($script:_B_rbApiMan); $script:_B_gbApi.Controls.Add($script:_B_tbApiMan)
    $script:_B_rbApiMan.Add_CheckedChanged({ $script:_B_tbApiMan.Enabled = $script:_B_rbApiMan.Checked })
    $p.Controls.Add($script:_B_gbApi)

    # TLS Certificate groupbox
    $script:_B_gbCert = New-LMGroupBox 'TLS Certificate' 280 $y 280 166
    $script:_B_rbCertAuto = New-LMRadio 'Auto-generate self-signed  (730 days)' 8 16 $true 260
    $script:_B_rbCertImp  = New-LMRadio 'Import external certificate' 8 36 $false 200
    $script:_B_gbCert.Controls.Add($script:_B_rbCertAuto); $script:_B_gbCert.Controls.Add($script:_B_rbCertImp)
    $script:_B_gbCert.Controls.Add((New-LMLabel '.crt file:' 8 54 100))
    $script:_B_tbCertF = New-LMTextBox '' 8 76 186; $script:_B_tbCertF.Enabled = $false
    $script:_B_btnBrowseCrt = [System.Windows.Forms.Button]::new()
    $script:_B_btnBrowseCrt.Text     = 'Browse...'
    $script:_B_btnBrowseCrt.Location = [System.Drawing.Point]::new(198, 74)
    $script:_B_btnBrowseCrt.Size     = [System.Drawing.Size]::new(60, 24)
    $script:_B_btnBrowseCrt.Font     = [System.Drawing.Font]::new('Tahoma', 7)
    $script:_B_btnBrowseCrt.Enabled  = $false
    $script:_B_btnBrowseCrt.Add_Click({
        $ofd = [System.Windows.Forms.OpenFileDialog]::new()
        $ofd.Filter = 'PEM Certificate|*.crt;*.pem|All files|*.*'
        $ofd.Title  = 'Select .crt file'
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:_B_tbCertF.Text = $ofd.FileName
        }
        $ofd.Dispose()
    })
    $script:_B_gbCert.Controls.Add($script:_B_tbCertF)
    $script:_B_gbCert.Controls.Add($script:_B_btnBrowseCrt)
    $script:_B_gbCert.Controls.Add((New-LMLabel '.key file:' 8 102 100))
    $script:_B_tbCertK = New-LMTextBox '' 8 124 186; $script:_B_tbCertK.Enabled = $false
    $script:_B_btnBrowseKey = [System.Windows.Forms.Button]::new()
    $script:_B_btnBrowseKey.Text     = 'Browse...'
    $script:_B_btnBrowseKey.Location = [System.Drawing.Point]::new(198, 122)
    $script:_B_btnBrowseKey.Size     = [System.Drawing.Size]::new(60, 24)
    $script:_B_btnBrowseKey.Font     = [System.Drawing.Font]::new('Tahoma', 7)
    $script:_B_btnBrowseKey.Enabled  = $false
    $script:_B_btnBrowseKey.Add_Click({
        $ofd = [System.Windows.Forms.OpenFileDialog]::new()
        $ofd.Filter = 'Private Key|*.key;*.pem|All files|*.*'
        $ofd.Title  = 'Select .key file'
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:_B_tbCertK.Text = $ofd.FileName
        }
        $ofd.Dispose()
    })
    $script:_B_gbCert.Controls.Add($script:_B_tbCertK)
    $script:_B_gbCert.Controls.Add($script:_B_btnBrowseKey)
    $script:_B_errCert = New-LMErrorLabel 8 148 260; $script:_B_gbCert.Controls.Add($script:_B_errCert)
    $script:_B_rbCertImp.Add_CheckedChanged({
        $script:_B_tbCertF.Enabled      = $script:_B_rbCertImp.Checked
        $script:_B_tbCertK.Enabled      = $script:_B_rbCertImp.Checked
        $script:_B_btnBrowseCrt.Enabled = $script:_B_rbCertImp.Checked
        $script:_B_btnBrowseKey.Enabled = $script:_B_rbCertImp.Checked
    })
    $p.Controls.Add($script:_B_gbCert)
    $y += 170

    # Keep/Regen handler: disable credential groupboxes when Keep is selected
    if ($global:LMGui_State['ExistingVersion']) {
        $script:_B_rbKeep.Add_CheckedChanged({
            $enabled = -not $script:_B_rbKeep.Checked
            $script:_B_gbApi.Enabled  = $enabled
            $script:_B_gbCert.Enabled = $enabled
        })
        # Initial state: Keep is default (Checked=true), so disable groupboxes
        $script:_B_gbApi.Enabled  = $false
        $script:_B_gbCert.Enabled = $false
    }

    # Preserve config.yaml -- shown only when reinstalling over an existing config
    $script:_B_cbPreserveConfig = $null
    $configDefault = Join-Path $env:ProgramData 'LegacyMCP\config\config.yaml'
    if (Test-Path $configDefault) {
        $p.Controls.Add((New-LMSeparator $y)); $y += 10
        $script:_B_cbPreserveConfig = New-LMCheckBox 'Preserve existing config.yaml  (recommended)' 20 $y $true 480
        $p.Controls.Add($script:_B_cbPreserveConfig); $y += 22
        $hintPc = New-LMLabel 'Uncheck to overwrite with default template. Workspace entries will be lost.' 40 $y 500
        $hintPc.ForeColor = [System.Drawing.Color]::Gray
        $p.Controls.Add($hintPc); $y += 26
    }

    # DevInstall + Advanced
    $script:_B_cbDev = New-LMCheckBox 'Developer install  (-e from source tree)' 20 $y ($global:LMGui_State['DevInstall'] -eq $true) 280
    $p.Controls.Add($script:_B_cbDev)

    # Advanced toggle
    $script:_B_advLink = [System.Windows.Forms.LinkLabel]::new()
    $script:_B_advLink.Text     = 'Advanced options'
    $script:_B_advLink.Location = [System.Drawing.Point]::new(310, $y+2)
    $script:_B_advLink.AutoSize = $true
    $script:_B_advLink.Font     = [System.Drawing.Font]::new('Tahoma', 8)
    $p.Controls.Add($script:_B_advLink)
    $y += 22

    $script:_B_advPanel = [System.Windows.Forms.Panel]::new()
    $script:_B_advPanel.Location = [System.Drawing.Point]::new(20, $y)
    $script:_B_advPanel.Size     = [System.Drawing.Size]::new(560, 132)
    $script:_B_advPanel.Visible  = $false
    $script:_B_advPanel.Controls.Add((New-LMLabel 'Install Path' 0 0 200))
    $script:_B_tbIP = New-LMTextBox $global:LMGui_State['InstallPath'] 0 22 490
    $btnBrowseIP = [System.Windows.Forms.Button]::new()
    $btnBrowseIP.Text = 'Browse...'; $btnBrowseIP.Location = [System.Drawing.Point]::new(496, 20)
    $btnBrowseIP.Size = [System.Drawing.Size]::new(56, 24); $btnBrowseIP.Font = [System.Drawing.Font]::new('Tahoma', 7)
    $btnBrowseIP.Add_Click({ $fbd = [System.Windows.Forms.FolderBrowserDialog]::new(); $fbd.Description = 'Select Install Path'; if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $script:_B_tbIP.Text = $fbd.SelectedPath }; $fbd.Dispose() })
    $script:_B_advPanel.Controls.Add($script:_B_tbIP); $script:_B_advPanel.Controls.Add($btnBrowseIP)
    $script:_B_advPanel.Controls.Add((New-LMLabel 'Config Path' 0 42 200))
    $script:_B_tbCP = New-LMTextBox $global:LMGui_State['ConfigPath'] 0 64 490
    $btnBrowseCP = [System.Windows.Forms.Button]::new()
    $btnBrowseCP.Text = 'Browse...'; $btnBrowseCP.Location = [System.Drawing.Point]::new(496, 62)
    $btnBrowseCP.Size = [System.Drawing.Size]::new(56, 24); $btnBrowseCP.Font = [System.Drawing.Font]::new('Tahoma', 7)
    $btnBrowseCP.Add_Click({ $fbd = [System.Windows.Forms.FolderBrowserDialog]::new(); $fbd.Description = 'Select Config directory'; if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $script:_B_tbCP.Text = $fbd.SelectedPath }; $fbd.Dispose() })
    $script:_B_advPanel.Controls.Add($script:_B_tbCP); $script:_B_advPanel.Controls.Add($btnBrowseCP)
    $script:_B_advPanel.Controls.Add((New-LMLabel 'Log Path' 0 84 200))
    $script:_B_tbLP = New-LMTextBox $global:LMGui_State['LogPath'] 0 106 490
    $btnBrowseLP = [System.Windows.Forms.Button]::new()
    $btnBrowseLP.Text = 'Browse...'; $btnBrowseLP.Location = [System.Drawing.Point]::new(496, 104)
    $btnBrowseLP.Size = [System.Drawing.Size]::new(56, 24); $btnBrowseLP.Font = [System.Drawing.Font]::new('Tahoma', 7)
    $btnBrowseLP.Add_Click({ $fbd = [System.Windows.Forms.FolderBrowserDialog]::new(); $fbd.Description = 'Select Log Path'; if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $script:_B_tbLP.Text = $fbd.SelectedPath }; $fbd.Dispose() })
    $script:_B_advPanel.Controls.Add($script:_B_tbLP); $script:_B_advPanel.Controls.Add($btnBrowseLP)
    $p.Controls.Add($script:_B_advPanel)

    $script:_B_advLink.Add_LinkClicked({
        $script:_B_advPanel.Visible = -not $script:_B_advPanel.Visible
        $script:_B_advLink.Text = if ($script:_B_advPanel.Visible) { 'Hide advanced options' } else { 'Advanced options' }
    })

    # Scroll support
    $p.AutoScroll = $true

    $global:LMGui_BtnBack.Enabled = $true
    $global:LMGui_BtnNext.Text    = 'Next >'
    $global:LMGui_BtnNext.Enabled = $true

    $global:LMGui_NextAction = {
        # Validate
        $ok = $true
        $script:_B_errSA.Text = ''; $script:_B_errPwd.Text = ''; $script:_B_errPort.Text = ''; $script:_B_errCert.Text = ''

        if ([string]::IsNullOrWhiteSpace($script:_B_tbSA.Text)) {
            $script:_B_errSA.Text = 'Service account is required.'; $ok = $false
        }
        $isGmsa = $script:_B_tbSA.Text.TrimEnd().EndsWith('$')
        if (-not $isGmsa -and -not $global:LMGui_State['ExistingVersion'] -and [string]::IsNullOrWhiteSpace($script:_B_tbPwd.Text)) {
            $script:_B_errPwd.Text = 'Password is required for non-gMSA accounts.'; $ok = $false
        }
        $portInt = 0
        if (-not [int]::TryParse($script:_B_tbPort.Text, [ref]$portInt) -or $portInt -lt 1024 -or $portInt -gt 65535) {
            $script:_B_errPort.Text = 'Port must be 1024-65535.'; $ok = $false
        }
        if ($script:_B_rbCertImp.Checked) {
            if ([string]::IsNullOrWhiteSpace($script:_B_tbCertF.Text) -or [string]::IsNullOrWhiteSpace($script:_B_tbCertK.Text)) {
                $script:_B_errCert.Text = 'Both .crt and .key files are required.'; $ok = $false
            } elseif (-not (Test-Path $script:_B_tbCertF.Text) -or -not (Test-Path $script:_B_tbCertK.Text)) {
                $script:_B_errCert.Text = 'Certificate file(s) not found.'; $ok = $false
            }
        }
        if ($script:_B_rbApiMan.Checked -and [string]::IsNullOrWhiteSpace($script:_B_tbApiMan.Text)) {
            [System.Windows.Forms.MessageBox]::Show('API key cannot be empty when set manually.','Validation','OK','Warning') | Out-Null
            $ok = $false
        }
        if (-not $ok) { return }

        # Persist state
        $global:LMGui_State['ServiceAccount']  = $script:_B_tbSA.Text.Trim()
        $global:LMGui_State['Port']            = $script:_B_tbPort.Text.Trim()
        $global:LMGui_State['SnapshotPath']    = $script:_B_tbSnap.Text.Trim()
        $global:LMGui_State['Version']         = $script:_B_tbVer.Text.Trim()
        $global:LMGui_State['DevInstall']      = $script:_B_cbDev.Checked
        $global:LMGui_State['InstallPath']     = $script:_B_tbIP.Text.Trim()
        $global:LMGui_State['ConfigPath']      = $script:_B_tbCP.Text.Trim()
        $global:LMGui_State['LogPath']         = $script:_B_tbLP.Text.Trim()
        $global:LMGui_State['ApiKeyMode']      = if ($script:_B_rbApiAuto.Checked) { 'auto' } else { 'manual' }
        $global:LMGui_State['ApiKeyValue']     = $script:_B_tbApiMan.Text.Trim()
        $global:LMGui_State['CertMode']        = if ($script:_B_rbCertAuto.Checked) { 'auto' } else { 'import' }
        $global:LMGui_State['CertFile']        = $script:_B_tbCertF.Text.Trim()
        $global:LMGui_State['CertKeyFile']     = $script:_B_tbCertK.Text.Trim()
        $global:LMGui_State['KeepCredentials'] = if ($script:_B_rbKeep) { $script:_B_rbKeep.Checked } else { $false }

        if (-not $isGmsa -and -not [string]::IsNullOrWhiteSpace($script:_B_tbPwd.Text)) {
            $ss = [System.Security.SecureString]::new()
            foreach ($c in $script:_B_tbPwd.Text.ToCharArray()) { $ss.AppendChar($c) }
            $ss.MakeReadOnly()
            $global:LMGui_State['ServiceAccountPassword'] = $ss
        } else {
            $global:LMGui_State['ServiceAccountPassword'] = $null
        }
        $global:LMGui_State['PreserveConfig'] = ($script:_B_cbPreserveConfig -eq $null) -or $script:_B_cbPreserveConfig.Checked
        $global:LMGui_Content.AutoScroll = $false
        & $global:LMGui_NavFn
    }
    } catch { Write-Warning "GUI: error building step screen: $_" }
}

# ---------------------------------------------------------------------------
# Step 3B -- Parameters: Install, Profile A
# ---------------------------------------------------------------------------

function Show-LMStepParamsInstallA {
    try {
    Clear-LMContent
    Add-LMPageTitle 'Parameters > Install Profile A'

    $p = $global:LMGui_Content
    $y = 65

    $note = [System.Windows.Forms.Label]::new()
    $note.Text      = "Profile A runs as a local stdio process. No service, no network port.`r`nAfter installation, restart Claude Desktop to activate LegacyMCP."
    $note.Location  = [System.Drawing.Point]::new(20, $y)
    $note.Size      = [System.Drawing.Size]::new(560, 36)
    $note.Font      = [System.Drawing.Font]::new('Tahoma', 8)
    $p.Controls.Add($note)
    $y += 46

    # DataPath
    $p.Controls.Add((New-LMLabel 'Data folder (optional)' 20 $y))
    $y += 20
    $script:_A_tbData = New-LMTextBox $global:LMGui_State['DataPath'] 20 $y 400
    $p.Controls.Add($script:_A_tbData)
    $y += 32

    # Preserve config.yaml -- shown only when reinstalling over an existing config
    $script:_A_cbPreserveConfig = $null
    $configDefault = Join-Path $env:LOCALAPPDATA 'LegacyMCP\config\config.yaml'
    if (Test-Path $configDefault) {
        $p.Controls.Add((New-LMSeparator $y)); $y += 10
        $script:_A_cbPreserveConfig = New-LMCheckBox 'Preserve existing config.yaml  (recommended)' 20 $y $true 480
        $p.Controls.Add($script:_A_cbPreserveConfig); $y += 22
        $hintPc = New-LMLabel 'Uncheck to overwrite with default template. Workspace entries will be lost.' 40 $y 500
        $hintPc.ForeColor = [System.Drawing.Color]::Gray
        $p.Controls.Add($hintPc); $y += 26
    }

    # DevInstall checkbox
    $script:_A_cbDev = New-LMCheckBox 'Developer install  (-e from source tree)' 20 $y ($global:LMGui_State['DevInstall'] -eq $true) 280
    $p.Controls.Add($script:_A_cbDev)
    $y += 28

    # Version
    $lbVer = New-LMLabel 'Package version (optional, e.g. 0.2.3)' 20 $y 280
    $p.Controls.Add($lbVer)
    $y += 20
    $script:_A_tbVer = New-LMTextBox $global:LMGui_State['Version'] 20 $y 200
    $script:_A_tbVer.Enabled = -not ($global:LMGui_State['DevInstall'] -eq $true)
    $p.Controls.Add($script:_A_tbVer)
    $y += 26

    # DevInstall toggles Version field enabled state
    $script:_A_cbDev.Add_CheckedChanged({
        $script:_A_tbVer.Enabled = -not $script:_A_cbDev.Checked
        if ($script:_A_cbDev.Checked) { $script:_A_tbVer.Text = '' }
    })

    $global:LMGui_BtnBack.Enabled = $true
    $global:LMGui_BtnNext.Text    = 'Next >'
    $global:LMGui_BtnNext.Enabled = $true

    $global:LMGui_NextAction = {
        $global:LMGui_State['DataPath']       = $script:_A_tbData.Text.Trim()
        $global:LMGui_State['DevInstall']     = $script:_A_cbDev.Checked
        $global:LMGui_State['Version']        = $script:_A_tbVer.Text.Trim()
        $global:LMGui_State['PreserveConfig'] = ($script:_A_cbPreserveConfig -eq $null) -or $script:_A_cbPreserveConfig.Checked
        & $global:LMGui_NavFn
    }
    } catch { Write-Warning "GUI: error building step screen: $_" }
}

# ---------------------------------------------------------------------------
# Step: Parameters -- B-core Client Install
# ---------------------------------------------------------------------------

function Show-LMStepParamsClient {
    try {
    Clear-LMContent
    Add-LMPageTitle 'Parameters > B-core Client'

    $p = $global:LMGui_Content
    $y = 65

    $p.Controls.Add((New-LMLabel 'Server URL *' 20 $y))
    $y += 20
    $script:_CL_tbUrl = New-LMTextBox $global:LMGui_State['ServerUrl'] 20 $y 540
    $p.Controls.Add($script:_CL_tbUrl)
    $script:_CL_errUrl = New-LMErrorLabel 20 ($y + 22) 540
    $p.Controls.Add($script:_CL_errUrl)
    $hUrl = New-LMLabel 'Full HTTPS URL of the LegacyMCP server  (e.g. https://server.domain.local:8000/mcp)' 20 ($y + 40) 540
    $hUrl.ForeColor = [System.Drawing.Color]::Gray
    $p.Controls.Add($hUrl)
    $y += 62

    $p.Controls.Add((New-LMLabel 'CA Certificate *' 20 $y))
    $y += 20
    $script:_CL_tbCaCert = New-LMTextBox $global:LMGui_State['CaCertPath'] 20 $y 444
    $p.Controls.Add($script:_CL_tbCaCert)
    $script:_CL_btnBrowseCaCert = [System.Windows.Forms.Button]::new()
    $script:_CL_btnBrowseCaCert.Text     = 'Browse...'
    $script:_CL_btnBrowseCaCert.Location = [System.Drawing.Point]::new(472, $y - 1)
    $script:_CL_btnBrowseCaCert.Size     = [System.Drawing.Size]::new(80, 24)
    $script:_CL_btnBrowseCaCert.Font     = [System.Drawing.Font]::new('Tahoma', 7)
    $script:_CL_btnBrowseCaCert.Add_Click({
        $ofd = [System.Windows.Forms.OpenFileDialog]::new()
        $ofd.Filter = 'Certificate|*.crt;*.pem|All files|*.*'
        $ofd.Title  = 'Select CA certificate file'
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:_CL_tbCaCert.Text = $ofd.FileName
        }
        $ofd.Dispose()
    })
    $p.Controls.Add($script:_CL_btnBrowseCaCert)
    $script:_CL_errCert = New-LMErrorLabel 20 ($y + 22) 540
    $p.Controls.Add($script:_CL_errCert)
    $hCert = New-LMLabel 'Server certificate file provided by the server administrator.' 20 ($y + 40) 540
    $hCert.ForeColor = [System.Drawing.Color]::Gray
    $p.Controls.Add($hCert)
    $y += 62

    $p.Controls.Add((New-LMLabel 'API Key *' 20 $y))
    $y += 20
    # Plain-text in LMGui_State during wizard session (WinForms limitation; CLI uses SecureString). Cleared after use.
    $script:_CL_tbApiKey = New-LMTextBox '' 20 $y 540 -Password
    $p.Controls.Add($script:_CL_tbApiKey)
    $script:_CL_errKey = New-LMErrorLabel 20 ($y + 22) 540
    $p.Controls.Add($script:_CL_errKey)
    $hKey = New-LMLabel 'API key provided by the server administrator.' 20 ($y + 40) 540
    $hKey.ForeColor = [System.Drawing.Color]::Gray
    $p.Controls.Add($hKey)

    $global:LMGui_BtnBack.Enabled = $true
    $global:LMGui_BtnNext.Text    = 'Next >'
    $global:LMGui_BtnNext.Enabled = $true

    $global:LMGui_NextAction = {
        $ok = $true
        $script:_CL_errUrl.Text  = ''
        $script:_CL_errCert.Text = ''
        $script:_CL_errKey.Text  = ''

        if ([string]::IsNullOrWhiteSpace($script:_CL_tbUrl.Text)) {
            $script:_CL_errUrl.Text = 'Server URL is required.'; $ok = $false
        } elseif (-not $script:_CL_tbUrl.Text.Trim().StartsWith('https://')) {
            $script:_CL_errUrl.Text = 'Server URL must start with https://.'; $ok = $false
        }
        if ([string]::IsNullOrWhiteSpace($script:_CL_tbCaCert.Text)) {
            $script:_CL_errCert.Text = 'CA Certificate path is required.'; $ok = $false
        } elseif (-not (Test-Path $script:_CL_tbCaCert.Text.Trim())) {
            $script:_CL_errCert.Text = 'Certificate file not found.'; $ok = $false
        }
        if ([string]::IsNullOrWhiteSpace($script:_CL_tbApiKey.Text)) {
            $script:_CL_errKey.Text = 'API Key is required.'; $ok = $false
        }
        if (-not $ok) { return }

        $global:LMGui_State['ServerUrl']    = $script:_CL_tbUrl.Text.Trim()
        $global:LMGui_State['CaCertPath']   = $script:_CL_tbCaCert.Text.Trim()
        $global:LMGui_State['ClientApiKey'] = $script:_CL_tbApiKey.Text
        & $global:LMGui_NavFn
    }
    } catch { Write-Warning "GUI: error building step screen: $_" }
}

# ---------------------------------------------------------------------------
# Step: Parameters -- Configure, Profile B-core (Server)
# ---------------------------------------------------------------------------

function Show-LMStepParamsConfigure {
    try {
    Clear-LMContent
    Add-LMPageTitle 'Parameters > Configure Profile B-core'

    $p = $global:LMGui_Content
    $y = 65

    $note = New-LMLabel 'Leave any field blank to keep the current value. Every change requires a service restart.' 20 $y 560
    $note.ForeColor = [System.Drawing.Color]::Gray
    $p.Controls.Add($note); $y += 28

    # Port and Snapshot
    $gbPath = New-LMGroupBox 'Port and Paths' 20 $y 560 74
    $gbPath.Controls.Add((New-LMLabel 'Port' 8 18 60))
    $script:_C_tbPort = New-LMTextBox '' 8 40 80
    $gbPath.Controls.Add($script:_C_tbPort)
    $gbPath.Controls.Add((New-LMLabel 'Snapshot Path' 100 18 140))
    $script:_C_tbSnap = New-LMTextBox '' 100 40 448
    $gbPath.Controls.Add($script:_C_tbSnap)
    $p.Controls.Add($gbPath); $y += 82

    # API Key
    $gbAk = New-LMGroupBox 'API Key' 20 $y 560 76
    $rbAkNone   = New-LMRadio 'No change' 8 16 $true 130
    $script:_C_rbAkRotate = New-LMRadio 'Rotate  (generate new key -- invalidates all clients)' 150 16 $false 380
    $script:_C_rbAkMan    = New-LMRadio 'Set manually:' 8 40 $false 130
    $script:_C_tbAkMan    = New-LMTextBox '' 150 38 380; $script:_C_tbAkMan.Enabled = $false
    $script:_C_rbAkMan.Add_CheckedChanged({ $script:_C_tbAkMan.Enabled = $script:_C_rbAkMan.Checked })
    $gbAk.Controls.Add($rbAkNone); $gbAk.Controls.Add($script:_C_rbAkRotate)
    $gbAk.Controls.Add($script:_C_rbAkMan);  $gbAk.Controls.Add($script:_C_tbAkMan)
    $p.Controls.Add($gbAk); $y += 84

    # TLS Certificate
    $gbTls = New-LMGroupBox 'TLS Certificate' 20 $y 560 108
    $rbTlsNone   = New-LMRadio 'No change' 8 16 $true 130
    $script:_C_rbTlsRegen  = New-LMRadio 'Regenerate self-signed  (clients must import new CA)' 150 16 $false 390
    $script:_C_rbTlsImp    = New-LMRadio 'Import external certificate:' 8 40 $false 200
    $script:_C_tbTlsCrt    = New-LMTextBox '' 8 62 250; $script:_C_tbTlsCrt.Enabled = $false
    $script:_C_tbTlsKey    = New-LMTextBox '' 265 62 280; $script:_C_tbTlsKey.Enabled = $false
    $script:_C_errTls      = New-LMErrorLabel 8 88 540; $gbTls.Controls.Add($script:_C_errTls)
    $script:_C_rbTlsImp.Add_CheckedChanged({ $script:_C_tbTlsCrt.Enabled = $script:_C_rbTlsImp.Checked; $script:_C_tbTlsKey.Enabled = $script:_C_rbTlsImp.Checked })
    $gbTls.Controls.Add($rbTlsNone); $gbTls.Controls.Add($script:_C_rbTlsRegen)
    $gbTls.Controls.Add($script:_C_rbTlsImp);  $gbTls.Controls.Add($script:_C_tbTlsCrt); $gbTls.Controls.Add($script:_C_tbTlsKey)
    $p.Controls.Add($gbTls)

    $global:LMGui_BtnBack.Enabled = $true
    $global:LMGui_BtnNext.Text    = 'Next >'
    $global:LMGui_BtnNext.Enabled = $true

    $global:LMGui_NextAction = {
        $ok = $true; $script:_C_errTls.Text = ''
        $portTxt = $script:_C_tbPort.Text.Trim()
        if ($portTxt -ne '') {
            $portInt = 0
            if (-not [int]::TryParse($portTxt, [ref]$portInt) -or $portInt -lt 1024 -or $portInt -gt 65535) {
                [System.Windows.Forms.MessageBox]::Show('Port must be 1024-65535 or blank.','Validation','OK','Warning') | Out-Null
                $ok = $false
            }
        }
        if ($script:_C_rbTlsImp.Checked) {
            if (-not (Test-Path $script:_C_tbTlsCrt.Text) -or -not (Test-Path $script:_C_tbTlsKey.Text)) {
                $script:_C_errTls.Text = 'Certificate file(s) not found.'; $ok = $false
            }
        }
        if (-not $ok) { return }
        $global:LMGui_State['CfgPort']         = $portTxt
        $global:LMGui_State['CfgSnapshotPath'] = $script:_C_tbSnap.Text.Trim()
        $global:LMGui_State['CfgApiKeyMode']   = if ($script:_C_rbAkRotate.Checked) { 'rotate' } elseif ($script:_C_rbAkMan.Checked) { 'manual' } else { 'none' }
        $global:LMGui_State['CfgApiKeyValue']  = $script:_C_tbAkMan.Text.Trim()
        $global:LMGui_State['CfgCertMode']     = if ($script:_C_rbTlsRegen.Checked) { 'rotate' } elseif ($script:_C_rbTlsImp.Checked) { 'import' } else { 'none' }
        $global:LMGui_State['CfgCertFile']     = $script:_C_tbTlsCrt.Text.Trim()
        $global:LMGui_State['CfgCertKeyFile']  = $script:_C_tbTlsKey.Text.Trim()
        & $global:LMGui_NavFn
    }
    } catch { Write-Warning "GUI: error building step screen: $_" }
}

# ---------------------------------------------------------------------------
# Step 3D -- Options: Uninstall
# ---------------------------------------------------------------------------

function Show-LMStepParamsUninstall {
    try {
    Clear-LMContent
    Add-LMPageTitle 'Options > Uninstall'

    $p = $global:LMGui_Content
    $y = 65

    $lbWhat = [System.Windows.Forms.Label]::new()
    $lbWhat.Text     = "The following components will be removed:"
    $lbWhat.Location = [System.Drawing.Point]::new(20, $y)
    $lbWhat.AutoSize = $true
    $lbWhat.Font     = [System.Drawing.Font]::new('Tahoma', 8)
    $p.Controls.Add($lbWhat); $y += 22

    $uninstProfile = $global:LMGui_State['Profile']
    $uninstItems = if ($uninstProfile -eq 'A') {
        @(
            'Registry entries (HKCU)',
            'Install directory and config  (only with Purge)'
        )
    } else {
        @(
            'Windows service (LegacyMCP)',
            'Install directory  (venv + nssm.exe)',
            'Firewall rule and EventLog source',
            'Registry entries preserved unless Purge is selected'
        )
    }
    foreach ($item in $uninstItems) {
        $li = New-LMLabel "    $([char]0x2022) $item" 20 $y 520
        $p.Controls.Add($li); $y += 18
    }
    $y += 10

    $script:_U_cbPurge = New-LMCheckBox 'Also remove all data and configuration  (Purge)' 20 $y ($global:LMGui_State['Purge'] -eq $true) 440
    $p.Controls.Add($script:_U_cbPurge); $y += 22

    $hintPurge = New-LMLabel 'Purge removes: config.yaml, logs, snapshots, TLS certificates, API key. Cannot be undone.' 40 $y 500
    $hintPurge.ForeColor = [System.Drawing.Color]::Gray
    $p.Controls.Add($hintPurge); $y += 26

    # Profile A note: Purge is tracked but full purge support is in task #114
    if ($global:LMGui_State['Profile'] -eq 'A') {
        $noteA = New-LMLabel 'Note: Purge for Profile A will remove config.yaml and data folder. (task #114)' 20 $y 540
        $noteA.ForeColor = [System.Drawing.Color]::Gray
        $p.Controls.Add($noteA); $y += 20
    }

    $warnBox = [System.Windows.Forms.Label]::new()
    $warnBox.Text = 'The service will be stopped automatically before uninstallation begins.'
    if ($global:LMGui_State['Profile'] -eq 'A') { $warnBox.Text = 'Registry entries and local files will be removed.' }
    $warnBox.Location  = [System.Drawing.Point]::new(20, $y + 8)
    $warnBox.Size      = [System.Drawing.Size]::new(540, 20)
    $warnBox.Font      = [System.Drawing.Font]::new('Tahoma', 8, [System.Drawing.FontStyle]::Bold)
    $warnBox.ForeColor = [System.Drawing.Color]::FromArgb(150, 0, 0)
    $p.Controls.Add($warnBox)

    $global:LMGui_BtnBack.Enabled = $true
    $global:LMGui_BtnNext.Text    = 'Uninstall'
    $global:LMGui_BtnNext.ForeColor = $global:LMGui_CL.Accent
    $global:LMGui_BtnNext.Font      = [System.Drawing.Font]::new('Tahoma', 9, [System.Drawing.FontStyle]::Bold)
    $global:LMGui_BtnNext.Enabled   = $true

    $global:LMGui_NextAction = {
        $global:LMGui_State['Purge'] = $script:_U_cbPurge.Checked
        & $global:LMGui_NavFn
    }
    } catch { Write-Warning "GUI: error building step screen: $_" }
}

# ---------------------------------------------------------------------------
# Step 4 -- Summary
# ---------------------------------------------------------------------------

function Show-LMStepSummary {
    try {
    Clear-LMContent

    $mode      = $global:LMGui_State['Mode']
    $profile   = $global:LMGui_State['Profile']
    $role      = $global:LMGui_State['Role']
    $profLabel = if ($role -ne '') { "$profile $role" } else { $profile }
    Add-LMPageTitle "Summary > $mode > $profLabel"

    $p = $global:LMGui_Content
    $y = 58

    # Build summary rows
    $rows = [System.Collections.Generic.List[string[]]]::new()
    $rows.Add([string[]]@('Operation', $mode))
    $rows.Add([string[]]@('Profile',   $profLabel))

    if ($mode -eq 'Install' -and $profile -eq 'B-core' -and $role -eq 'Server') {
        $rows.Add([string[]]@('Service Account', $global:LMGui_State['ServiceAccount']))
        $keepCred = [bool]$global:LMGui_State['KeepCredentials']
        $portDisp = if ($global:LMGui_State['Port'] -ne '') { $global:LMGui_State['Port'] } else { '8000 (default)' }
        $snapDisp = if ($global:LMGui_State['SnapshotPath'] -ne '') { $global:LMGui_State['SnapshotPath'] } else { 'Default' }
        $apiDisp  = if ($keepCred) { 'Kept (unchanged)' } elseif ($global:LMGui_State['ApiKeyMode'] -eq 'manual') { 'Manual (provided)' } else { 'Auto-generate' }
        $certDisp = if ($keepCred) { 'Kept (unchanged)' } elseif ($global:LMGui_State['CertMode'] -eq 'import') { 'Import external' } else { 'Auto self-signed' }
        $devDisp  = if ($global:LMGui_State['DevInstall']) { 'Yes (from source tree)' } else { 'No (from PyPI)' }
        $rows.Add([string[]]@('Port',            $portDisp))
        $rows.Add([string[]]@('Snapshot Path',   $snapDisp))
        $rows.Add([string[]]@('API Key',         $apiDisp))
        $rows.Add([string[]]@('TLS Certificate', $certDisp))
        $rows.Add([string[]]@('Dev install',     $devDisp))
        if ($global:LMGui_State['ExistingVersion']) {
            $rows.Add([string[]]@('Existing install', $global:LMGui_State['ExistingVersion']))
            $credDisp = if ($global:LMGui_State['KeepCredentials']) { 'Keep existing' } else { 'Regenerate' }
            $rows.Add([string[]]@('Credentials', $credDisp))
        }
    } elseif ($mode -eq 'Install' -and $profile -eq 'B-core' -and $role -eq 'Client') {
        $urlDisp    = $global:LMGui_State['ServerUrl']
        $certDisp   = $global:LMGui_State['CaCertPath']
        $keyPreview = $global:LMGui_State['ClientApiKey']
        $keyDisp    = if ($keyPreview.Length -ge 8) { "$($keyPreview.Substring(0,8))..." } else { '(provided)' }
        $rows.Add([string[]]@('Server URL',     $urlDisp))
        $rows.Add([string[]]@('CA Certificate', $certDisp))
        $rows.Add([string[]]@('API Key',        $keyDisp))
    } elseif ($mode -eq 'Install' -and $profile -eq 'A') {
        $dataDisp = if ($global:LMGui_State['DataPath'] -ne '') { $global:LMGui_State['DataPath'] } else { 'Default (Documents\LegacyMCP-Data)' }
        $rows.Add([string[]]@('Data folder', $dataDisp))
    } elseif ($mode -eq 'Configure') {
        if ($global:LMGui_State['CfgPort']         -ne '') { $rows.Add([string[]]@('Port change',   $global:LMGui_State['CfgPort'])) }
        if ($global:LMGui_State['CfgSnapshotPath'] -ne '') { $rows.Add([string[]]@('Snapshot path', $global:LMGui_State['CfgSnapshotPath'])) }
        $rows.Add([string[]]@('API Key',     $global:LMGui_State['CfgApiKeyMode']))
        $rows.Add([string[]]@('Certificate', $global:LMGui_State['CfgCertMode']))
    } elseif ($mode -eq 'Uninstall') {
        $purgeDisp = if ($global:LMGui_State['Purge']) { 'YES -- removes all data' } else { 'No (data preserved)' }
        $rows.Add([string[]]@('Purge', $purgeDisp))
    }

    $lv = [System.Windows.Forms.ListView]::new()
    $lv.Location  = [System.Drawing.Point]::new(20, $y)
    $lv.Size      = [System.Drawing.Size]::new(560, ($rows.Count * 20 + 28))
    $lv.View      = [System.Windows.Forms.View]::Details
    $lv.FullRowSelect = $true
    $lv.GridLines = $true
    $lv.Font      = [System.Drawing.Font]::new('Tahoma', 8)
    $lv.Columns.Add('Setting', 150) | Out-Null
    $lv.Columns.Add('Value',   400) | Out-Null
    foreach ($r in $rows) {
        $lv.Items.Add([System.Windows.Forms.ListViewItem]::new($r)) | Out-Null
    }
    $p.Controls.Add($lv)
    $y += $lv.Height + 12

    if ($mode -eq 'Uninstall' -and $global:LMGui_State['Purge']) {
        $warn = [System.Windows.Forms.Label]::new()
        $warn.Text      = "WARNING: Purge will permanently delete all data and configuration."
        $warn.Location  = [System.Drawing.Point]::new(20, $y)
        $warn.Size      = [System.Drawing.Size]::new(560, 20)
        $warn.ForeColor = [System.Drawing.Color]::Red
        $warn.Font      = [System.Drawing.Font]::new('Tahoma', 8, [System.Drawing.FontStyle]::Bold)
        $p.Controls.Add($warn)
    }

    $global:LMGui_BtnBack.Enabled   = $true
    $actionLabel = switch ($mode) { 'Install' { 'Install' } 'Configure' { 'Configure' } default { 'Uninstall' } }
    $global:LMGui_BtnNext.Text      = $actionLabel
    $global:LMGui_BtnNext.ForeColor = $global:LMGui_CL.Accent
    $global:LMGui_BtnNext.Font      = [System.Drawing.Font]::new('Tahoma', 9, [System.Drawing.FontStyle]::Bold)
    if ($mode -eq 'Configure') {
        $global:LMGui_BtnBack.Location = [System.Drawing.Point]::new(420, 10)
        $global:LMGui_BtnNext.Size     = [System.Drawing.Size]::new(90, 28)
        $global:LMGui_BtnNext.Location = [System.Drawing.Point]::new(510, 10)
        $global:LMGui_BtnNext.Font     = [System.Drawing.Font]::new('Tahoma', 8, [System.Drawing.FontStyle]::Bold)
    } else {
        $global:LMGui_BtnBack.Location = [System.Drawing.Point]::new(440, 10)
        $global:LMGui_BtnNext.Size     = [System.Drawing.Size]::new(72, 28)
        $global:LMGui_BtnNext.Location = [System.Drawing.Point]::new(528, 10)
    }
    $global:LMGui_BtnNext.Enabled   = $true

    $global:LMGui_NextAction = {
        & $global:LMGui_NavFn
    }
    } catch { Write-Warning "GUI: error building step screen: $_" }
}

# ---------------------------------------------------------------------------
# Step 5 -- Executing
# ---------------------------------------------------------------------------

function Show-LMStepComplete {
    try {
    Clear-LMContent
    $mode      = $global:LMGui_State['Mode']
    $profile   = $global:LMGui_State['Profile']
    $role      = $global:LMGui_State['Role']
    $profLabel = $profile
    if ($role -ne '') { $profLabel = "$profile $role" }
    Add-LMPageTitle "Complete > $mode > $profLabel"

    $p = $global:LMGui_Content
    $y = 65

    $msgTxt = if ($global:LMGui_ExecSuccess) { "$mode completed successfully." } else { "$mode failed. Review the log in the previous step." }
    $msgLbl = [System.Windows.Forms.Label]::new()
    $msgLbl.Text      = $msgTxt
    $msgLbl.Location  = [System.Drawing.Point]::new(20, $y)
    $msgLbl.Size      = [System.Drawing.Size]::new(560, 24)
    $msgLbl.Font      = [System.Drawing.Font]::new('Tahoma', 10, [System.Drawing.FontStyle]::Bold)
    $msgLbl.ForeColor = if ($global:LMGui_ExecSuccess) { [System.Drawing.Color]::FromArgb(0,120,0) } else { [System.Drawing.Color]::FromArgb(255,51,51) }
    $p.Controls.Add($msgLbl); $y += 34

    if ($global:LMGui_ExecSuccess -and $mode -eq 'Install' -and $profile -eq 'B-core' -and $role -eq 'Server') {
        $portFin = if ($global:LMGui_State['Port'] -ne '') { $global:LMGui_State['Port'] } else { '8000' }
        $verFin  = $global:LMGui_State['INSTALLER_VERSION']
        $infos = @(
            @('Service',   'LegacyMCP (Running)'),
            @('Port',      $portFin),
            @('Installer', "v$verFin")
        )
        if ($global:LMGui_NewApiKey -ne '') {
            $infos += @(@('API Key', "$($global:LMGui_NewApiKey.Substring(0,[Math]::Min(8,$global:LMGui_NewApiKey.Length)))... (see log above)"))
            $global:LMGui_NewApiKey = ''
        }
        foreach ($r in $infos) {
            $lbK = New-LMLabel "$($r[0]):" 20 $y 120; $lbK.Font = [System.Drawing.Font]::new('Tahoma', 8, [System.Drawing.FontStyle]::Bold)
            $lbV = New-LMLabel $r[1] 148 $y 400
            $p.Controls.Add($lbK); $p.Controls.Add($lbV); $y += 20
        }
    } elseif ($global:LMGui_ExecSuccess -and $mode -eq 'Install' -and $profile -eq 'A') {
        $note = New-LMLabel 'Restart Claude Desktop to activate LegacyMCP.' 20 $y 540
        $note.Font = [System.Drawing.Font]::new('Tahoma', 9, [System.Drawing.FontStyle]::Bold)
        $p.Controls.Add($note)
    } elseif ($global:LMGui_ExecSuccess -and $mode -eq 'Install' -and $profile -eq 'B-core' -and $role -eq 'Client') {
        $note = New-LMLabel 'Restart Claude Desktop to activate LegacyMCP.' 20 $y 540
        $note.Font = [System.Drawing.Font]::new('Tahoma', 9, [System.Drawing.FontStyle]::Bold)
        $p.Controls.Add($note)
    }

    $global:LMGui_BtnBack.Enabled   = $false
    $global:LMGui_BtnNext.Enabled   = $false
    $global:LMGui_BtnCancel.Enabled = $false
    $global:LMGui_BtnNext.Text      = 'Finish'
    $global:LMGui_BtnNext.Enabled   = $true
    $global:LMGui_NextAction = {
        $global:LMGui_WizardOk = $global:LMGui_ExecSuccess
        $global:LMGui_Form.Close()
    }
    } catch { Write-Warning "GUI: error building step screen: $_" }
}

# ---------------------------------------------------------------------------
# Navigation
# ---------------------------------------------------------------------------
