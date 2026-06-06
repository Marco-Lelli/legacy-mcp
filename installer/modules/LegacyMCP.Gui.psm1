# LegacyMCP.Gui.psm1
# WinForms wizard activated by Setup-LegacyMCP.ps1 -Gui.
# Collects parameters across 5 steps and delegates execution to the
# same module functions used by the CLI -- no business logic here.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$global:LMGui_Steps = @('Profile-Role','Parameters','Summary','Executing','Complete')

$global:LMGui_CL = @{
    SideTop  = [System.Drawing.Color]::FromArgb(  0,  0,  0)
    SideBot  = [System.Drawing.Color]::FromArgb(107,  0,  0)
    Accent   = [System.Drawing.Color]::FromArgb(204, 34,  0)
    AccentDk = [System.Drawing.Color]::FromArgb(152, 24,  0)
    StepTxt  = [System.Drawing.Color]::FromArgb(255,204,204)
    StepDone = [System.Drawing.Color]::FromArgb(204,136,136)
    StepVer  = [System.Drawing.Color]::FromArgb(102, 51, 51)
    LogBg    = [System.Drawing.Color]::Black
    LogOk    = [System.Drawing.Color]::FromArgb(  0,204, 68)
    LogWarn  = [System.Drawing.Color]::FromArgb(255,204,  0)
    LogErr   = [System.Drawing.Color]::FromArgb(255, 51, 51)
    LogStep  = [System.Drawing.Color]::FromArgb(255,102, 68)
    LogInfo  = [System.Drawing.Color]::FromArgb(170,170,170)
    WinBg    = [System.Drawing.SystemColors]::Control
}

# Expected Write-LMStep calls per mode (for progress bar max)
$global:LMGui_StepTotals = @{
    'Install-B-core-Server'  = 14
    'Install-B-core-Client'  = 6
    'Install-A'              = 9
    'Configure-B-core-Server'= 5
    'Uninstall-B-core-Server'= 7
    'Uninstall-A'            = 4
}

# ---------------------------------------------------------------------------
# Shared wizard state
# ---------------------------------------------------------------------------

$global:LMGui_Form        = $null
$global:LMGui_Sidebar     = $null
$global:LMGui_SideLabels  = @()
$global:LMGui_Content     = $null
$global:LMGui_Footer      = $null
$global:LMGui_BtnBack     = $null
$global:LMGui_BtnNext     = $null
$global:LMGui_BtnCancel   = $null
$global:LMGui_CurrentStep = 0
$global:LMGui_WizardOk    = $false

$global:LMGui_ModulesDir  = ''
$global:LMGui_ScriptDir   = ''
$global:LMGui_RepoRoot    = ''

$global:LMGui_ImgLogoLarge = $null
$global:LMGui_ImgGifOk     = $null
$global:LMGui_ImgGifErr    = $null

$global:LMGui_State = @{}

$global:LMGui_Queue       = $null
$global:LMGui_ExecPS      = $null
$global:LMGui_ExecRS      = $null
$global:LMGui_ExecAsync   = $null
$global:LMGui_ExecTimer   = $null
$global:LMGui_ExecSuccess = $false
$global:LMGui_StepCount   = 0
$global:LMGui_StepTotal   = 0
$global:LMGui_LogBox      = $null
$global:LMGui_StepLabel   = $null
$global:LMGui_GifBox      = $null
$global:LMGui_ProgPanel   = $null
$global:LMGui_NewApiKey   = ''

# Per-step action dispatchers (set by each Show-LMStep* function)
$global:LMGui_NextAction  = $null
$global:LMGui_BackAction  = $null

# Module-level RadioButton references for steps that read them from event closures.
# Local variables captured by GetNewClosure() can lose their WinForms reference;
# $script: variables are always accessible from module scope.
$script:_rb0_AI  = $null   # Step 0: Profile A Install
$script:_rb0_AU  = $null   # Step 0: Profile A Uninstall
$script:_rb0_BSI = $null   # Step 0: B-core Server Install
$script:_rb0_BSC = $null   # Step 0: B-core Server Configure
$script:_rb0_BSU = $null   # Step 0: B-core Server Uninstall
$script:_rb0_BC  = $null   # Step 0: B-core Client Install

# Module-private function references -- populated in Start-LMWizard
$global:LMGui_NavFn  = $null
$global:LMGui_ShowFn = $null

# Step 3A -- Install B-core controls referenced in event handlers
$script:_B_tbSA       = $null
$script:_B_tbPwd      = $null
$script:_B_hintLbl    = $null
$script:_B_errSA      = $null
$script:_B_errPwd     = $null
$script:_B_pwdUpdater = $null
$script:_B_tbPort     = $null
$script:_B_errPort    = $null
$script:_B_tbSnap     = $null
$script:_B_tbVer      = $null
$script:_B_cbDev      = $null
$script:_B_tbIP       = $null
$script:_B_tbCP       = $null
$script:_B_tbLP       = $null
$script:_B_rbApiAuto  = $null
$script:_B_rbApiMan   = $null
$script:_B_tbApiMan   = $null
$script:_B_rbCertAuto = $null
$script:_B_rbCertImp  = $null
$script:_B_tbCertF    = $null
$script:_B_tbCertK    = $null
$script:_B_errCert    = $null
$script:_B_advLink    = $null
$script:_B_advPanel   = $null
$script:_B_rbKeep           = $null
$script:_B_cbPreserveConfig = $null

# Step 3B -- Install A controls
$script:_A_tbData     = $null

# Step 3C -- Configure controls
$script:_C_tbPort     = $null
$script:_C_tbSnap     = $null
$script:_C_rbAkRotate = $null
$script:_C_rbAkMan    = $null
$script:_C_tbAkMan    = $null
$script:_C_rbTlsRegen = $null
$script:_C_rbTlsImp   = $null
$script:_C_tbTlsCrt   = $null
$script:_C_tbTlsKey   = $null
$script:_C_errTls     = $null

# Step 3A -- Install B-core groupbox containers (referenced in Keep/Regen handler)
$script:_B_gbApi        = $null
$script:_B_gbCert       = $null
$script:_B_btnBrowseCrt = $null
$script:_B_btnBrowseKey = $null

# Step 3D -- Uninstall controls
$script:_U_cbPurge    = $null

# Step: B-core Client Install controls
$script:_CL_tbUrl           = $null
$script:_CL_tbCaCert        = $null
$script:_CL_tbApiKey        = $null
$script:_CL_errUrl          = $null
$script:_CL_errCert         = $null
$script:_CL_errKey          = $null
$script:_CL_btnBrowseCaCert = $null

# ---------------------------------------------------------------------------
# Asset loading
# ---------------------------------------------------------------------------

function Load-LMAsset {
    param([string]$Path, [switch]$IsGif)
    if (-not (Test-Path $Path)) { return $null }
    try {
        if ($IsGif) {
            return [System.Drawing.Image]::FromFile($Path)
        } else {
            return [System.Drawing.Bitmap]::new($Path)
        }
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Sidebar drawing
# ---------------------------------------------------------------------------

function Register-LMSidebarPaint {
    param([System.Windows.Forms.Panel]$Panel)
    $Panel.Add_Paint({
        param($s, $e)
        $rect  = $s.ClientRectangle
        $brush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
            $rect,
            $global:LMGui_CL.SideTop,
            $global:LMGui_CL.SideBot,
            [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
        $e.Graphics.FillRectangle($brush, $rect)
        $brush.Dispose()
    })
}

function Update-LMSidebarLabels {
    for ($i = 0; $i -lt $global:LMGui_SideLabels.Count; $i++) {
        $lbl = $global:LMGui_SideLabels[$i]
        if ($i -lt $global:LMGui_CurrentStep) {
            $lbl.Text      = "  checkmark $($global:LMGui_Steps[$i])" -replace 'checkmark ', ([char]0x2713 + ' ')
            $lbl.ForeColor = $global:LMGui_CL.StepDone
            $lbl.Font      = [System.Drawing.Font]::new('Tahoma', 8)
        } elseif ($i -eq $global:LMGui_CurrentStep) {
            $lbl.Text      = "  $($global:LMGui_Steps[$i])"
            $lbl.ForeColor = [System.Drawing.Color]::White
            $lbl.Font      = [System.Drawing.Font]::new('Tahoma', 8, [System.Drawing.FontStyle]::Bold)
        } else {
            $lbl.Text      = "  $($global:LMGui_Steps[$i])"
            $lbl.ForeColor = $global:LMGui_CL.StepTxt
            $lbl.Font      = [System.Drawing.Font]::new('Tahoma', 8)
        }
    }
    $global:LMGui_Sidebar.Refresh()
}

# ---------------------------------------------------------------------------
# Content panel helpers
# ---------------------------------------------------------------------------

function Clear-LMContent {
    $global:LMGui_Content.SuspendLayout()
    $global:LMGui_Content.Controls.Clear()
    $global:LMGui_Content.ResumeLayout()
}

function Add-LMPageTitle {
    param([string]$Title)
    $lbl = [System.Windows.Forms.Label]::new()
    $lbl.Text      = $Title
    $lbl.Font      = [System.Drawing.Font]::new('Tahoma', 13, [System.Drawing.FontStyle]::Bold)
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(80, 0, 0)
    $lbl.Location  = [System.Drawing.Point]::new(20, 16)
    $lbl.AutoSize  = $true
    $global:LMGui_Content.Controls.Add($lbl)

    # Gradient line under title
    $line = [System.Windows.Forms.Panel]::new()
    $line.Location = [System.Drawing.Point]::new(20, 44)
    $line.Size     = [System.Drawing.Size]::new(560, 2)
    $line.Add_Paint({
        param($s, $e)
        $brush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
            $s.ClientRectangle,
            $global:LMGui_CL.Accent,
            $global:LMGui_CL.WinBg,
            [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
        $e.Graphics.FillRectangle($brush, $s.ClientRectangle)
        $brush.Dispose()
    })
    $global:LMGui_Content.Controls.Add($line)
}

function New-LMLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 200)
    $lbl = [System.Windows.Forms.Label]::new()
    $lbl.Text     = $Text
    $lbl.Location = [System.Drawing.Point]::new($X, $Y)
    $lbl.Size     = [System.Drawing.Size]::new($W, 20)
    $lbl.Font     = [System.Drawing.Font]::new('Tahoma', 8)
    return $lbl
}

function New-LMTextBox {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 300, [switch]$Password)
    $tb = [System.Windows.Forms.TextBox]::new()
    $tb.Text     = $Text
    $tb.Location = [System.Drawing.Point]::new($X, $Y)
    $tb.Size     = [System.Drawing.Size]::new($W, 22)
    $tb.Font     = [System.Drawing.Font]::new('Tahoma', 8)
    if ($Password) { $tb.UseSystemPasswordChar = $true }
    return $tb
}

function New-LMRadio {
    param([string]$Text, [int]$X, [int]$Y, [bool]$Checked = $false, [int]$W = 300)
    $rb = [System.Windows.Forms.RadioButton]::new()
    $rb.Text     = $Text
    $rb.Location = [System.Drawing.Point]::new($X, $Y)
    $rb.Size     = [System.Drawing.Size]::new($W, 20)
    $rb.Font     = [System.Drawing.Font]::new('Tahoma', 8)
    $rb.Checked  = $Checked
    return $rb
}

function New-LMCheckBox {
    param([string]$Text, [int]$X, [int]$Y, [bool]$Checked = $false, [int]$W = 300)
    $cb = [System.Windows.Forms.CheckBox]::new()
    $cb.Text     = $Text
    $cb.Location = [System.Drawing.Point]::new($X, $Y)
    $cb.Size     = [System.Drawing.Size]::new($W, 20)
    $cb.Font     = [System.Drawing.Font]::new('Tahoma', 8)
    $cb.Checked  = $Checked
    return $cb
}

function New-LMGroupBox {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H)
    $gb = [System.Windows.Forms.GroupBox]::new()
    $gb.Text     = $Text
    $gb.Location = [System.Drawing.Point]::new($X, $Y)
    $gb.Size     = [System.Drawing.Size]::new($W, $H)
    $gb.Font     = [System.Drawing.Font]::new('Tahoma', 8)
    return $gb
}

function New-LMErrorLabel {
    param([int]$X, [int]$Y, [int]$W = 300)
    $lbl = [System.Windows.Forms.Label]::new()
    $lbl.Text      = ''
    $lbl.ForeColor = [System.Drawing.Color]::Red
    $lbl.Location  = [System.Drawing.Point]::new($X, $Y)
    $lbl.Size      = [System.Drawing.Size]::new($W, 16)
    $lbl.Font      = [System.Drawing.Font]::new('Tahoma', 7)
    return $lbl
}

function New-LMSeparator {
    param([int]$Y)
    $sep = [System.Windows.Forms.Label]::new()
    $sep.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
    $sep.Location    = [System.Drawing.Point]::new(20, $Y)
    $sep.Size        = [System.Drawing.Size]::new(560, 2)
    return $sep
}

# ---------------------------------------------------------------------------
# Step 0 -- ProfileRole
# ---------------------------------------------------------------------------

function Navigate-LMForward {
    $next = $global:LMGui_CurrentStep + 1
    Show-LMStep $next
}

function Show-LMStep {
    param([int]$Step)
    $global:LMGui_CurrentStep = $Step
    $global:LMGui_NextAction  = $null
    $global:LMGui_BackAction  = $null
    Update-LMSidebarLabels

    $global:LMGui_BtnNext.Font      = [System.Drawing.Font]::new('Tahoma', 8)
    $global:LMGui_BtnNext.ForeColor = [System.Drawing.Color]::Empty
    $global:LMGui_BtnNext.Size      = [System.Drawing.Size]::new(72, 28)
    $global:LMGui_BtnNext.Location  = [System.Drawing.Point]::new(528, 10)

    switch ($Step) {
        0 { Show-LMStepMode }
        1 {
            switch ("$($global:LMGui_State['Profile'])|$($global:LMGui_State['Role'])|$($global:LMGui_State['Mode'])") {
                'A||Install'              { Show-LMStepParamsInstallA }
                'A||Uninstall'            { Show-LMStepParamsUninstall }
                'B-core|Server|Install'   { Show-LMStepParamsInstallB }
                'B-core|Server|Configure' { Show-LMStepParamsConfigure }
                'B-core|Server|Uninstall' { Show-LMStepParamsUninstall }
                'B-core|Client|Install'   { Show-LMStepParamsClient }
            }
        }
        2 { Show-LMStepSummary }
        3 { Show-LMStepExecuting }
        4 { Show-LMStepComplete }
    }

    if ($Step -gt 0 -and $Step -lt 3) {
        $global:LMGui_BtnBack.Enabled = $true
        $global:LMGui_BackAction = {
            $prev = $global:LMGui_CurrentStep - 1
            & $global:LMGui_ShowFn $prev
        }
    }
}

# ---------------------------------------------------------------------------
# Execution: runspace factory
# ---------------------------------------------------------------------------

function Build-LMForm {
    param([string]$AssetsDir, [string]$Version = '0.0.0')

    $global:LMGui_ImgLogoLarge = Load-LMAsset (Join-Path $AssetsDir 'logo-1024.png')
    $global:LMGui_ImgGifOk     = Load-LMAsset (Join-Path $AssetsDir 'server-install.gif') -IsGif
    $global:LMGui_ImgGifErr    = Load-LMAsset (Join-Path $AssetsDir 'server-error.gif')   -IsGif
    $iconImg             = Load-LMAsset (Join-Path $AssetsDir 'logo-16.png')

    $global:LMGui_Form = [System.Windows.Forms.Form]::new()
    $global:LMGui_Form.Text            = 'LegacyMCP Setup'
    $global:LMGui_Form.ClientSize      = [System.Drawing.Size]::new(800, 560)
    $global:LMGui_Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $global:LMGui_Form.MaximizeBox     = $false
    $global:LMGui_Form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $global:LMGui_Form.BackColor       = $global:LMGui_CL.WinBg
    if ($iconImg) {
        try { $global:LMGui_Form.Icon = [System.Drawing.Icon]::FromHandle((New-Object System.Drawing.Bitmap($iconImg)).GetHicon()) } catch {}
    }

    # Sidebar (190 wide, full height)
    $global:LMGui_Sidebar = [System.Windows.Forms.Panel]::new()
    $global:LMGui_Sidebar.Location  = [System.Drawing.Point]::new(0, 0)
    $global:LMGui_Sidebar.Size      = [System.Drawing.Size]::new(190, 560)
    $global:LMGui_Sidebar.BackColor = $global:LMGui_CL.SideTop
    $global:LMGui_Sidebar.Anchor    = [System.Windows.Forms.AnchorStyles]::Top `
        -bor [System.Windows.Forms.AnchorStyles]::Left `
        -bor [System.Windows.Forms.AnchorStyles]::Bottom
    Register-LMSidebarPaint $global:LMGui_Sidebar

    # Logo
    $logoPic = [System.Windows.Forms.PictureBox]::new()
    $logoPic.Location = [System.Drawing.Point]::new(59, 18)
    $logoPic.Size     = [System.Drawing.Size]::new(72, 72)
    $logoPic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $logoPic.BackColor = [System.Drawing.Color]::Black
    if ($global:LMGui_ImgLogoLarge) {
        $logoPic.Image = $global:LMGui_ImgLogoLarge
    }
    $global:LMGui_Sidebar.Controls.Add($logoPic)

    # Title labels
    $tlbl = [System.Windows.Forms.Label]::new()
    $tlbl.Text      = 'LEGACY'
    $tlbl.Location  = [System.Drawing.Point]::new(12, 96)
    $tlbl.Size      = [System.Drawing.Size]::new(166, 22)
    $tlbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $tlbl.Font      = [System.Drawing.Font]::new('Tahoma', 13, [System.Drawing.FontStyle]::Bold)
    $tlbl.ForeColor = [System.Drawing.Color]::White
    $tlbl.BackColor = [System.Drawing.Color]::Transparent
    $global:LMGui_Sidebar.Controls.Add($tlbl)

    $tlbl2 = [System.Windows.Forms.Label]::new()
    $tlbl2.Text      = 'MCP'
    $tlbl2.Location  = [System.Drawing.Point]::new(12, 116)
    $tlbl2.Size      = [System.Drawing.Size]::new(166, 22)
    $tlbl2.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $tlbl2.Font      = [System.Drawing.Font]::new('Tahoma', 13, [System.Drawing.FontStyle]::Bold)
    $tlbl2.ForeColor = [System.Drawing.Color]::White
    $tlbl2.BackColor = [System.Drawing.Color]::Transparent
    $global:LMGui_Sidebar.Controls.Add($tlbl2)

    $verLbl = [System.Windows.Forms.Label]::new()
    $verLbl.Text      = "v$Version"
    $verLbl.Location  = [System.Drawing.Point]::new(12, 136)
    $verLbl.Size      = [System.Drawing.Size]::new(166, 16)
    $verLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $verLbl.Font      = [System.Drawing.Font]::new('Tahoma', 7)
    $verLbl.ForeColor = $global:LMGui_CL.StepVer
    $verLbl.BackColor = [System.Drawing.Color]::Transparent
    $global:LMGui_Sidebar.Controls.Add($verLbl)

    # Divider
    $div = [System.Windows.Forms.Label]::new()
    $div.Location  = [System.Drawing.Point]::new(20, 158)
    $div.Size      = [System.Drawing.Size]::new(150, 1)
    $div.BackColor = [System.Drawing.Color]::FromArgb(80, 0, 0)
    $global:LMGui_Sidebar.Controls.Add($div)

    # Step labels
    $global:LMGui_SideLabels = @()
    for ($i = 0; $i -lt $global:LMGui_Steps.Count; $i++) {
        $sl = [System.Windows.Forms.Label]::new()
        $sl.Text      = "  $($global:LMGui_Steps[$i])"
        $sl.Location  = [System.Drawing.Point]::new(0, 168 + $i * 26)
        $sl.Size      = [System.Drawing.Size]::new(190, 22)
        $sl.Font      = [System.Drawing.Font]::new('Tahoma', 8)
        $sl.ForeColor = $global:LMGui_CL.StepTxt
        $sl.BackColor = [System.Drawing.Color]::Transparent
        $global:LMGui_Sidebar.Controls.Add($sl)
        $global:LMGui_SideLabels += $sl
    }

    # Content panel
    $global:LMGui_Content = [System.Windows.Forms.Panel]::new()
    $global:LMGui_Content.Location  = [System.Drawing.Point]::new(190, 0)
    $global:LMGui_Content.Size      = [System.Drawing.Size]::new(610, 510)
    $global:LMGui_Content.BackColor = $global:LMGui_CL.WinBg

    # Footer panel
    $global:LMGui_Footer = [System.Windows.Forms.Panel]::new()
    $global:LMGui_Footer.Location  = [System.Drawing.Point]::new(190, 510)
    $global:LMGui_Footer.Size      = [System.Drawing.Size]::new(610, 50)
    $global:LMGui_Footer.BackColor = [System.Drawing.Color]::FromArgb(210, 208, 200)
    $global:LMGui_Footer.Anchor    = [System.Windows.Forms.AnchorStyles]::Bottom `
        -bor [System.Windows.Forms.AnchorStyles]::Left `
        -bor [System.Windows.Forms.AnchorStyles]::Right

    $footerLine = [System.Windows.Forms.Label]::new()
    $footerLine.Location  = [System.Drawing.Point]::new(0, 0)
    $footerLine.Size      = [System.Drawing.Size]::new(610, 1)
    $footerLine.BackColor = [System.Drawing.Color]::FromArgb(160, 150, 140)
    $global:LMGui_Footer.Controls.Add($footerLine)

    $global:LMGui_BtnCancel = [System.Windows.Forms.Button]::new()
    $global:LMGui_BtnCancel.Text     = 'Cancel'
    $global:LMGui_BtnCancel.Location = [System.Drawing.Point]::new(10, 10)
    $global:LMGui_BtnCancel.Size     = [System.Drawing.Size]::new(80, 28)
    $global:LMGui_BtnCancel.Font     = [System.Drawing.Font]::new('Tahoma', 8)
    $global:LMGui_BtnCancel.Add_Click({
        if ($global:LMGui_ExecTimer) { $global:LMGui_ExecTimer.Stop() }
        try { if ($global:LMGui_ExecPS) { $global:LMGui_ExecPS.Stop() } } catch {}
        $global:LMGui_WizardOk = $false
        $global:LMGui_Form.Close()
    })
    $global:LMGui_Footer.Controls.Add($global:LMGui_BtnCancel)

    $global:LMGui_BtnBack = [System.Windows.Forms.Button]::new()
    $global:LMGui_BtnBack.Text     = '< Back'
    $global:LMGui_BtnBack.Location = [System.Drawing.Point]::new(440, 10)
    $global:LMGui_BtnBack.Size     = [System.Drawing.Size]::new(80, 28)
    $global:LMGui_BtnBack.Font     = [System.Drawing.Font]::new('Tahoma', 8)
    $global:LMGui_BtnBack.Enabled  = $false
    $global:LMGui_Footer.Controls.Add($global:LMGui_BtnBack)

    $global:LMGui_BtnNext = [System.Windows.Forms.Button]::new()
    $global:LMGui_BtnNext.Text     = 'Next >'
    $global:LMGui_BtnNext.Location = [System.Drawing.Point]::new(528, 10)
    $global:LMGui_BtnNext.Size     = [System.Drawing.Size]::new(72, 28)
    $global:LMGui_BtnNext.Font     = [System.Drawing.Font]::new('Tahoma', 8)
    $global:LMGui_Footer.Controls.Add($global:LMGui_BtnNext)

    # Single persistent dispatch handlers -- actions set per-step by Show-LMStep* functions
    $global:LMGui_BtnNext.Add_Click({ if ($global:LMGui_NextAction) { & $global:LMGui_NextAction } })
    $global:LMGui_BtnBack.Add_Click({ if ($global:LMGui_BackAction) { & $global:LMGui_BackAction } })

    $global:LMGui_Form.Controls.Add($global:LMGui_Sidebar)
    $global:LMGui_Form.Controls.Add($global:LMGui_Content)
    $global:LMGui_Form.Controls.Add($global:LMGui_Footer)
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

function Start-LMWizard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ModulesDir,
        [Parameter(Mandatory)] [string]$ScriptDir,
        [Parameter(Mandatory)] [string]$RepoRoot,
        [string]$ScriptPath    = '',
        [string]$WizardVersion = '0.0.0'
    )

    # Best-effort: must be called before any Win32 window is created.
    # In a PS console host the console window already exists, so the call may
    # throw InvalidOperationException -- suppress it and continue.
    try { [System.Windows.Forms.Application]::EnableVisualStyles() }                    catch {}
    try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch {}

    $global:LMGui_ModulesDir = $ModulesDir
    $global:LMGui_ScriptDir  = $ScriptDir
    $global:LMGui_RepoRoot   = $RepoRoot
    $global:LMGui_WizardOk   = $false
    $global:LMGui_State      = @{
        Mode = ''; Profile = ''; Role = ''; ServiceAccount = ''; ServiceAccountPassword = $null
        Port = '8000'; SnapshotPath = ''; Version = ''; DevInstall = $false; PreserveConfig = $true
        InstallPath = ''; ConfigPath = ''; LogPath = ''; DataPath = ''
        ApiKeyMode = 'auto'; ApiKeyValue = ''; CertMode = 'auto'; CertFile = ''; CertKeyFile = ''
        KeepCredentials = $false; ExistingVersion = $null; Purge = $false
        CfgPort = ''; CfgSnapshotPath = ''; CfgApiKeyMode = 'none'; CfgApiKeyValue = ''
        CfgCertMode = 'none'; CfgCertFile = ''; CfgCertKeyFile = ''
        ServerUrl = ''; CaCertPath = ''; ClientApiKey = ''
        INSTALLER_VERSION = $WizardVersion
    }

    # Wrapper ScriptBlocks for module-private functions, defined here (module scope)
    # so the function name lookup resolves via the module's scope chain at call time.
    # ${function:Name} is unreliable for non-exported module functions in PS 5.1.
    $global:LMGui_NavFn  = { Navigate-LMForward }
    $global:LMGui_ShowFn = { param([int]$s) Show-LMStep $s }

    $assetsDir = Join-Path $ScriptDir 'assets'
    Build-LMForm -AssetsDir $assetsDir -Version $WizardVersion

    Show-LMStep 0

    [System.Windows.Forms.Application]::Run($global:LMGui_Form)

    # Cleanup
    try { if ($global:LMGui_ExecTimer) { $global:LMGui_ExecTimer.Stop(); $global:LMGui_ExecTimer.Dispose() } } catch {}
    if ($global:LMGui_ImgLogoLarge) { try { $global:LMGui_ImgLogoLarge.Dispose() } catch {} }
    if ($global:LMGui_ImgGifOk)     { try { $global:LMGui_ImgGifOk.Dispose()     } catch {} }
    if ($global:LMGui_ImgGifErr)    { try { $global:LMGui_ImgGifErr.Dispose()     } catch {} }

    $ok = $global:LMGui_WizardOk
    Get-Variable -Scope Global -Name 'LMGui_*' |
        ForEach-Object { Remove-Variable -Scope Global -Name $_.Name -ErrorAction SilentlyContinue }

    return $ok
}

