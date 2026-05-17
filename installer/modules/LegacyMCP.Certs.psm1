# LegacyMCP.Certs.psm1
# TLS certificate management: self-signed generation, import,
# certificate replacement (ReplaceCert workflow).

Import-Module (Join-Path $PSScriptRoot 'LegacyMCP.Common.psm1') -Force -Global

function New-LMSelfSignedCert {
    [CmdletBinding()]
    param(
        [string]$VenvPython,
        [string]$CertDir,
        [int]$ValidityDays = 730
    )
    $certFile = Join-Path $CertDir 'server.crt'
    $keyFile  = Join-Path $CertDir 'server.key'

    if (-not (Test-Path $CertDir)) {
        New-Item -ItemType Directory -Path $CertDir -Force | Out-Null
    }

    $env:LEGACYMCP_CERT_FILE = $certFile
    $env:LEGACYMCP_KEY_FILE  = $keyFile
    $env:LEGACYMCP_CERT_DAYS = $ValidityDays.ToString()

    $genPy = @'
import os, socket, datetime, ipaddress
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa

cert_file = os.environ['LEGACYMCP_CERT_FILE']
key_file  = os.environ['LEGACYMCP_KEY_FILE']
hostname  = socket.getfqdn()
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
    Remove-Item Env:LEGACYMCP_CERT_FILE  -ErrorAction SilentlyContinue
    Remove-Item Env:LEGACYMCP_KEY_FILE   -ErrorAction SilentlyContinue
    Remove-Item Env:LEGACYMCP_CERT_DAYS  -ErrorAction SilentlyContinue

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
    Copy-Item -Path $CertFile    -Destination $destCert -Force
    Copy-Item -Path $CertKeyFile -Destination $destKey  -Force
    Write-LMOK "Certificate copied to $CertDir"
    return @{ CertFile = $destCert; KeyFile = $destKey }
}

function Update-LMYamlSslFields {
    # Internal helper -- not exported
    param(
        [string]$YamlPath,
        [string]$SslCertFile,
        [string]$SslKeyFile
    )
    # Extracted from Install-LegacyMCP.ps1 lines 65-88
    # Single implementation -- resolves MED-P15-1 (duplicate in Install + Config scripts)
    $certLine = "  ssl_certfile: $SslCertFile"
    $keyLine  = "  ssl_keyfile:  $SslKeyFile"
    $content  = Get-Content $YamlPath -Raw -Encoding UTF8

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
    [System.IO.File]::WriteAllText($YamlPath, $content, [System.Text.UTF8Encoding]::new($false))
}

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
