# LegacyMCP — Design Principles

This document defines the core principles that guide every decision in LegacyMCP,
from architecture to implementation to documentation.
When in doubt, come back here.

---

## 1. The MCP server never runs on a Domain Controller

The server is an observer of the AD infrastructure, not a participant.
Running it on a DC would violate the separation between the tool and the
environment it analyzes, and introduce unnecessary security risk.

## 2. Collector and Live Mode are always aligned

Same data structure, same behavior, same scope.
If the collector iterates all Domain Controllers in a forest,
Live Mode does the same. Silent discrepancies between the two modes
are never acceptable.

Corollary: every section collected via Invoke-Command must explicitly
exclude PS* artefact fields (PSComputerName, RunspaceId, PSShowComputerName)
both in the collector (at source, via Select-Object -ExcludeProperty) and in
loader.py (as a safety net). When adding a new module that uses Invoke-Command,
both touch points are mandatory.

Corollary: every Live Mode section must emit explicit field sets — via
`[PSCustomObject]` with named properties or `Select-Object` of named
properties — never raw pipeline objects passed through unmodified. This
is the primary defense that keeps PS* artefact fields out of the output;
the corollary above about stripping those fields at the two touch points
is the safety net behind it, not the first line of defense.

Corollary: alignment between Collector and Live Mode must target the
correct behavior, not merely mirror whatever the other side currently
does. A prior alignment is not proof of correctness — if one side had a
defect, aligning the other side to match it only doubles the defect. Any
fix to one side must be verified against the other before the task is
considered complete.

## 3. Kerberos only — NTLM is not a fallback

NTLM is deprecated and must not be used as a transport or fallback mechanism.
Live Mode authentication uses Kerberos exclusively. No exceptions.

## 4. Every failure point has explicit error handling

Every PowerShell block that can fail has a try/catch.
Every network call, WinRM session, and AD query handles failures explicitly.
Silent failures are not acceptable.

Corollary: failure points involving secrets or authentication (API key
decryption, TLS private keys, credential material) must fail safe — the
server refuses to start rather than proceed unprotected. This is distinct
from Principle 10, which governs soft degradation on AD data collection
only. A failure to decrypt a credential is never treated the same as a
failure to reach a Domain Controller.

## 5. Open boundary follows Webster's scope

LegacyMCP Core covers everything in Carl Webster's ADDS_Inventory.ps1 —
no more, no less. Features that go beyond that boundary belong in the
Enterprise layer and are not accepted in this repository.

## 6. Security-first when in doubt

When two approaches achieve the same result, choose the more secure one.
Choosing the less secure option requires an explicit architectural discussion
and a documented decision.

## 7. Security by design, not by configuration

TLS, DPAPI-protected API keys, Bearer authentication.
Security is built into the architecture, not left as a deployment decision.

## 8. The simplest solution that works is the right solution

Complexity must be justified. If a simpler approach achieves the same result,
use it. "BAT is King" — learned in the field, never forgotten.

## 9. Resilience to external factors

The code does not assume a stable external environment.
OS versions, AD configurations, PowerShell module availability:
all external dependencies are handled with explicit fallbacks.

## 10. Soft degradation on data collection

If a data point is unavailable or its collection fails, the field is left empty.
Collection failures are never blocking. The goal is always a partial result
over no result.

## 11. UTF-8 without BOM, always

All files — JSON, YAML, Python, PowerShell — are UTF-8 without BOM.
No exceptions. BOM causes silent parse failures that are hard to diagnose.

## 12. English in code, docs and commits — always

All code, documentation, commit messages, changelogs, and output strings
are in English. No exceptions.

## 13. No sensitive data in the repository

API keys, certificates, real AD environment JSON files, and credentials
never enter the repository. This applies to all branches and all history.

## 14. What, not how, in public documentation

Public documentation describes what each deployment profile does.
Implementation details of the Enterprise layer are never disclosed
in public-facing documents.

## 15. Separation of concerns: principles vs implementation

Design decisions, expected outcomes, and principles are defined explicitly
before implementation begins. Implementation is then delegated to tooling.
This separation is not negotiable.

## 16. Documentation follows every significant change

No significant change is considered complete without updating
the corresponding documentation. Code and docs move together.

## 17. Field testing before closing

No session involving Live Mode or Profile B changes is closed without 
testing on the reference environment (LegacyMCP live against DC) to confirm
end-to-end behavior in a real AD context.

Corollary: any new section or modification that queries a Domain Controller
must be evaluated against the POLP matrix in docs/minimum-permissions.md.
If the operation requires permissions beyond the certified baseline, the
matrix must be updated and re-certified before closing.

## 18. Every module declares what it uses

A module must never rely on another module's function, variable, or import
having already been loaded by whatever happens to import it first. If
module B calls a function defined in module A, module B must import
module A explicitly — regardless of what the host script does today.
Implicit dependencies on load order are fragile: they work by coincidence
and break silently the moment that order changes.

(Origin: two distinct regressions in session #59 caused by exactly this —
Write-CollectorLog invisible to modules when the invocation order changed,
and Get-PrivilegedGroupNames lost when another module's import order
changed.)
