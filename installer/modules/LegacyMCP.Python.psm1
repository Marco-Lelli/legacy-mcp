# LegacyMCP.Python.psm1
# Python environment management: detection, venv creation, pip install.

function Find-LMPython {
    # Finds a suitable Python 3.10+ installation.
    # Returns the path to python.exe or throws if not found.
    throw "Not implemented"
}

function Test-LMPythonVersion {
    [CmdletBinding()]
    param([string]$PythonExe)
    # Returns $true if Python >= 3.10
    throw "Not implemented"
}

function New-LMVenv {
    [CmdletBinding()]
    param(
        [string]$PythonExe,
        [string]$VenvPath
    )
    throw "Not implemented"
}

function Install-LMPackage {
    [CmdletBinding()]
    param(
        [string]$VenvPath,
        [string]$PackageOrPath,
        [switch]$Editable
    )
    # Runs pip install with --quiet --disable-pip-version-check
    # Checks $LASTEXITCODE explicitly
    throw "Not implemented"
}

Export-ModuleMember -Function *
