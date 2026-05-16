# LegacyMCP.Python.psm1
# Python environment management: detection, venv creation, pip install.

function Find-LMPython {
    # 1. Try 'python' in PATH
    # 2. Try 'python3' in PATH
    # 3. Try py launcher (py -3)
    # Returns path to python.exe or throws with explicit message
    $candidates = @('python', 'python3')
    foreach ($cmd in $candidates) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) {
            if (Test-LMPythonVersion -PythonExe $found.Source) {
                return $found.Source
            }
        }
    }
    # Try py launcher
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        $pyExe = & py -3 -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $pyExe) {
            if (Test-LMPythonVersion -PythonExe $pyExe.Trim()) {
                return $pyExe.Trim()
            }
        }
    }
    throw "Python 3.10 or later not found. Install from https://python.org and ensure it is in PATH."
}

function Test-LMPythonVersion {
    [CmdletBinding()]
    param([string]$PythonExe)
    try {
        $ver = & $PythonExe --version 2>&1
        if ($ver -match 'Python (\d+)\.(\d+)') {
            $major = [int]$Matches[1]
            $minor = [int]$Matches[2]
            return ($major -gt 3) -or ($major -eq 3 -and $minor -ge 10)
        }
        return $false
    } catch {
        return $false
    }
}

function New-LMVenv {
    [CmdletBinding()]
    param(
        [string]$PythonExe,
        [string]$VenvPath
    )
    if (Test-Path $VenvPath) {
        Write-LMInfo "Virtual environment already exists at '$VenvPath' -- skipping creation."
        return
    }
    & $PythonExe -m venv $VenvPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create virtual environment at '$VenvPath'. " +
              "Check Python installation, available disk space, and antivirus exclusions."
    }
    Write-LMOK "Virtual environment created at '$VenvPath'."
}

function Install-LMPackage {
    [CmdletBinding()]
    param(
        [string]$VenvPath,
        [string]$PackageOrPath,
        [switch]$Editable
    )
    $venvPip = Join-Path $VenvPath 'Scripts\python.exe'
    $pipArgs = @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check')
    if ($Editable) { $pipArgs += '-e' }
    $pipArgs += $PackageOrPath

    & $venvPip @pipArgs
    if ($LASTEXITCODE -ne 0) {
        throw "pip install failed for '$PackageOrPath'. " +
              "Check network connectivity, antivirus exclusions, and pip output above."
    }
    Write-LMOK "Package '$PackageOrPath' installed successfully."
}

Export-ModuleMember -Function *
