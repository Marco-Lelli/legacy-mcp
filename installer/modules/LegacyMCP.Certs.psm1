# LegacyMCP.Certs.psm1
# TLS certificate management: self-signed generation, import,
# certificate replacement (ReplaceCert workflow).

function New-LMSelfSignedCert {
    [CmdletBinding()]
    param(
        [string]$CertDir,
        [string]$Hostname,
        [int]$ValidityDays = 730
    )
    # Generates server.crt and server.key in CertDir
    # Uses Python cryptography inline script
    # ValidityDays default: 730 (2 years)
    throw "Not implemented"
}

function Import-LMCert {
    [CmdletBinding()]
    param(
        [string]$CertFile,
        [string]$CertKeyFile,
        [string]$CertDir
    )
    # Copies provided cert files to CertDir as server.crt / server.key
    throw "Not implemented"
}

function Invoke-LMReplaceCert {
    [CmdletBinding()]
    param(
        [string]$CertFile,
        [string]$CertKeyFile,
        [string]$CertDir,
        [string]$ConfigPath,
        [string]$ServiceName
    )
    # Full ReplaceCert workflow:
    # 1. Copy new cert to CertDir
    # 2. Update ssl_certfile/ssl_keyfile in config.yaml
    # 3. Restart service
    # Logic extracted from Install-LegacyMCP.ps1 -Action ReplaceCert
    throw "Not implemented"
}

Export-ModuleMember -Function *
