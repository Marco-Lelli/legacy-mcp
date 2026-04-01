#Requires -Version 5.1
<#
.SYNOPSIS
    Manage LegacyMCP workspaces -- list, add, remove, validate, repair metadata.

.DESCRIPTION
    Provides lifecycle management for forests in the LegacyMCP config.yaml
    workspace. Each operation is a mutually exclusive switch.

    YAML parsing: uses powershell-yaml module if available; falls back to a
    built-in state-machine parser that handles all real-world config.yaml
    structures without any external dependencies.

.EXAMPLE
    .\Manage-Workspaces.ps1 -List
    .\Manage-Workspaces.ps1 -Add -Name contoso.local -File "C:\Data\contoso.json"
    .\Manage-Workspaces.ps1 -Add -Name house.local -DC dc01.house.local
    .\Manage-Workspaces.ps1 -Remove -Name contoso.local
    .\Manage-Workspaces.ps1 -Validate
    .\Manage-Workspaces.ps1 -Validate -Name contoso.local
    .\Manage-Workspaces.ps1 -RepairMetadata
    .\Manage-Workspaces.ps1 -RepairMetadata -Name contoso.local
#>

[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(ParameterSetName = 'List',          Mandatory = $true)]  [switch]$List,
    [Parameter(ParameterSetName = 'Add',           Mandatory = $true)]  [switch]$Add,
    [Parameter(ParameterSetName = 'Remove',        Mandatory = $true)]  [switch]$Remove,
    [Parameter(ParameterSetName = 'Validate',      Mandatory = $true)]  [switch]$Validate,
    [Parameter(ParameterSetName = 'RepairMetadata',Mandatory = $true)]  [switch]$RepairMetadata,

    [string]$Name,
    [string]$File,
    [string]$DC,
    [string]$Relation = 'standalone',
    [string]$Module   = 'ad-core',
    [string]$Config   = 'config\config.yaml',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-OK    { param([string]$Msg); Write-Host "  [OK]    $Msg" -ForegroundColor Green  }
function Write-Warn  { param([string]$Msg); Write-Host "  [WARN]  $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg); Write-Host "  [ERROR] $Msg" -ForegroundColor Red    }
function Write-Info  { param([string]$Msg); Write-Host "  [INFO]  $Msg" -ForegroundColor Cyan   }
function Write-Step  { param([string]$Msg); Write-Host "`n$Msg" -ForegroundColor White           }

# ---------------------------------------------------------------------------
# Resolve config path
# ---------------------------------------------------------------------------
function Resolve-ConfigPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    # Relative to caller's working directory
    return Join-Path (Get-Location).Path $Path
}

$ConfigFile = Resolve-ConfigPath $Config

# ---------------------------------------------------------------------------
# YAML helpers -- powershell-yaml with full fallback
# ---------------------------------------------------------------------------
$script:UseYamlModule = $false
try {
    Import-Module powershell-yaml -ErrorAction Stop
    $script:UseYamlModule = $true
} catch {
    # Fallback mode -- built-in parser
}

# Read config.yaml as raw text (always UTF-8 w/o BOM)
function Read-ConfigRaw {
    if (-not (Test-Path $ConfigFile)) {
        throw "config.yaml not found: $ConfigFile"
    }
    return [System.IO.File]::ReadAllText($ConfigFile, [System.Text.Encoding]::UTF8)
}

function Write-ConfigRaw {
    param([string]$Content)
    [System.IO.File]::WriteAllText($ConfigFile, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------
# Fallback YAML parser -- extracts forest list from config.yaml text
#
# Supports both legacy (mode: offline) and profile-based configs.
# Returns array of hashtables; each hashtable has at minimum 'name'.
# ---------------------------------------------------------------------------
function Parse-ForestsFromText {
    param([string]$Text)

    $lines  = $Text -split "`r?`n"
    $forests = @()
    $inWorkspace = $false
    $inForests   = $false
    $current     = $null

    foreach ($line in $lines) {
        # Detect workspace: block (0-indent)
        if ($line -match '^workspace\s*:') {
            $inWorkspace = $true
            continue
        }

        # Detect forests: block (2-space indent under workspace)
        if ($inWorkspace -and $line -match '^  forests\s*:') {
            $inForests = $true
            continue
        }

        # Leaving workspace block (line with 0 indent and not empty)
        if ($inWorkspace -and $line -match '^[a-zA-Z]') {
            $inWorkspace = $false
            $inForests   = $false
            if ($null -ne $current) { $forests += $current; $current = $null }
            continue
        }

        if (-not $inForests) { continue }

        # New forest entry: "    - " at 4-space indent
        if ($line -match '^    - ') {
            if ($null -ne $current) { $forests += $current }
            $current = @{}
            # Inline key on the same line as "-"
            if ($line -match '^    - (\w+)\s*:\s*(.*)$') {
                $current[$Matches[1]] = $Matches[2].Trim()
            }
            continue
        }

        # Property line: 6+ spaces
        if ($null -ne $current -and $line -match '^      (\w+)\s*:\s*(.*)$') {
            $current[$Matches[1]] = $Matches[2].Trim()
            continue
        }

        # Line that ends the forests block (blank lines are ok, but 0-2 indent non-blank is not)
        if ($null -ne $current -and $line -match '^  [a-zA-Z#]') {
            $forests += $current
            $current  = $null
            $inForests = $false
        }
    }

    if ($null -ne $current) { $forests += $current }
    return $forests
}

# Get forests using module or fallback
function Get-Forests {
    $raw = Read-ConfigRaw

    if ($script:UseYamlModule) {
        try {
            $yaml = ConvertFrom-Yaml $raw
            $list = $yaml.workspace.forests
            if (-not $list) { return @() }
            $result = @()
            foreach ($f in $list) {
                $ht = @{}
                foreach ($k in $f.Keys) { $ht[$k] = $f[$k] }
                $result += $ht
            }
            return $result
        } catch {
            # Fall through to text parser
        }
    }

    return Parse-ForestsFromText -Text $raw
}

# ---------------------------------------------------------------------------
# Fallback YAML writer
#
# Strategy: treat the config.yaml as three sections:
#   Pre  -- everything before "  forests:"
#   Body -- the forest list entries (    - name: ... through to end of block)
#   Post -- everything after the forest block
#
# We rebuild Body from the (modified) forest list, keeping Pre and Post intact.
# ---------------------------------------------------------------------------
function Get-ConfigSections {
    param([string]$Text)

    $lines   = $Text -split "`r?`n"
    $pre     = [System.Collections.Generic.List[string]]::new()
    $body    = [System.Collections.Generic.List[string]]::new()
    $post    = [System.Collections.Generic.List[string]]::new()

    $phase = 'pre'   # pre | body | post
    $inWorkspace = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if ($phase -eq 'pre') {
            $pre.Add($line)
            if ($line -match '^workspace\s*:') { $inWorkspace = $true }
            if ($inWorkspace -and $line -match '^  forests\s*:') {
                $phase = 'body'
            }
            continue
        }

        if ($phase -eq 'body') {
            # Forest entries start with "    - " or are blank/comment lines within the block
            # The body ends when we see a non-blank line with <= 3 spaces that is not a forest entry
            if ($line -match '^    [ -]' -or $line -match '^      ' -or $line -match '^\s*$') {
                $body.Add($line)
            } else {
                $phase = 'post'
                $post.Add($line)
            }
            continue
        }

        # post
        $post.Add($line)
    }

    return @{ Pre = $pre; Body = $body; Post = $post }
}

function Format-ForestBlock {
    param([hashtable]$Forest)

    $lines = [System.Collections.Generic.List[string]]::new()
    # Name is always first
    $lines.Add("    - name: $($Forest['name'])")
    $ordered = @('relation','module','mode','file','dc','credentials')
    foreach ($key in $ordered) {
        if ($Forest.ContainsKey($key) -and $Forest[$key]) {
            $lines.Add("      $key`: $($Forest[$key])")
        }
    }
    # Any remaining keys not in ordered list
    foreach ($key in $Forest.Keys) {
        if ($key -ne 'name' -and $ordered -notcontains $key -and $Forest[$key]) {
            $lines.Add("      $key`: $($Forest[$key])")
        }
    }
    return $lines
}

function Add-ForestToConfig {
    param([hashtable]$Forest)

    $raw      = Read-ConfigRaw
    $sections = Get-ConfigSections -Text $raw

    if ($script:UseYamlModule) {
        # With module: parse, add, re-serialize (preserves comments partially)
        # But for safety, still use text manipulation to preserve formatting
    }

    $newBlock = Format-ForestBlock -Forest $Forest
    foreach ($l in $newBlock) { $sections.Body.Add($l) }

    $allLines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $sections.Pre)  { $allLines.Add($l) }
    foreach ($l in $sections.Body) { $allLines.Add($l) }
    foreach ($l in $sections.Post) { $allLines.Add($l) }

    # Remove trailing empty lines accumulation at join points
    $content = ($allLines | ForEach-Object { $_ }) -join "`n"
    Write-ConfigRaw -Content $content
}

function Remove-ForestFromConfig {
    param([string]$ForestName)

    $raw   = Read-ConfigRaw
    $lines = [System.Collections.Generic.List[string]]($raw -split "`r?`n")

    # Find the line index of "    - name: <ForestName>"
    $startIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^    - name:\s*$([regex]::Escape($ForestName))\s*$") {
            $startIdx = $i
            break
        }
    }

    if ($startIdx -lt 0) { return $false }

    # Find end of this forest entry: next "    - " line or line with <4 indent
    $endIdx = $lines.Count
    for ($i = $startIdx + 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^    - ' -or ($l -notmatch '^\s*$' -and $l -notmatch '^      ')) {
            $endIdx = $i
            break
        }
    }

    # Remove lines [startIdx, endIdx)
    $newLines = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -lt $startIdx -or $i -ge $endIdx) {
            $newLines.Add($lines[$i])
        }
    }

    Write-ConfigRaw -Content ($newLines -join "`n")
    return $true
}

# ---------------------------------------------------------------------------
# JSON helpers (offline mode)
# ---------------------------------------------------------------------------
function Read-JsonFile {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    # Strip UTF-8 BOM if present
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length-1)]
    }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    return ConvertFrom-Json $text
}

function Write-JsonFile {
    param([string]$Path, [object]$Data)
    $json  = $Data | ConvertTo-Json -Depth 20
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Infer-Module {
    param([object]$JsonData)
    # Infer module from data structure
    $keys = ($JsonData | Get-Member -MemberType NoteProperty).Name
    $adCoreKeys = @('forest','dcs','domains','users','groups','computers','gpos','sites')
    $matches = 0
    foreach ($k in $adCoreKeys) { if ($keys -contains $k) { $matches++ } }
    if ($matches -ge 3) { return 'ad-core' }
    return 'unknown'
}

# ---------------------------------------------------------------------------
# Backup helper
# ---------------------------------------------------------------------------
function Backup-JsonFile {
    param([string]$Path)
    $dir  = Split-Path $Path -Parent
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $ts   = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $dir 'backups'
    if (-not (Test-Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    $dest = Join-Path $backupDir "${base}_${ts}.json"
    Copy-Item -Path $Path -Destination $dest -Force
    return $dest
}

# ---------------------------------------------------------------------------
# WinRM / DC reachability check
# ---------------------------------------------------------------------------
function Test-DcReachable {
    param([string]$DCHost)
    try {
        $result = Test-NetConnection -ComputerName $DCHost -Port 5986 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        return $result
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# -List
# ---------------------------------------------------------------------------
function Invoke-List {
    if (-not (Test-Path $ConfigFile)) {
        Write-Host "  config.yaml not found: $ConfigFile" -ForegroundColor Red
        exit 1
    }

    $forests = Get-Forests

    Write-Host ''
    Write-Host "Forest montati nel workspace (config: $Config)" -ForegroundColor White
    Write-Host ''

    if ($forests.Count -eq 0) {
        Write-Host '  (nessun forest configurato)' -ForegroundColor Yellow
        Write-Host ''
        return
    }

    foreach ($f in $forests) {
        $fname = $f['name']
        $mode  = if ($f.ContainsKey('mode')) { $f['mode'] } elseif ($f.ContainsKey('dc')) { 'live' } else { 'offline' }
        $src   = if ($f.ContainsKey('file')) { $f['file'] } elseif ($f.ContainsKey('dc')) { $f['dc'] } else { '(unknown)' }

        $status = ''
        if ($mode -eq 'offline' -and $f.ContainsKey('file')) {
            if (Test-Path $f['file']) {
                # Check _metadata
                try {
                    $jdata = Read-JsonFile -Path $f['file']
                    $meta  = $jdata._metadata
                    if ($null -eq $meta -or -not $meta.forest) {
                        $status = 'WARN -- metadati incompleti'
                    } else {
                        $status = 'OK'
                    }
                } catch {
                    $status = 'WARN -- JSON non leggibile'
                }
            } else {
                $status = 'ERROR -- file non trovato'
            }
        } elseif ($mode -eq 'live') {
            $status = 'OK (live -- non verificato)'
        } else {
            $status = '?'
        }

        $line = '  {0,-25} [{1,-8}]  {2,-55} {3}' -f $fname, $mode, $src, $status
        $color = if ($status -like 'ERROR*') { 'Red' } elseif ($status -like 'WARN*') { 'Yellow' } else { 'Green' }
        Write-Host $line -ForegroundColor $color
    }

    Write-Host ''
}

# ---------------------------------------------------------------------------
# -Add
# ---------------------------------------------------------------------------
function Invoke-Add {
    if (-not $Name) {
        Write-Err '-Name is required for -Add.'
        exit 1
    }
    if (-not $File -and -not $DC) {
        Write-Err 'Provide -File (offline) or -DC (live) for -Add.'
        exit 1
    }
    if ($File -and $DC) {
        Write-Err 'Provide either -File or -DC, not both.'
        exit 1
    }

    # Check for duplicate
    $existing = Get-Forests
    foreach ($f in $existing) {
        if ($f['name'] -eq $Name) {
            Write-Err "Forest '$Name' already exists in config.yaml."
            exit 1
        }
    }

    # Build forest hashtable
    $forest = @{ name = $Name; relation = $Relation; module = $Module }
    if ($File) { $forest['mode'] = 'offline'; $forest['file'] = $File }
    if ($DC)   { $forest['mode'] = 'live';    $forest['dc']   = $DC   }

    # Pre-validate
    Write-Step "Validating forest '$Name' before adding..."
    $errors = 0; $warnings = 0

    if ($File) {
        if (-not (Test-Path $File)) {
            Write-Err "File not found: $File"
            $errors++
        } else {
            Write-OK "File found: $File"
            try {
                $jdata = Read-JsonFile -Path $File
                Write-OK 'JSON readable.'
                $meta  = $jdata._metadata
                if ($null -eq $meta) {
                    Write-Warn '_metadata block absent -- consider running -RepairMetadata after adding.'
                    $warnings++
                } elseif ($meta.forest -and $meta.forest -ne $Name) {
                    Write-Warn "_metadata.forest '$($meta.forest)' differs from -Name '$Name'."
                    $warnings++
                } else {
                    Write-OK '_metadata present.'
                }
            } catch {
                Write-Err "JSON parse error: $_"
                $errors++
            }
        }

        if (-not [System.IO.Path]::IsPathRooted($File)) {
            Write-Warn "File path is relative. Absolute paths are recommended."
            $warnings++
        }
    }

    if ($DC) {
        Write-Info "Checking WinRM HTTPS on ${DC}:5986..."
        if (Test-DcReachable -DCHost $DC) {
            Write-OK "WinRM HTTPS reachable: $DC"
        } else {
            Write-Warn "WinRM HTTPS not reachable on $DC -- forest added but live queries may fail."
            $warnings++
        }
    }

    if ($errors -gt 0) {
        Write-Host ''
        Write-Host "  Validation failed ($errors error(s)). Forest NOT added." -ForegroundColor Red
        exit 1
    }

    if ($warnings -gt 0 -and -not $Force) {
        Write-Host ''
        Write-Host "  $warnings warning(s) found." -ForegroundColor Yellow
        $answer = Read-Host '  Proceed anyway? [y/N]'
        if ($answer -notmatch '^[yY]') {
            Write-Host '  Aborted by user.'
            exit 0
        }
    }

    Add-ForestToConfig -Forest $forest
    Write-Host ''
    Write-OK "Forest '$Name' added to workspace."
    Write-Host ''
}

# ---------------------------------------------------------------------------
# -Remove
# ---------------------------------------------------------------------------
function Invoke-Remove {
    if (-not $Name) {
        Write-Err '-Name is required for -Remove.'
        exit 1
    }

    if (-not $Force) {
        $answer = Read-Host "  Remove forest '$Name' from config.yaml? The JSON file will NOT be deleted. [y/N]"
        if ($answer -notmatch '^[yY]') {
            Write-Host '  Aborted by user.'
            exit 0
        }
    }

    $ok = Remove-ForestFromConfig -ForestName $Name
    if ($ok) {
        Write-Host ''
        Write-OK "Forest rimosso dal workspace. Il file JSON non e' stato eliminato."
        Write-Host ''
    } else {
        Write-Err "Forest '$Name' not found in config.yaml."
        exit 1
    }
}

# ---------------------------------------------------------------------------
# -Validate
# ---------------------------------------------------------------------------
function Invoke-Validate {
    if (-not (Test-Path $ConfigFile)) {
        Write-Err "config.yaml not found: $ConfigFile"
        exit 1
    }

    $forests  = Get-Forests
    $hasError = $false

    # Filter to single forest if -Name provided
    if ($Name) {
        $forests = $forests | Where-Object { $_['name'] -eq $Name }
        if ($forests.Count -eq 0) {
            Write-Err "Forest '$Name' not found in config.yaml."
            exit 1
        }
    }

    Write-Host ''

    # ------------------------------------------------------------------
    # Per-forest validation
    # ------------------------------------------------------------------
    foreach ($f in $forests) {
        $fname = $f['name']
        $mode  = if ($f.ContainsKey('mode')) { $f['mode'] } elseif ($f.ContainsKey('dc')) { 'live' } else { 'offline' }

        Write-Host $fname -ForegroundColor White

        if ($mode -eq 'offline') {
            if (-not $f.ContainsKey('file') -or -not $f['file']) {
                Write-Err 'Offline forest has no file: path.'
                $hasError = $true
                continue
            }

            $fpath = $f['file']

            if (-not [System.IO.Path]::IsPathRooted($fpath)) {
                Write-Warn "Path is relative: $fpath -- absolute paths are recommended."
            }

            if (-not (Test-Path $fpath)) {
                Write-Err "File not found: $fpath"
                $hasError = $true
            } else {
                Write-OK "File found: $fpath"

                try {
                    $jdata = Read-JsonFile -Path $fpath
                    Write-OK 'JSON structure valid.'

                    $meta = $jdata._metadata
                    if ($null -eq $meta) {
                        Write-Warn '_metadata block absent -- run -RepairMetadata to fix.'
                    } else {
                        # forest name match
                        if ($meta.forest -and $meta.forest -ne $fname) {
                            Write-Warn "_metadata.forest '$($meta.forest)' differs from config name '$fname'."
                        } elseif ($meta.forest) {
                            Write-OK "_metadata.forest matches config name."
                        } else {
                            Write-Warn '_metadata.forest absent -- run -RepairMetadata.'
                        }

                        # collected_at
                        if (-not $meta.collected_at) {
                            Write-Warn '_metadata.collected_at absent -- run -RepairMetadata.'
                        }

                        # collector_version warnings for known old versions
                        if ($meta.collector_version) {
                            $cv = [string]$meta.collector_version
                            if ($cv -match '^1\.[0-3]$') {
                                Write-Warn "_metadata.collector_version: $cv -- group_members and gpo_links may be incomplete."
                            }
                        }

                        # module
                        if (-not $meta.module) {
                            Write-Warn '_metadata.module absent.'
                        }
                    }
                } catch {
                    Write-Err "JSON parse error: $_"
                    $hasError = $true
                }
            }
        } elseif ($mode -eq 'live') {
            $dc = if ($f.ContainsKey('dc')) { $f['dc'] } else { '(not set)' }
            if ($dc -eq '(not set)') {
                Write-Err "Live forest has no dc: field."
                $hasError = $true
            } else {
                Write-OK "DC configured: $dc"
                if (Test-DcReachable -DCHost $dc) {
                    Write-OK "WinRM HTTPS reachable: $dc"
                } else {
                    Write-Warn "WinRM HTTPS not reachable on $dc -- may be offline or firewall blocked."
                }
            }
        }

        Write-Host ''
    }

    # ------------------------------------------------------------------
    # Super-validate: config coherence (only when validating all forests)
    # ------------------------------------------------------------------
    if (-not $Name) {
        Write-Host 'Super-validate -- config coherence' -ForegroundColor White

        $allForests = Get-Forests
        $names = $allForests | ForEach-Object { $_['name'] }

        # Duplicate names
        $duplicates = $names | Group-Object | Where-Object { $_.Count -gt 1 }
        foreach ($dup in $duplicates) {
            Write-Err "Duplicate forest name in config: '$($dup.Name)'"
            $hasError = $true
        }

        # Relative paths
        foreach ($f in $allForests) {
            if ($f.ContainsKey('file') -and $f['file'] -and -not [System.IO.Path]::IsPathRooted($f['file'])) {
                Write-Warn "Forest '$($f['name'])': relative file path '$($f['file'])' -- absolute paths recommended."
            }
        }

        # source without destination and vice versa
        $hasSrc = $allForests | Where-Object { $_['relation'] -eq 'source' }
        $hasDst = $allForests | Where-Object { $_['relation'] -eq 'destination' -or $_['relation'] -eq 'dest' }
        foreach ($s in $hasSrc) {
            if (-not $hasDst) {
                Write-Warn "Forest '$($s['name'])' has relation 'source' but no 'destination' forest is present."
            }
        }
        foreach ($d in $hasDst) {
            if (-not $hasSrc) {
                Write-Warn "Forest '$($d['name'])' has relation 'destination' but no 'source' forest is present."
            }
        }

        # Offline files referenced but not found
        foreach ($f in $allForests) {
            if ($f.ContainsKey('file') -and $f['file'] -and -not (Test-Path $f['file'])) {
                Write-Err "Forest '$($f['name'])': file not found: $($f['file'])"
                $hasError = $true
            }
        }

        Write-Host ''
    }

    if ($hasError) {
        Write-Host '  Validation FAILED -- one or more [ERROR] items require attention.' -ForegroundColor Red
        Write-Host ''
        exit 1
    } else {
        Write-Host '  Validation PASSED.' -ForegroundColor Green
        Write-Host ''
        exit 0
    }
}

# ---------------------------------------------------------------------------
# -RepairMetadata
# ---------------------------------------------------------------------------
function Invoke-RepairMetadata {
    if (-not (Test-Path $ConfigFile)) {
        Write-Err "config.yaml not found: $ConfigFile"
        exit 1
    }

    $allForests = Get-Forests

    # Filter to single forest if -Name provided
    if ($Name) {
        $allForests = $allForests | Where-Object { $_['name'] -eq $Name }
        if ($allForests.Count -eq 0) {
            Write-Err "Forest '$Name' not found in config.yaml."
            exit 1
        }
    }

    # Only offline forests have JSON files to repair
    $offlineForests = $allForests | Where-Object {
        $mode = if ($_.ContainsKey('mode')) { $_['mode'] } elseif ($_.ContainsKey('dc')) { 'live' } else { 'offline' }
        $mode -eq 'offline' -and $_.ContainsKey('file') -and $_['file']
    }

    if ($offlineForests.Count -eq 0) {
        Write-Info 'No offline forests with file paths found. Nothing to repair.'
        exit 0
    }

    foreach ($f in $offlineForests) {
        $fname = $f['name']
        $fpath = $f['file']

        Write-Host ''
        Write-Host "Repairing: $fname" -ForegroundColor White

        if (-not (Test-Path $fpath)) {
            Write-Err "File not found: $fpath -- skipping."
            continue
        }

        # Load JSON
        $jdata = $null
        try {
            $jdata = Read-JsonFile -Path $fpath
        } catch {
            Write-Err "Cannot parse JSON: $_ -- skipping."
            continue
        }

        # Build metadata object if absent
        $changed = $false
        $meta    = $jdata._metadata
        if ($null -eq $meta) {
            Write-Warn '_metadata block absent -- creating.'
            # Add _metadata as new property
            $meta    = New-Object PSObject
            $changed = $true
        }

        # Helper to get/set property on PSObject
        function Get-MetaField { param($Obj, $Field)
            $names = ($Obj | Get-Member -MemberType NoteProperty -ErrorAction SilentlyContinue).Name
            if ($names -contains $Field) { return $Obj.$Field }
            return $null
        }

        function Set-MetaField { param($Obj, $Field, $Value)
            $names = ($Obj | Get-Member -MemberType NoteProperty -ErrorAction SilentlyContinue).Name
            if ($names -contains $Field) {
                $Obj.$Field = $Value
            } else {
                $Obj | Add-Member -MemberType NoteProperty -Name $Field -Value $Value -Force
            }
        }

        # --- Auto-repairable fields ---

        # forest (from config name)
        $curForest = Get-MetaField -Obj $meta -Field 'forest'
        if (-not $curForest) {
            Set-MetaField -Obj $meta -Field 'forest' -Value $fname
            Write-OK "_metadata.forest set to '$fname'."
            $changed = $true
        } elseif ($curForest -ne $fname) {
            Write-Warn "_metadata.forest '$curForest' differs from config name '$fname'. Updating."
            Set-MetaField -Obj $meta -Field 'forest' -Value $fname
            $changed = $true
        } else {
            Write-OK "_metadata.forest OK: $curForest"
        }

        # collected_at (from file modification date)
        $curAt = Get-MetaField -Obj $meta -Field 'collected_at'
        if (-not $curAt) {
            $mtime   = (Get-Item $fpath).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
            Set-MetaField -Obj $meta -Field 'collected_at' -Value $mtime
            Write-Warn "_metadata.collected_at set from file mtime: $mtime (estimated)."
            $changed = $true
        } else {
            Write-OK "_metadata.collected_at OK: $curAt"
        }

        # module (infer from structure)
        $curModule = Get-MetaField -Obj $meta -Field 'module'
        if (-not $curModule) {
            $inferred = Infer-Module -JsonData $jdata
            Set-MetaField -Obj $meta -Field 'module' -Value $inferred
            Write-OK "_metadata.module inferred: $inferred."
            $changed = $true
        } else {
            Write-OK "_metadata.module OK: $curModule"
        }

        # --- Fields requiring confirmation ---

        # collector_version
        $curCv = Get-MetaField -Obj $meta -Field 'collector_version'
        if (-not $curCv) {
            if ($Force) {
                Set-MetaField -Obj $meta -Field 'collector_version' -Value 'unknown'
                Write-Warn "_metadata.collector_version set to 'unknown' (-Force)."
                $changed = $true
            } else {
                $answer = Read-Host '  collector_version is absent. Enter value (or press Enter to set "unknown")'
                $cv = if ($answer.Trim()) { $answer.Trim() } else { 'unknown' }
                Set-MetaField -Obj $meta -Field 'collector_version' -Value $cv
                Write-OK "_metadata.collector_version set to '$cv'."
                $changed = $true
            }
        }

        # forest_level (if present, ask confirmation)
        $curFl = Get-MetaField -Obj $meta -Field 'forest_level'
        if ($null -ne $curFl) {
            if ($Force) {
                Write-OK "_metadata.forest_level kept as-is: $curFl (-Force)."
            } else {
                $answer = Read-Host "  forest_level = '$curFl'. Press Enter to keep, or type new value"
                if ($answer.Trim()) {
                    Set-MetaField -Obj $meta -Field 'forest_level' -Value $answer.Trim()
                    Write-OK "_metadata.forest_level updated to '$($answer.Trim())'."
                    $changed = $true
                }
            }
        }

        # domain_level (if present, ask confirmation)
        $curDl = Get-MetaField -Obj $meta -Field 'domain_level'
        if ($null -ne $curDl) {
            if ($Force) {
                Write-OK "_metadata.domain_level kept as-is: $curDl (-Force)."
            } else {
                $answer = Read-Host "  domain_level = '$curDl'. Press Enter to keep, or type new value"
                if ($answer.Trim()) {
                    Set-MetaField -Obj $meta -Field 'domain_level' -Value $answer.Trim()
                    Write-OK "_metadata.domain_level updated to '$($answer.Trim())'."
                    $changed = $true
                }
            }
        }

        if (-not $changed) {
            Write-OK 'No repairs needed.'
            continue
        }

        # --- Backup before writing ---
        $backupPath = Backup-JsonFile -Path $fpath
        Write-Info "Backup created: $backupPath"

        # Reattach _metadata to jdata
        $names = ($jdata | Get-Member -MemberType NoteProperty).Name
        if ($names -contains '_metadata') {
            $jdata._metadata = $meta
        } else {
            # Prepend _metadata: build new ordered object
            $newObj = New-Object PSObject
            $newObj | Add-Member -MemberType NoteProperty -Name '_metadata' -Value $meta
            foreach ($k in $names) {
                $newObj | Add-Member -MemberType NoteProperty -Name $k -Value $jdata.$k
            }
            $jdata = $newObj
        }

        Write-JsonFile -Path $fpath -Data $jdata
        Write-OK "File updated: $fpath"
    }

    Write-Host ''
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
Write-Host ''
switch ($PSCmdlet.ParameterSetName) {
    'List'          { Invoke-List }
    'Add'           { Invoke-Add }
    'Remove'        { Invoke-Remove }
    'Validate'      { Invoke-Validate }
    'RepairMetadata'{ Invoke-RepairMetadata }
}
