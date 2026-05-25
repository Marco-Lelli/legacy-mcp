# LegacyMCP.Certs.psm1
# TLS certificate management: self-signed generation, import,
# certificate replacement (ReplaceCert workflow).

Import-Module (Join-Path $PSScriptRoot 'LegacyMCP.Common.psm1') -Force -Global

function New-LMSelfSignedCert {
    [CmdletBinding()]
    param(
        [string]$VenvPython,
        [string]$CertDir,
        [int]$ValidityDays = 730,
        [string]$Hostname = ''
    )
    $certFile = Join-Path $CertDir 'server.crt'
    $keyFile  = Join-Path $CertDir 'server.key'

    if (-not (Test-Path $CertDir)) {
        New-Item -ItemType Directory -Path $CertDir -Force | Out-Null
    }

    $env:LEGACYMCP_CERT_FILE     = $certFile
    $env:LEGACYMCP_KEY_FILE      = $keyFile
    $env:LEGACYMCP_CERT_DAYS     = $ValidityDays.ToString()
    $env:LEGACYMCP_CERT_HOSTNAME = $Hostname

    $genPy = @'
import os, socket, datetime, ipaddress
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa

cert_file = os.environ['LEGACYMCP_CERT_FILE']
key_file  = os.environ['LEGACYMCP_KEY_FILE']
hostname  = os.environ.get('LEGACYMCP_CERT_HOSTNAME') or socket.getfqdn()
days      = int(os.environ.get('LEGACYMCP_CERT_DAYS', '730'))

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
now = datetime.datetime.now(datetime.timezone.utc)
subject = issuer = x509.Name([
    x509.NameAttribute(NameOID.COMMON_NAME, hostname),
])
san = x509.SubjectAlternativeName([
    x509.DNSName(hostname),
    x509.DNSName('localhost'),
])
try:
    san._general_names._general_names.append(x509.IPAddress(ipaddress.IPv4Address('127.0.0.1')))
except Exception:
    pass
cert = (x509.CertificateBuilder()
    .subject_name(subject)
    .issuer_name(issuer)
    .public_key(key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(now)
    .not_valid_after(now + datetime.timedelta(days=days))
    .add_extension(san, critical=False)
    .sign(key, hashes.SHA256()))
with open(cert_file, 'wb') as f:
    f.write(cert.public_bytes(serialization.Encoding.PEM))
with open(key_file, 'wb') as f:
    f.write(key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption()))
print('OK')
'@

    & $VenvPython -c $genPy | Out-Null
    Remove-Item Env:LEGACYMCP_CERT_FILE     -ErrorAction SilentlyContinue
    Remove-Item Env:LEGACYMCP_KEY_FILE      -ErrorAction SilentlyContinue
    Remove-Item Env:LEGACYMCP_CERT_DAYS     -ErrorAction SilentlyContinue
    Remove-Item Env:LEGACYMCP_CERT_HOSTNAME -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to generate self-signed certificate."
    }
    Write-LMOK "Self-signed certificate generated: $certFile (valid $ValidityDays days)"
    Write-LMWarn "Clients must trust this CA. Copy $certFile to the consultant PC."
    return @{ CertFile = $certFile; KeyFile = $keyFile }
}

function Import-LMCert {
    [CmdletBinding()]
    param(
        [string]$CertFile,
        [string]$CertKeyFile,
        [string]$CertDir
    )
    if (-not (Test-Path $CertFile))    { throw "Certificate file not found: $CertFile" }
    if (-not (Test-Path $CertKeyFile)) { throw "Key file not found: $CertKeyFile" }

    if (-not (Test-Path $CertDir)) {
        New-Item -ItemType Directory -Path $CertDir -Force | Out-Null
    }
    $destCert = Join-Path $CertDir 'server.crt'
    $destKey  = Join-Path $CertDir 'server.key'
    try {
        Copy-Item -Path $CertFile    -Destination $destCert -Force
        Copy-Item -Path $CertKeyFile -Destination $destKey  -Force
    } catch {
        Write-Error "Import-LMCert: Failed to copy certificate files to '$CertDir': $_"
        exit 1
    }
    Write-LMOK "Certificate copied to $CertDir"
    return @{ CertFile = $destCert; KeyFile = $destKey }
}

function Update-LMYamlSslFields {
    param(
        [string]$YamlPath,
        [string]$SslCertFile,
        [string]$SslKeyFile,
        [string]$VenvPython = ""
    )
    $certLine = "  ssl_certfile: $SslCertFile"
    $keyLine  = "  ssl_keyfile:  $SslKeyFile"

    $rawBytes = [System.IO.File]::ReadAllBytes($YamlPath)
    $hasBom   = ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and
                 $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF)
    try {
        $content = [System.Text.Encoding]::UTF8.GetString($rawBytes)
    } catch {
        $content = [System.Text.Encoding]::GetEncoding(1252).GetString($rawBytes)
    }
    if ($hasBom -and $content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
        $content = $content.Substring(1)
    }

    if ($content -match '(?m)^\s*#?\s*ssl_certfile\s*:') {
        $content = $content -replace '(?m)^\s*#?\s*ssl_certfile\s*:.*', $certLine
    } else {
        $content = $content -replace '(?m)(^server\s*:.*(?:\r?\n(?:[ \t][^\r\n]*))*)', "`$1`n$certLine"
    }
    if ($content -match '(?m)^\s*#?\s*ssl_keyfile\s*:') {
        $content = $content -replace '(?m)^\s*#?\s*ssl_keyfile\s*:.*', $keyLine
    } else {
        $content = $content -replace '(?m)(^\s*ssl_certfile\s*:.*)', "`$1`n$keyLine"
    }

    $tmpPath = "$YamlPath.tmp"
    try {
        [System.IO.File]::WriteAllText($tmpPath, $content, [System.Text.UTF8Encoding]::new($false))
    } catch {
        throw "Update-LMYamlSslFields: Failed to write tmp file '$tmpPath': $_"
    }

    if ($VenvPython -and (Test-Path $VenvPython)) {
        $result = & $VenvPython -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' $tmpPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
            throw "Update-LMYamlSslFields: YAML validation failed after SSL field update: $result"
        }
    }

    try {
        Move-Item -Path $tmpPath -Destination $YamlPath -Force
    } catch {
        Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
        throw "Update-LMYamlSslFields: Failed to replace '$YamlPath' with updated content: $_"
    }
}

# Reserved for future use -- wired into Setup-LegacyMCP.ps1 when -Mode Repair is implemented.
function Invoke-LMReplaceCert {
    [CmdletBinding()]
    param(
        [string]$CertFile,
        [string]$CertKeyFile,
        [string]$CertDir,
        [string]$ConfigPath,
        [string]$ServiceName = 'LegacyMCP'
    )
    if (-not $CertFile -or -not $CertKeyFile) {
        throw "-CertFile and -CertKeyFile are required for ReplaceCert."
    }
    if (-not (Test-Path $CertFile))    { throw "Certificate file not found: $CertFile" }
    if (-not (Test-Path $CertKeyFile)) { throw "Key file not found: $CertKeyFile" }
    if (-not (Test-Path $ConfigPath))  { throw "config.yaml not found at: $ConfigPath" }

    $result = Import-LMCert -CertFile $CertFile -CertKeyFile $CertKeyFile -CertDir $CertDir

    Update-LMYamlSslFields -YamlPath $ConfigPath `
        -SslCertFile $result.CertFile -SslKeyFile $result.KeyFile
    Write-LMOK "ssl_certfile and ssl_keyfile updated in config.yaml."

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        Write-LMInfo "Restarting $ServiceName service..."
        Restart-Service -Name $ServiceName -Force
        Write-LMOK "$ServiceName service restarted."
    } else {
        Write-LMWarn "$ServiceName service not found -- skipping restart."
    }
}

Export-ModuleMember -Function New-LMSelfSignedCert, Import-LMCert, Invoke-LMReplaceCert, Update-LMYamlSslFields
