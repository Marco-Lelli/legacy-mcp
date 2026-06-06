# LegacyMCP.Gui.Exec.psm1 -- wizard execution engine
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'LegacyMCP.Gui.psm1') -Force -WarningAction SilentlyContinue

function Show-LMStepExecuting {
    Clear-LMContent
    Add-LMPageTitle 'Executing'

    $p = $global:LMGui_Content

    # GIF + step label row
    $gifPanel = [System.Windows.Forms.Panel]::new()
    $gifPanel.Location    = [System.Drawing.Point]::new(20, 56)
    $gifPanel.Size        = [System.Drawing.Size]::new(76, 76)
    $gifPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
    $gifPanel.BackColor   = [System.Drawing.Color]::Black

    $global:LMGui_GifBox = [System.Windows.Forms.PictureBox]::new()
    $global:LMGui_GifBox.Size     = [System.Drawing.Size]::new(68, 68)
    $global:LMGui_GifBox.Location = [System.Drawing.Point]::new(3, 3)
    $global:LMGui_GifBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $global:LMGui_GifBox.BackColor = [System.Drawing.Color]::Black
    if ($global:LMGui_ImgGifOk) { $global:LMGui_GifBox.Image = $global:LMGui_ImgGifOk }
    $gifPanel.Controls.Add($global:LMGui_GifBox)
    $p.Controls.Add($gifPanel)

    $global:LMGui_StepLabel = [System.Windows.Forms.Label]::new()
    $global:LMGui_StepLabel.Text     = 'Starting...'
    $global:LMGui_StepLabel.Location = [System.Drawing.Point]::new(108, 64)
    $global:LMGui_StepLabel.Size     = [System.Drawing.Size]::new(462, 36)
    $global:LMGui_StepLabel.Font     = [System.Drawing.Font]::new('Tahoma', 8)
    $p.Controls.Add($global:LMGui_StepLabel)

    # Log RichTextBox
    $global:LMGui_LogBox = [System.Windows.Forms.RichTextBox]::new()
    $global:LMGui_LogBox.Location  = [System.Drawing.Point]::new(20, 140)
    $global:LMGui_LogBox.Size      = [System.Drawing.Size]::new(560, 260)
    $global:LMGui_LogBox.BackColor = $global:LMGui_CL.LogBg
    $global:LMGui_LogBox.ForeColor = $global:LMGui_CL.LogInfo
    $global:LMGui_LogBox.ReadOnly  = $true
    $global:LMGui_LogBox.Font      = [System.Drawing.Font]::new('Consolas', 8)
    $global:LMGui_LogBox.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
    $p.Controls.Add($global:LMGui_LogBox)

    # Progress label
    $progLabel = New-LMLabel 'Overall progress:' 20 408 200
    $p.Controls.Add($progLabel)

    # Custom progress bar (block style)
    $global:LMGui_ProgPanel = [System.Windows.Forms.Panel]::new()
    $global:LMGui_ProgPanel.Location  = [System.Drawing.Point]::new(20, 432)
    $global:LMGui_ProgPanel.Size      = [System.Drawing.Size]::new(560, 16)
    $global:LMGui_ProgPanel.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $progTag = @{ Current = 0; Max = 1 }
    $global:LMGui_ProgPanel.Tag = $progTag
    $global:LMGui_ProgPanel.Add_Paint({
        param($s, $e)
        $tag = $s.Tag
        $max = if ($tag.Max -gt 0) { $tag.Max } else { 1 }
        $pct = [Math]::Min($tag.Current / $max, 1.0)
        $filled = [int]($s.Width * $pct)
        $blockW = 9; $gapW = 2; $x = 0
        $col1 = if ($global:LMGui_ExecSuccess -or $tag.Current -lt $tag.Max) { $global:LMGui_CL.Accent   } else { [System.Drawing.Color]::FromArgb(136,0,0) }
        $col2 = if ($global:LMGui_ExecSuccess -or $tag.Current -lt $tag.Max) { $global:LMGui_CL.AccentDk } else { [System.Drawing.Color]::FromArgb( 85,0,0) }
        $br1 = [System.Drawing.SolidBrush]::new($col1)
        $br2 = [System.Drawing.SolidBrush]::new($col2)
        while ($x + $blockW -le $filled) {
            $e.Graphics.FillRectangle($br1, $x, 0, $blockW, $s.Height)
            if ($x + $blockW + $gapW -le $filled) { $e.Graphics.FillRectangle($br2, $x + $blockW, 0, $gapW, $s.Height) }
            $x += $blockW + $gapW
        }
        $br1.Dispose(); $br2.Dispose()
    })
    $p.Controls.Add($global:LMGui_ProgPanel)

    # Disable navigation during execution
    $global:LMGui_BtnBack.Enabled   = $false
    $global:LMGui_BtnNext.Enabled   = $false
    $global:LMGui_BtnCancel.Enabled = $false

    # Set step total
    $role    = $global:LMGui_State['Role']
    $modeKey = "$($global:LMGui_State['Mode'])-$($global:LMGui_State['Profile'])$(if ($role -ne '') { "-$role" })"
    $global:LMGui_StepTotal = if ($global:LMGui_StepTotals.ContainsKey($modeKey)) { $global:LMGui_StepTotals[$modeKey] } else { 10 }
    $global:LMGui_StepCount = 0
    $global:LMGui_ExecSuccess = $false

    # Launch async execution
    $global:LMGui_Queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $execData = Start-LMExecution -State $global:LMGui_State `
        -Queue $global:LMGui_Queue `
        -ModulesDir $global:LMGui_ModulesDir `
        -ScriptDir  $global:LMGui_ScriptDir `
        -RepoRoot   $global:LMGui_RepoRoot
    $global:LMGui_ExecPS    = $execData.PS
    $global:LMGui_ExecRS    = $execData.RS
    $global:LMGui_ExecAsync = $execData.Async

    # Timer to drain the queue
    $global:LMGui_ExecTimer = [System.Windows.Forms.Timer]::new()
    $global:LMGui_ExecTimer.Interval = 100
    $global:LMGui_ExecTimer.Add_Tick({
        $item = [string]''
        while ($global:LMGui_Queue.TryDequeue([ref]$item)) {
            if ($item.StartsWith('STEP:')) {
                $msg = $item.Substring(5)
                $global:LMGui_StepCount++
                $tag = $global:LMGui_ProgPanel.Tag
                $tag.Current = $global:LMGui_StepCount
                $tag.Max     = $global:LMGui_StepTotal
                $global:LMGui_ProgPanel.Refresh()
                $n = $global:LMGui_StepCount; $m = $global:LMGui_StepTotal
                $global:LMGui_StepLabel.Text = "Step $n of $m -- $msg"
                Add-LMLogLine "==> $msg" $global:LMGui_CL.LogStep $true
            } elseif ($item.StartsWith('OK:')) {
                Add-LMLogLine "  [OK]   $($item.Substring(3))" $global:LMGui_CL.LogOk $false
            } elseif ($item.StartsWith('WARN:')) {
                Add-LMLogLine "  [WARN] $($item.Substring(5))" $global:LMGui_CL.LogWarn $false
            } elseif ($item.StartsWith('INFO:')) {
                Add-LMLogLine "  [INFO] $($item.Substring(5))" $global:LMGui_CL.LogInfo $false
            } elseif ($item.StartsWith('FAIL:')) {
                Add-LMLogLine "  [FAIL] $($item.Substring(5))" $global:LMGui_CL.LogErr $true
            } elseif ($item.StartsWith('KEY:')) {
                $global:LMGui_NewApiKey = $item.Substring(4)
            } elseif ($item -eq 'DONE:success') {
                $global:LMGui_ExecSuccess = $true
            } elseif ($item -eq 'DONE:error') {
                $global:LMGui_ExecSuccess = $false
            }
        }

        # Check completion
        if ($global:LMGui_ExecAsync -and $global:LMGui_ExecAsync.IsCompleted) {
            $global:LMGui_ExecTimer.Stop()
            # Drain any remaining messages
            $item = [string]''
            while ($global:LMGui_Queue.TryDequeue([ref]$item)) {
                if ($item.StartsWith('STEP:'))     { Add-LMLogLine "==> $($item.Substring(5))" $global:LMGui_CL.LogStep $true }
                elseif ($item.StartsWith('OK:'))   { Add-LMLogLine "  [OK]   $($item.Substring(3))" $global:LMGui_CL.LogOk $false }
                elseif ($item.StartsWith('WARN:')) { Add-LMLogLine "  [WARN] $($item.Substring(5))" $global:LMGui_CL.LogWarn $false }
                elseif ($item.StartsWith('INFO:')) { Add-LMLogLine "  [INFO] $($item.Substring(5))" $global:LMGui_CL.LogInfo $false }
                elseif ($item.StartsWith('FAIL:')) { Add-LMLogLine "  [FAIL] $($item.Substring(5))" $global:LMGui_CL.LogErr $true }
                elseif ($item.StartsWith('KEY:'))  { $global:LMGui_NewApiKey = $item.Substring(4) }
                elseif ($item -eq 'DONE:success')  { $global:LMGui_ExecSuccess = $true }
                elseif ($item -eq 'DONE:error')    { $global:LMGui_ExecSuccess = $false }
            }
            # Finalize progress
            $tag = $global:LMGui_ProgPanel.Tag
            $tag.Current = if ($global:LMGui_ExecSuccess) { $tag.Max } else { $tag.Current }
            $global:LMGui_ProgPanel.Refresh()

            if ($global:LMGui_ExecSuccess) {
                $global:LMGui_StepLabel.Text    = 'Completed successfully.'
                $global:LMGui_BtnNext.Text      = 'Next >'
                $global:LMGui_BtnNext.Font      = [System.Drawing.Font]::new('Tahoma', 8)
                $global:LMGui_BtnNext.ForeColor = [System.Drawing.Color]::Empty
                $global:LMGui_BtnNext.Enabled   = $true
                $global:LMGui_NextAction        = { & $global:LMGui_NavFn }
            } else {
                if ($global:LMGui_ImgGifErr) { $global:LMGui_GifBox.Image = $global:LMGui_ImgGifErr }
                $global:LMGui_StepLabel.Text = 'Installation failed. See log for details.'
                $global:LMGui_BtnBack.Enabled   = $true
                $global:LMGui_BtnCancel.Enabled = $true
            }

            # Clean up runspace
            try { $global:LMGui_ExecPS.Dispose() } catch {}
            try { $global:LMGui_ExecRS.Close(); $global:LMGui_ExecRS.Dispose() } catch {}
            $global:LMGui_ExecPS = $null; $global:LMGui_ExecRS = $null; $global:LMGui_ExecAsync = $null
        }
    })
    $global:LMGui_ExecTimer.Start()
}

function Add-LMLogLine {
    param([string]$Text, [System.Drawing.Color]$Color, [bool]$Bold)
    $box = $global:LMGui_LogBox
    $box.SelectionStart  = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionColor  = $Color
    $box.SelectionFont   = [System.Drawing.Font]::new('Consolas', 8, $(if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }))
    $box.AppendText("$Text`n")
    $box.ScrollToCaret()
}

# ---------------------------------------------------------------------------
# Step 6 -- Complete
# ---------------------------------------------------------------------------

function Start-LMExecution {
    param(
        [hashtable]$State,
        $Queue,
        [string]$ModulesDir,
        [string]$ScriptDir,
        [string]$RepoRoot
    )

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.Open()

    $rs.SessionStateProxy.SetVariable('_Q',     $Queue)
    $rs.SessionStateProxy.SetVariable('_mdir',  $ModulesDir)
    $rs.SessionStateProxy.SetVariable('_sdir',  $ScriptDir)
    $rs.SessionStateProxy.SetVariable('_rroot', $RepoRoot)
    $rs.SessionStateProxy.SetVariable('_ws',    $State)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript({
        $Q    = $_Q
        $mdir = $_mdir
        $sdir = $_sdir
        $rroot = $_rroot
        $ws   = $_ws

        # Import all modules
        Import-Module (Join-Path $mdir 'LegacyMCP.Common.psm1')  -Force -Global
        Import-Module (Join-Path $mdir 'LegacyMCP.Python.psm1')  -Force
        Import-Module (Join-Path $mdir 'LegacyMCP.Service.psm1') -Force
        Import-Module (Join-Path $mdir 'LegacyMCP.Certs.psm1')   -Force
        Import-Module (Join-Path $mdir 'LegacyMCP.Config.psm1')  -Force
        Import-Module (Join-Path $mdir 'LegacyMCP.Client.psm1')  -Force
        Import-Module (Join-Path $mdir 'LegacyMCP.Gui.Exec.psm1') -Force -WarningAction SilentlyContinue

        # Override Write-LM* to push to queue (must be after all module imports)
        function global:Write-LMStep { param($Message) $Q.Enqueue("STEP:$Message") }
        function global:Write-LMOK   { param($Message) $Q.Enqueue("OK:$Message") }
        function global:Write-LMWarn { param($Message) $Q.Enqueue("WARN:$Message") }
        function global:Write-LMInfo { param($Message) $Q.Enqueue("INFO:$Message") }
        function global:Write-LMFail { param($Message) $Q.Enqueue("FAIL:$Message") }

        $INSTALLER_VERSION = $ws['INSTALLER_VERSION']
        $SERVICE_NAME = 'LegacyMCP'
        $MODE    = $ws['Mode']
        $PROFILE = $ws['Profile']
        $ROLE    = $ws['Role']

        # Safety net: no interactive prompts in GUI runspace.
        # Config overwrite decision is driven by $ws['PreserveConfig'] in Invoke-LMInstallBCore.
        $script:_wsPreserveConfig = [bool]$ws['PreserveConfig']
        function global:Read-Host {
            param([string]$Prompt = '', [switch]$AsSecureString)
            if ($Prompt -match '[Oo]verwrite') {
                if ($script:_wsPreserveConfig) { return 'N' } else { return 'Y' }
            }
            $Q.Enqueue("WARN:Read-Host called unexpectedly in GUI runspace: $Prompt")
            return ''
        }

        # --------------- Install B-core ---------------
        function Invoke-LMInstallBCore {
            param($ws, $sdir, $rroot, $SvcName, $Ver, $Q)
            $REG_ROOT    = 'HKLM:\SOFTWARE\LegacyMCP'
            $InstallPath = if ($ws['InstallPath'] -ne '') { $ws['InstallPath'] } else { "$env:ProgramFiles\LegacyMCP" }
            $ConfigPath  = if ($ws['ConfigPath']  -ne '') { $ws['ConfigPath']  } else { "$env:ProgramData\LegacyMCP\config\config.yaml" }
            $LogPath     = if ($ws['LogPath']     -ne '') { $ws['LogPath']     } else { "$env:ProgramData\LegacyMCP\logs" }
            $SnapPath    = if ($ws['SnapshotPath']-ne '') { $ws['SnapshotPath']} else { "$env:ProgramData\LegacyMCP\snapshots" }
            $Port        = if ($ws['Port']        -ne '') { [int]$ws['Port']   } else { 8000 }
            $CertDir     = "$env:ProgramData\LegacyMCP\certs"
            $NssmSource  = Join-Path $sdir 'tools\nssm.exe'
            $NssmExe     = Join-Path $InstallPath 'nssm.exe'
            $VenvPath    = Join-Path $InstallPath '.venv'
            $ServiceAccount = $ws['ServiceAccount']
            $SvcPwd      = $ws['ServiceAccountPassword']
            $DevInstall  = [bool]$ws['DevInstall']
            $Version     = $ws['Version']
            $KeepCred    = [bool]$ws['KeepCredentials']
            $ApiKeyMode  = $ws['ApiKeyMode']
            $CertMode    = $ws['CertMode']

            Write-LMStep "LegacyMCP Setup -- Profile B-core Server"

            # Detect existing + auto-stop service if running
            $existingVersion = $null
            if (Test-Path $REG_ROOT) {
                $rp = Get-ItemProperty -Path $REG_ROOT -ErrorAction SilentlyContinue
                $existingVersion = if ($rp -and $rp.InstalledVersion) { $rp.InstalledVersion } else { 'unknown' }
            }
            if ($existingVersion) {
                $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq 'Running') {
                    Write-LMInfo "Stopping service '$SvcName' before reinstall..."
                    Stop-Service -Name $SvcName -Force -ErrorAction Stop
                    Write-LMOK "Service '$SvcName' stopped."
                }
            }

            Write-LMStep 'Step 1 -- Python'
            $pythonExe = Find-LMPython
            $peLower   = $pythonExe.ToLower()
            if ($peLower.StartsWith($env:LOCALAPPDATA.ToLower()) -or $peLower.StartsWith($env:APPDATA.ToLower())) {
                throw "Python is installed for the current user only ('$pythonExe'). Profile B Server requires Python for all users."
            }
            Write-LMOK "Python found (system-wide): $pythonExe"

            Write-LMStep 'Step 2 -- Virtual environment'
            New-LMVenv -PythonExe $pythonExe -VenvPath $VenvPath
            $venvPython = Join-Path $VenvPath 'Scripts\python.exe'

            Write-LMStep 'Step 3 -- Package installation'
            $installMode = if ($DevInstall) { 'dev' } else { 'release' }
            if ($DevInstall) {
                if ($Version -ne '') { Write-LMWarn '-Version has no effect in DevInstall mode.' }
                if (-not (Test-Path (Join-Path $rroot 'pyproject.toml'))) {
                    throw '-DevInstall requires a source tree (pyproject.toml not found).'
                }
                Install-LMPackage -VenvPath $VenvPath -PackageOrPath $rroot -Editable
            } else {
                $pkg = if ($Version -ne '') { "legacy-mcp==$Version" } else { 'legacy-mcp' }
                Install-LMPackage -VenvPath $VenvPath -PackageOrPath $pkg
            }
            $InstalledVersion = 'dev-unknown'
            if ($DevInstall) {
                try { $h = & git -C $rroot rev-parse --short HEAD 2>&1; if ($LASTEXITCODE -eq 0) { $InstalledVersion = "dev-$($h.Trim())" } } catch {}
            } else {
                try { $po = & $venvPython -m pip show legacy-mcp 2>&1; $vl = $po | Select-String '^Version:'; if ($vl) { $InstalledVersion = ($vl.Line -replace 'Version:\s*','').Trim() } } catch {}
                if ($InstalledVersion -eq 'dev-unknown') { $InstalledVersion = $Ver }
            }
            Write-LMInfo "Package installed (mode: $installMode, version: $InstalledVersion)."

            Write-LMStep 'Step 4 -- Directories'
            foreach ($dir in @($InstallPath, (Split-Path $ConfigPath -Parent), $LogPath, $SnapPath, $CertDir)) {
                if (-not (Test-Path $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    Write-LMOK "Created: $dir"
                }
            }
            if (-not (Test-Path $NssmSource)) { throw "nssm.exe not found: $NssmSource" }
            Copy-Item -Path $NssmSource -Destination $NssmExe -Force
            Write-LMOK "nssm.exe copied to: $NssmExe"

            $fqdn = [System.Net.Dns]::GetHostEntry('').HostName

            Write-LMStep 'Step 5 -- TLS certificate'
            $keyPasswordBlob = $null
            $certResult = $null
            if ($KeepCred) {
                $certResult = @{ CertFile = (Join-Path $CertDir 'server.crt'); KeyFile = (Join-Path $CertDir 'server.key') }
                Write-LMOK 'Existing TLS certificate preserved.'
            } elseif ($CertMode -eq 'import') {
                $certResult = Import-LMCert -CertFile $ws['CertFile'] -CertKeyFile $ws['CertKeyFile'] -CertDir $CertDir
            } else {
                $certResult = New-LMSelfSignedCert -VenvPython $venvPython -CertDir $CertDir -Hostname $fqdn
                if ($certResult.KeyPassword) {
                    $keyPasswordBlob = Protect-LMKeyPasswordBlob -PlainText $certResult.KeyPassword -ServiceAccount $ServiceAccount
                    Write-LMOK 'TLS key password encrypted (DPAPI-NG, SID-scoped).'
                    $certResult.KeyPassword = $null; [System.GC]::Collect()
                }
            }

            Write-LMStep 'Step 6 -- API key'
            $displayApiKey = $null
            if ($KeepCred) {
                Write-LMOK 'API key preserved (existing DPAPI-NG entry retained).'
            } elseif ($ApiKeyMode -eq 'manual' -and $ws['ApiKeyValue'] -ne '') {
                $displayApiKey = $ws['ApiKeyValue']
                Protect-LMApiKey -ApiKey $ws['ApiKeyValue'] -ServiceAccount $ServiceAccount -RegistryRoot $REG_ROOT
                $ws['ApiKeyValue'] = $null
                Write-LMInfo 'API key stored (DPAPI-NG, SID-scoped). Provided manually.'
            } else {
                $newKey = New-LMApiKey
                $displayApiKey = $newKey
                Protect-LMApiKey -ApiKey $newKey -ServiceAccount $ServiceAccount -RegistryRoot $REG_ROOT
                Write-LMInfo 'API key stored (DPAPI-NG, SID-scoped). Auto-generated.'
                $newKey = $null
            }
            if ($displayApiKey) { $Q.Enqueue("KEY:$displayApiKey"); $displayApiKey = $null }

            Write-LMStep 'Step 7 -- Configuration'
            $templatePath = Join-Path $rroot 'config\config.example-B.yaml'
            if (-not (Test-Path $templatePath)) { throw "Config template not found: $templatePath" }
            if ((Test-Path $ConfigPath) -and [bool]$ws['PreserveConfig']) {
                Write-LMOK 'config.yaml preserved (existing configuration retained).'
            } else {
                Copy-Item $templatePath $ConfigPath -Force
                Write-LMOK 'config.yaml created from template.'
            }
            Set-LMRegistry -Key $REG_ROOT -Name 'ConfigPath' -Value $ConfigPath
            Update-LMYamlSslFields -YamlPath $ConfigPath -SslCertFile $certResult.CertFile -SslKeyFile $certResult.KeyFile -VenvPython $venvPython
            Write-LMOK 'ssl_certfile and ssl_keyfile updated.'
            Update-LMYamlPort -YamlPath $ConfigPath -Port $Port
            Write-LMOK "port updated in config.yaml: $Port"

            Write-LMStep 'Step 8 -- EventLog'
            Register-LMEventLog

            Write-LMStep 'Step 9 -- Windows service'
            Install-LMService -NssmExe $NssmExe -ServiceName $SvcName `
                -PythonExe $venvPython -ConfigPath $ConfigPath `
                -InstallPath $InstallPath -LogPath $LogPath `
                -ServiceAccount $ServiceAccount -Port $Port `
                -ServiceAccountPassword $SvcPwd

            try {
                Set-LMConfig -RegistryRoot $REG_ROOT -Name 'SnapshotPath' -Value $SnapPath
            } catch {
                Write-LMWarn "Failed to configure SnapshotPath: $_"
            }

            Write-LMStep 'Step 10 -- Firewall'
            Add-LMFirewallRule -Port $Port

            Write-LMStep 'Step 11 -- Registry'
            Set-LMRegistry -Key $REG_ROOT -Name 'InstallPath'      -Value $InstallPath
            Set-LMRegistry -Key $REG_ROOT -Name 'LogPath'          -Value $LogPath
            Set-LMRegistry -Key $REG_ROOT -Name 'Profile'          -Value 'B-core'
            Set-LMRegistry -Key $REG_ROOT -Name 'Transport'        -Value 'streamable-http'
            Set-LMRegistry -Key $REG_ROOT -Name 'Port'             -Value $Port -Type 'DWord'
            Set-LMRegistry -Key $REG_ROOT -Name 'Version'          -Value $Ver
            Set-LMRegistry -Key $REG_ROOT -Name 'InstallMode'      -Value $installMode
            Set-LMRegistry -Key $REG_ROOT -Name 'InstalledVersion' -Value $InstalledVersion
            Set-LMRegistry -Key $REG_ROOT -Name 'NssmPath'         -Value $NssmExe
            if ($keyPasswordBlob) { Set-LMRegistry -Key $REG_ROOT -Name 'KeyPasswordBlob' -Value $keyPasswordBlob }
            Write-LMOK 'Registry entries written.'

            Write-LMStep 'Step 12 -- Start service'
            Start-Service -Name $SvcName
            Write-LMOK "Service '$SvcName' started."

            Write-LMStep 'Setup complete'
            Write-LMOK "Profile B-core Server installation successful."
            Write-LMInfo "Service: $SvcName (Running)"
            Write-LMInfo "Port:    $Port"
        }

        # --------------- Install Profile A ---------------
        function Invoke-LMInstallA {
            param($ws, $rroot, $Ver)
            $REG_ROOT    = 'HKCU:\SOFTWARE\LegacyMCP'
            $InstallPath = "$env:LOCALAPPDATA\LegacyMCP"
            $ConfigPath  = "$env:LOCALAPPDATA\LegacyMCP\config\config.yaml"
            $DataPath    = if ($ws['DataPath'] -ne '') { $ws['DataPath'] } else { "$env:USERPROFILE\Documents\LegacyMCP-Data" }
            $VenvPath    = Join-Path $InstallPath '.venv'
            $DevInstall  = [bool]$ws['DevInstall']
            $Version     = if ($ws['Version']) { $ws['Version'] } else { '' }

            Write-LMStep 'LegacyMCP Setup -- Profile A'

            Write-LMStep 'Step 1 -- Python'
            $pythonExe = Find-LMPython
            Write-LMOK "Python found: $pythonExe"

            Write-LMStep 'Step 2 -- Directories'
            foreach ($dir in @($InstallPath, (Split-Path $ConfigPath -Parent), $DataPath)) {
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null; Write-LMOK "Created: $dir" }
            }

            Write-LMStep 'Step 3 -- Virtual environment'
            New-LMVenv -PythonExe $pythonExe -VenvPath $VenvPath
            $venvPython = Join-Path $VenvPath 'Scripts\python.exe'

            Write-LMStep 'Step 4 -- Package installation'
            $installMode = if ($DevInstall) { 'dev' } else { 'release' }
            if ($DevInstall) {
                if ($Version -ne '') { Write-LMWarn '-Version has no effect in DevInstall mode. The local source tree is used.' }
                if (-not (Test-Path (Join-Path $rroot 'pyproject.toml'))) {
                    throw '-DevInstall requires a source tree (pyproject.toml not found).'
                }
                Install-LMPackage -VenvPath $VenvPath -PackageOrPath $rroot -Editable
            } else {
                $pkg = if ($Version -ne '') { "legacy-mcp==$Version" } else { 'legacy-mcp' }
                Install-LMPackage -VenvPath $VenvPath -PackageOrPath $pkg
            }
            $InstalledVersion = 'dev-unknown'
            if ($DevInstall) {
                try { $h = & git -C $rroot rev-parse --short HEAD 2>&1; if ($LASTEXITCODE -eq 0) { $InstalledVersion = "dev-$($h.Trim())" } } catch {}
            } else {
                try { $po = & $venvPython -m pip show legacy-mcp 2>&1; $vl = $po | Select-String '^Version:'; if ($vl) { $InstalledVersion = ($vl.Line -replace 'Version:\s*','').Trim() } } catch {}
                if ($InstalledVersion -eq 'dev-unknown') { $InstalledVersion = $Ver }
            }
            Write-LMInfo "Package installed (mode: $installMode, version: $InstalledVersion)."

            Write-LMStep 'Step 5 -- Configuration'
            $templatePath = Join-Path $rroot 'config\config.example-A.yaml'
            if (-not (Test-Path $templatePath)) { throw "Config template not found: $templatePath" }
            if ((Test-Path $ConfigPath) -and [bool]$ws['PreserveConfig']) {
                Write-LMOK 'config.yaml preserved (existing configuration retained).'
            } else {
                Copy-Item $templatePath $ConfigPath -Force
                Write-LMOK 'config.yaml created from template.'
            }

            Write-LMStep 'Step 6 -- Claude Desktop configuration'
            $claudeConfigPath = Get-LMClaudeConfigPath
            try {
                Set-LMClaudeConfigProfileA -PythonExe $venvPython -ClaudeConfigPath $claudeConfigPath
                Write-LMOK "Claude Desktop config updated: $claudeConfigPath"
            } catch {
                Write-LMWarn "Could not write claude_desktop_config.json: $_"
                Write-LMInfo "Add the MCP server entry manually. See docs\getting-started-a.md."
            }

            Write-LMStep 'Step 7 -- Registry'
            try {
                Set-LMRegistry -Key $REG_ROOT -Name 'InstallPath' -Value $InstallPath
                Set-LMRegistry -Key $REG_ROOT -Name 'ConfigPath'  -Value $ConfigPath
                Set-LMRegistry -Key $REG_ROOT -Name 'Profile'     -Value 'A'
                Set-LMRegistry -Key $REG_ROOT -Name 'Transport'   -Value 'stdio'
                Set-LMRegistry -Key $REG_ROOT -Name 'Version'     -Value $Ver
                Set-LMRegistry -Key $REG_ROOT -Name 'InstalledVersion' -Value $InstalledVersion
                Write-LMOK 'Registry entries written.'
            } catch {
                Write-LMWarn "Could not write registry entries: $_  (non-blocking for Profile A)"
            }

            Write-LMStep 'Setup complete'
            Write-LMOK 'Profile A installation successful.'
            Write-LMInfo "Python:      $venvPython"
            Write-LMInfo "Config:      $ConfigPath"
            Write-LMInfo "Data folder: $DataPath"
            Write-LMInfo 'Restart Claude Desktop to activate LegacyMCP.'
        }

        # --------------- Configure B-core ---------------
        function Invoke-LMConfigure {
            param($ws)
            $REG_ROOT    = 'HKLM:\SOFTWARE\LegacyMCP'
            $SERVICE_NAME = 'LegacyMCP'
            $cfg         = Get-LMConfig -RegistryRoot $REG_ROOT
            $InstallPath = if ($cfg.ContainsKey('InstallPath')) { $cfg['InstallPath'] } else { "$env:ProgramFiles\LegacyMCP" }
            $ConfigPath  = if ($cfg.ContainsKey('ConfigPath'))  { $cfg['ConfigPath']  } else { "$env:ProgramData\LegacyMCP\config\config.yaml" }
            $CertDir     = "$env:ProgramData\LegacyMCP\certs"
            $venvPython  = Join-Path $InstallPath '.venv\Scripts\python.exe'
            $restartReq  = $false

            Write-LMStep "LegacyMCP Configure -- Profile B-core Server"

            # ServiceAccount (auto-detect from WMI)
            $ServiceAccount = $null
            try { $wmiSvc = Get-CimInstance Win32_Service -Filter "Name='LegacyMCP'" -ErrorAction SilentlyContinue; if ($wmiSvc) { $ServiceAccount = $wmiSvc.StartName } } catch {}

            if ($ws['CfgCertMode'] -eq 'import' -and $ws['CfgCertFile'] -ne '' -and $ws['CfgCertKeyFile'] -ne '') {
                Write-LMStep 'Updating TLS certificate'
                $certReplace = Invoke-LMReplaceCert -CertFile $ws['CfgCertFile'] -CertKeyFile $ws['CfgCertKeyFile'] -CertDir $CertDir -ConfigPath $ConfigPath -ServiceName $SERVICE_NAME -VenvPython $venvPython
                if ($certReplace.KeyPassword -and $ServiceAccount) {
                    $blob = Protect-LMKeyPasswordBlob -PlainText $certReplace.KeyPassword -ServiceAccount $ServiceAccount
                    Set-LMRegistry -Key $REG_ROOT -Name 'KeyPasswordBlob' -Value $blob
                    Write-LMOK 'TLS key password encrypted and KeyPasswordBlob updated.'
                }
                $restartReq = $true
            }

            if ($ws['CfgCertMode'] -eq 'rotate') {
                Write-LMStep 'Rotating TLS certificate'
                $fqdn = [System.Net.Dns]::GetHostEntry('').HostName
                $certNew = New-LMSelfSignedCert -VenvPython $venvPython -CertDir $CertDir -Hostname $fqdn
                if ($certNew.KeyPassword -and $ServiceAccount) {
                    $blob = Protect-LMKeyPasswordBlob -PlainText $certNew.KeyPassword -ServiceAccount $ServiceAccount
                    Set-LMRegistry -Key $REG_ROOT -Name 'KeyPasswordBlob' -Value $blob
                    Write-LMOK 'TLS key password encrypted and KeyPasswordBlob updated.'
                    $certNew.KeyPassword = $null; [System.GC]::Collect()
                }
                Update-LMYamlSslFields -YamlPath $ConfigPath -SslCertFile $certNew.CertFile -SslKeyFile $certNew.KeyFile -VenvPython $venvPython
                Write-LMOK 'ssl_certfile and ssl_keyfile updated.'
                Write-LMInfo 'Restarting service...'
                Restart-Service -Name $SERVICE_NAME -Force
                Write-LMOK 'Service restarted with new certificate.'
                Write-LMWarn "Distribute the new CA certificate to all clients: $($certNew.CertFile)"
                $restartReq = $false
            }

            if ($ws['CfgSnapshotPath'] -ne '') {
                Write-LMStep 'Updating snapshot path'
                Set-LMConfig -RegistryRoot $REG_ROOT -Name 'SnapshotPath' -Value $ws['CfgSnapshotPath']
                $restartReq = $true
            }

            if ($ws['CfgPort'] -ne '') {
                Write-LMStep 'Updating port'
                $newPort = [int]$ws['CfgPort']
                Set-LMConfig -RegistryRoot $REG_ROOT -Name 'Port' -Value "$newPort"
                Update-LMYamlPort -YamlPath $ConfigPath -Port $newPort
                Add-LMFirewallRule -Port $newPort
                Write-LMInfo "Restarting service on port $newPort..."
                Restart-Service -Name $SERVICE_NAME -Force
                Write-LMOK "Service restarted on port $newPort."
                $restartReq = $false
            }

            if ($ws['CfgApiKeyMode'] -eq 'manual' -and $ws['CfgApiKeyValue'] -ne '') {
                Write-LMStep 'Updating API key'
                if (-not $ServiceAccount) { throw 'Cannot determine service account for API key update. Check WMI service info.' }
                Protect-LMApiKey -ApiKey $ws['CfgApiKeyValue'] -ServiceAccount $ServiceAccount -RegistryRoot $REG_ROOT
                $ws['CfgApiKeyValue'] = $null
                Write-LMInfo 'API key updated (DPAPI-NG, SID-scoped).'
                $restartReq = $true
            }

            if ($ws['CfgApiKeyMode'] -eq 'rotate') {
                Write-LMStep 'Rotating API key'
                if (-not $ServiceAccount) { throw 'Cannot determine service account for API key rotation.' }
                $newKey = New-LMApiKey
                Protect-LMApiKey -ApiKey $newKey -ServiceAccount $ServiceAccount -RegistryRoot $REG_ROOT
                Write-LMOK 'New API key generated and stored.'
                $Q.Enqueue("KEY:$newKey"); $newKey = $null
                $restartReq = $true
            }

            Write-LMStep 'Configure complete'
            Write-LMOK 'Profile B-core Server configuration updated.'
            if ($restartReq) {
                Write-LMWarn 'Restart the service for changes to take effect: Restart-Service -Name LegacyMCP'
            }
        }

        # --------------- Uninstall B-core ---------------
        function Invoke-LMUninstallBCore {
            param($ws, $sdir)
            $REG_ROOT = 'HKLM:\SOFTWARE\LegacyMCP'
            $SvcName  = 'LegacyMCP'
            $cfg      = Get-LMConfig -RegistryRoot $REG_ROOT
            $InstallPath = if ($cfg.ContainsKey('InstallPath')) { $cfg['InstallPath'] } else { "$env:ProgramFiles\LegacyMCP" }
            $NssmExe  = if ($cfg.ContainsKey('NssmPath') -and (Test-Path $cfg['NssmPath'])) { $cfg['NssmPath'] } `
                         elseif (Test-Path (Join-Path $InstallPath 'nssm.exe')) { Join-Path $InstallPath 'nssm.exe' } `
                         else { Join-Path $sdir 'tools\nssm.exe' }
            $VenvPath = Join-Path $InstallPath '.venv'

            Write-LMStep "LegacyMCP Uninstall -- Profile B-core Server"
            Write-LMStep 'Step 1 -- Stop and remove service'
            Uninstall-LMService -NssmExe $NssmExe -ServiceName $SvcName -VenvPath $VenvPath -RegistryRoot $REG_ROOT
            Write-LMStep 'Step 2 -- Firewall rule'
            Remove-LMFirewallRule
            Write-LMStep 'Step 3 -- EventLog'
            Unregister-LMEventLog
            Write-LMStep 'Step 4 -- Binaries'
            if (Test-Path $InstallPath) {
                try { Remove-Item $InstallPath -Recurse -Force; Write-LMOK "Install directory removed: $InstallPath" } catch { Write-LMWarn "Could not remove '$InstallPath': $_" }
            }
            Write-LMStep 'Step 5 -- Registry'
            Write-LMInfo 'Registry preserved (use -Purge to remove).'
            Write-LMStep 'Step 6 -- Purge'
            if ($ws['Purge']) {
                $purgeData = Join-Path $env:ProgramData 'LegacyMCP'
                try { Remove-LMRegistry -Key $REG_ROOT; Write-LMOK 'Registry entries removed.' } catch { Write-LMWarn "Could not remove registry: $_" }
                if (Test-Path $purgeData) {
                    try { Remove-Item $purgeData -Recurse -Force; Write-LMOK "Removed: $purgeData" } catch { Write-LMWarn "Could not remove '$purgeData': $_" }
                }
            } else {
                Write-LMInfo 'Skipped (Purge not selected).'
            }
            Write-LMStep 'Uninstall complete'
            Write-LMOK 'Profile B-core Server uninstalled.'
        }

        # --------------- Uninstall Profile A ---------------
        function Invoke-LMUninstallA {
            param($ws)
            $REG_ROOT    = 'HKCU:\SOFTWARE\LegacyMCP'
            $cfg         = Get-LMConfig -RegistryRoot $REG_ROOT
            $InstallPath = if ($cfg.ContainsKey('InstallPath')) { $cfg['InstallPath'] } else { "$env:LOCALAPPDATA\LegacyMCP" }
            $ConfigPath  = if ($cfg.ContainsKey('ConfigPath'))  { $cfg['ConfigPath']  } else { "$env:LOCALAPPDATA\LegacyMCP\config\config.yaml" }
            $DataPath    = "$env:USERPROFILE\Documents\LegacyMCP-Data"

            Write-LMStep 'LegacyMCP Uninstall -- Profile A'
            Write-LMStep 'Step 1 -- Registry'
            try { Remove-LMRegistry -Key $REG_ROOT; Write-LMOK 'Registry entries removed.' } catch { Write-LMWarn "Could not remove registry: $_" }
            Write-LMStep 'Step 2 -- Purge'
            if ($ws['Purge']) {
                foreach ($path in @($InstallPath, (Split-Path $ConfigPath -Parent), $DataPath)) {
                    if (Test-Path $path) {
                        try { Remove-Item $path -Recurse -Force; Write-LMOK "Removed: $path" } catch { Write-LMWarn "Could not remove '$path': $_" }
                    }
                }
            } else {
                Write-LMInfo 'Data preserved. Remove manually if needed:'
                Write-LMInfo "  Venv:   $InstallPath"
                Write-LMInfo "  Config: $ConfigPath"
            }
            Write-LMStep 'Uninstall complete'
            Write-LMOK 'Profile A uninstalled. Remove the "legacymcp" entry from claude_desktop_config.json if present.'
        }

        # --------------- Install B-core Client ---------------
        function Invoke-LMInstallBCoreClient {
            param($ws, $sdir, $rroot)
            $ClientPath    = "$env:LOCALAPPDATA\LegacyMCP"
            $ClientCertDir = "$env:LOCALAPPDATA\LegacyMCP\certs"

            Write-LMStep "LegacyMCP Setup -- Profile B-core Client"

            Write-LMStep 'Step 1 -- CA certificate'
            foreach ($dir in @($ClientPath, $ClientCertDir)) {
                if (-not (Test-Path $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    Write-LMOK "Created: $dir"
                }
            }
            $CaCertPath = $ws['CaCertPath']
            if (-not (Test-Path $CaCertPath)) { throw "CA certificate not found: $CaCertPath" }
            $localCertPath = Join-Path $ClientCertDir (Split-Path $CaCertPath -Leaf)
            Copy-Item -Path $CaCertPath -Destination $localCertPath -Force
            Write-LMOK "CA certificate copied to: $localCertPath"

            Write-LMStep 'Step 2 -- API key'
            $keyPath = Join-Path $ClientPath '.legacymcp-key'
            $apiKey  = $ws['ClientApiKey']
            if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'API key cannot be empty.' }
            Protect-LMClientApiKey -ApiKey $apiKey -OutputPath $keyPath
            $ws['ClientApiKey'] = $null

            Write-LMStep 'Step 3 -- BAT entry point'
            $ps1Source = $null
            foreach ($candidate in @(
                (Join-Path $sdir 'mcp-remote-live.ps1'),
                (Join-Path $rroot 'client\mcp-remote-live.ps1'),
                (Join-Path $sdir 'client\mcp-remote-live.ps1')
            )) {
                if (Test-Path $candidate) { $ps1Source = $candidate; break }
            }
            if (-not $ps1Source) { throw 'mcp-remote-live.ps1 not found in expected locations.' }
            $ps1Dest = Join-Path $ClientPath 'mcp-remote-live.ps1'
            Copy-Item -Path $ps1Source -Destination $ps1Dest -Force
            Write-LMOK "mcp-remote-live.ps1 copied to: $ps1Dest"
            $batPath = Join-Path $ClientPath 'mcp-remote-live.bat'
            New-LMMcpRemoteBat -ServerUrl $ws['ServerUrl'] -CertPath $localCertPath -Ps1Path $ps1Dest -OutputPath $batPath

            Write-LMStep 'Step 4 -- Claude Desktop configuration'
            $claudeConfigPath = Get-LMClaudeConfigPath
            Set-LMClaudeConfigProfileB -BatPath $batPath -ClaudeConfigPath $claudeConfigPath

            Write-LMStep 'Setup complete'
            Write-LMOK "Profile B-core Client installation successful."
            Write-LMInfo "API key file:  $keyPath"
            Write-LMInfo "BAT:           $batPath"
            Write-LMInfo "CA cert:       $localCertPath"
            Write-LMInfo "Claude config: $claudeConfigPath"
            Write-LMInfo "Restart Claude Desktop to activate LegacyMCP."
        }

        try {
            if ($MODE -eq 'Install' -and $PROFILE -eq 'B-core' -and $ROLE -eq 'Server') {
                Invoke-LMInstallBCore -ws $ws -sdir $sdir -rroot $rroot -SvcName $SERVICE_NAME -Ver $INSTALLER_VERSION -Q $Q
            } elseif ($MODE -eq 'Install' -and $PROFILE -eq 'B-core' -and $ROLE -eq 'Client') {
                Invoke-LMInstallBCoreClient -ws $ws -sdir $sdir -rroot $rroot
            } elseif ($MODE -eq 'Install' -and $PROFILE -eq 'A') {
                Invoke-LMInstallA -ws $ws -rroot $rroot -Ver $INSTALLER_VERSION
            } elseif ($MODE -eq 'Configure') {
                Invoke-LMConfigure -ws $ws
            } elseif ($MODE -eq 'Uninstall' -and $PROFILE -eq 'B-core') {
                Invoke-LMUninstallBCore -ws $ws -sdir $sdir
            } elseif ($MODE -eq 'Uninstall' -and $PROFILE -eq 'A') {
                Invoke-LMUninstallA -ws $ws
            }
            $Q.Enqueue('DONE:success')
        } catch {
            $Q.Enqueue("FAIL:$($_.Exception.Message)")
            $Q.Enqueue('DONE:error')
        }

    }) | Out-Null  # end AddScript

    $asyncResult = $ps.BeginInvoke()
    return @{ PS = $ps; RS = $rs; Async = $asyncResult }
}

# ---------------------------------------------------------------------------
# Form construction
# ---------------------------------------------------------------------------
