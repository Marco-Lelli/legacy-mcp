# TLS Certificate Setup — Profile B

LegacyMCP Profile B requires TLS on all non-localhost endpoints.
This document covers certificate generation, export, and client configuration.

---

## Certificate Options

### Option A — Self-signed SHA-256 (recommended for lab and consulting)

Generated automatically by the installer. If you need to regenerate:

```powershell
.\Config-LegacyMCP.ps1 -Action ReplaceCert
```

The installer uses Python's `cryptography` library to generate a
self-signed SHA-256 certificate. This is necessary because:
- Windows Server 2012 R2 AD CS issues SHA-1 certificates by default
- SHA-1 certificates are incompatible with modern uvicorn/OpenSSL

### Option B — Corporate CA certificate

If your environment has a modern CA (SHA-256), you can use a CA-issued
certificate. Place the files in `certs/`:
- `certs/server.crt` — certificate (PEM)
- `certs/server.key` — private key (PEM)

Then update `config.yaml`:

```yaml
server:
  ssl_certfile: certs/server.crt
  ssl_keyfile: certs/server.key
```

---

## Exporting the Certificate for the Client

The client machine needs the server certificate to validate the TLS connection.
Export it from the server:

```powershell
.\Config-LegacyMCP.ps1 -Action ExportCert -OutputPath "C:\legacy-mcp\certs\server.crt"
```

> **Note**: `Export-Certificate` on PowerShell 5.1 requires a direct path.
> Do not use relative paths.

Transfer `server.crt` to the consultant machine via a secure channel.

---

## Private Key Export

If you need to export the private key, use Python from the venv —
`ExportRSAPrivateKey()` is not available on PowerShell 5.1 / .NET 4.x:

```python
from cryptography.hazmat.primitives.serialization import (
    Encoding, PrivateFormat, NoEncryption, load_pem_private_key
)

with open("certs/server.key", "rb") as f:
    key = load_pem_private_key(f.read(), password=None)

with open("certs/server_export.key", "wb") as f:
    f.write(key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption()))
```

---

## Client Configuration

`NODE_EXTRA_CA_CERTS` must point to the server certificate on the consultant
machine. This is set automatically by `Setup-LegacyMCPClient.ps1` in the
generated `mcp-remote-live.bat`.

Manual configuration if needed:

```bat
SET NODE_EXTRA_CA_CERTS=C:\path\to\server.crt
```

---

## Known Limitations

| Note | Description |
|------|-------------|
| N-TLS-1 | SHA-1 CA certificates (e.g. Windows Server 2012 R2 AD CS default) are incompatible with modern uvicorn/OpenSSL. Use self-signed SHA-256 as workaround. |
| N-TLS-2 | `ExportRSAPrivateKey()` not available on PS 5.1 / .NET 4.x. Use Python cryptography module from venv. |
| N-TLS-3 | `certs/` folder is not in the repository — create it manually before running the installer. |
| N-TLS-4 | `Export-Certificate` on PS 5.1 requires a direct path, not relative. |
| N-TLS-5 | AD CS certificate template must have "Allow private key to be exported" flag enabled. |
