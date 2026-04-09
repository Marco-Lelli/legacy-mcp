# Third-Party Licenses

LegacyMCP is released under the MIT License.
See [LICENSE](LICENSE) for the full text.

This project includes or depends on the following third-party components.

---

## NSSM — Non-Sucking Service Manager

- Version: 2.24 (2014-08-31)
- License: Public Domain
- Source: https://nssm.cc
- Usage: Windows service management for Profile B deployments.
  Bundled in `installer/tools/`. Not required for Profile A.

---

## mcp-remote

- License: MIT
- Source: https://github.com/modelcontextprotocol/mcp-remote
- Usage: Remote MCP transport bridge for Claude Desktop (Profile B client).
  Not bundled — installed separately by the consultant setup script.

---

## Python Dependencies

The following packages are used at runtime by the LegacyMCP server.
All are installed via pip and not bundled in the repository.

| Name                      | Version   | License                          | URL                                                                  |
|---------------------------|-----------|----------------------------------|----------------------------------------------------------------------|
| PyJWT                     | 2.12.1    | MIT                              | https://github.com/jpadilla/pyjwt                                    |
| PyYAML                    | 6.0.3     | MIT License                      | https://pyyaml.org/                                                  |
| annotated-types           | 0.7.0     | MIT License                      | https://github.com/annotated-types/annotated-types                   |
| anyio                     | 4.12.1    | MIT                              | https://anyio.readthedocs.io/en/stable/versionhistory.html           |
| attrs                     | 25.4.0    | MIT                              | https://www.attrs.org/en/stable/changelog.html                       |
| certifi                   | 2026.2.25 | Mozilla Public License 2.0 (MPL 2.0) | https://github.com/certifi/python-certifi                        |
| cffi                      | 2.0.0     | MIT                              | https://cffi.readthedocs.io/en/latest/whatsnew.html                  |
| charset-normalizer        | 3.4.5     | MIT                              | https://github.com/jawah/charset_normalizer                          |
| click                     | 8.3.1     | BSD-3-Clause                     | https://github.com/pallets/click/                                    |
| colorama                  | 0.4.6     | BSD License                      | https://github.com/tartley/colorama                                  |
| cryptography              | 46.0.5    | Apache-2.0 OR BSD-3-Clause       | https://github.com/pyca/cryptography                                 |
| h11                       | 0.16.0    | MIT License                      | https://github.com/python-hyper/h11                                  |
| httpcore                  | 1.0.9     | BSD-3-Clause                     | https://www.encode.io/httpcore/                                      |
| httpx                     | 0.28.1    | BSD License                      | https://github.com/encode/httpx                                      |
| httpx-sse                 | 0.4.3     | MIT                              | https://github.com/florimondmanca/httpx-sse                          |
| idna                      | 3.11      | BSD-3-Clause                     | https://github.com/kjd/idna                                          |
| jsonschema                | 4.26.0    | MIT                              | https://github.com/python-jsonschema/jsonschema                      |
| jsonschema-specifications | 2025.9.1  | MIT                              | https://github.com/python-jsonschema/jsonschema-specifications       |
| mcp                       | 1.26.0    | MIT License                      | https://modelcontextprotocol.io                                      |
| packaging                 | 26.0      | Apache-2.0 OR BSD-2-Clause       | https://github.com/pypa/packaging                                    |
| pycparser                 | 3.0       | BSD-3-Clause                     | https://github.com/eliben/pycparser                                  |
| pydantic                  | 2.12.5    | MIT                              | https://github.com/pydantic/pydantic                                 |
| pydantic-settings         | 2.13.1    | MIT                              | https://github.com/pydantic/pydantic-settings                        |
| pydantic_core             | 2.41.5    | MIT                              | https://github.com/pydantic/pydantic-core                            |
| pyspnego                  | 0.12.1    | MIT                              | https://github.com/jborean93/pyspnego                                |
| python-dotenv             | 1.2.2     | BSD-3-Clause                     | https://github.com/theskumar/python-dotenv                           |
| python-multipart          | 0.0.22    | Apache-2.0                       | https://github.com/Kludex/python-multipart                           |
| pywin32                   | 311       | Python Software Foundation License | https://github.com/mhammond/pywin32                                |
| pywinrm                   | 0.5.0     | MIT License                      | http://github.com/diyan/pywinrm/                                     |
| referencing               | 0.37.0    | MIT                              | https://github.com/python-jsonschema/referencing                     |
| requests                  | 2.32.5    | Apache Software License          | https://requests.readthedocs.io                                      |
| requests_ntlm             | 1.3.0     | ISC License                      | https://github.com/requests/requests-ntlm                            |
| rpds-py                   | 0.30.0    | MIT                              | https://github.com/crate-py/rpds                                     |
| sse-starlette             | 3.3.2     | BSD-3-Clause                     | https://github.com/sysid/sse-starlette                               |
| sspilib                   | 0.5.0     | MIT                              | https://github.com/jborean93/sspilib                                 |
| starlette                 | 0.52.1    | BSD-3-Clause                     | https://github.com/Kludex/starlette                                  |
| typing-inspection         | 0.4.2     | MIT                              | https://github.com/pydantic/typing-inspection                        |
| typing_extensions         | 4.15.0    | PSF-2.0                          | https://github.com/python/typing_extensions                          |
| urllib3                   | 2.6.3     | MIT                              | https://github.com/urllib3/urllib3                                   |
| uvicorn                   | 0.41.0    | BSD-3-Clause                     | https://uvicorn.dev/                                                 |
| winkerberos               | 0.13.0    | Apache Software License          | https://github.com/mongodb-labs/winkerberos                          |
| xmltodict                 | 1.0.4     | MIT                              | https://github.com/martinblech/xmltodict                             |

---

## Acknowledgements

LegacyMCP Core covers the same Active Directory assessment scope as
Carl Webster's ADDS_Inventory.ps1
(https://github.com/CarlWebster/Active-Directory-V3, GPL v2).
Webster's script is not a dependency of LegacyMCP — it is the
inspiration for the scope and coverage of this project.
Full attribution in [DISCLAIMER.md](DISCLAIMER.md).
