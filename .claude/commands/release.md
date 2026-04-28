# Skill: /release

## Scope
Publish a GitHub release by reading title and body from CHANGELOG.md.
Requires `gh` CLI installed and authenticated (`gh auth status`).

## Invocation
```
/release v0.2.1
```

---

## Procedure

### 1. Verify prerequisites

```powershell
gh auth status
```

If `gh` is not authenticated, stop immediately with an explicit error.
Do not proceed.

### 2. Read CHANGELOG.md

Find the section for the requested version. The expected format is:

```
## [X.Y.Z] - YYYY-MM-DD "Evocative Title"
```

Extract:
- **Title**: the quoted string after the date (e.g. `"Webster Closes"`)
- **Body**: everything from the line after the `## [X.Y.Z]` header
  down to (but not including) the next `## [` line

If the section is not found, stop with an explicit error:
```
ERROR: Section for version X.Y.Z not found in CHANGELOG.md.
Make sure CHANGELOG.md has been updated before running /release.
```

### 3. Build the release title

Construct the full title string:
```
vX.Y.Z "Evocative Title"
```

Example: `v0.2.1 "Webster Closes"`

### 4. Write body to temp file

Write the extracted body to a temporary file using UTF-8 without BOM
(P11 — BOM causes silent failures on Windows):

```powershell
$tmpFile = [System.IO.Path]::GetTempFileName()
[System.IO.File]::WriteAllText($tmpFile, $body, [System.Text.UTF8Encoding]::new($false))
```

### 5. Verify the tag exists on GitHub

```powershell
gh release view vX.Y.Z --repo Marco-Lelli/legacy-mcp
```

If the release does not exist, stop with an explicit error:
```
ERROR: Release vX.Y.Z not found on GitHub.
Push the tag first, then run /release.
```

### 6. Edit the release

```powershell
gh release edit vX.Y.Z `
    --title 'vX.Y.Z "Evocative Title"' `
    --notes-file $tmpFile `
    --repo Marco-Lelli/legacy-mcp
```

### 7. Clean up and verify

Delete the temp file, then verify:

```powershell
gh release view vX.Y.Z --repo Marco-Lelli/legacy-mcp
```

Report the title and first few lines of the body as confirmation.

---

## Error handling (P4)

| Condition | Action |
|---|---|
| `gh` not authenticated | Stop, print `gh auth login` instruction |
| Version not in CHANGELOG.md | Stop, explicit error message |
| Release tag not on GitHub | Stop, remind to push tag first |
| `gh release edit` fails | Stop, report full error output |
| Temp file write fails | Stop, report error |

Never leave the release in an inconsistent state.
Never proceed past a failed step.

---

## Rules

- Read CHANGELOG.md — never modify it
- Never create a new release — only edit existing ones (`gh release edit`)
- Never push tags or commits
- Never modify any source file
- If anything is ambiguous, stop and ask Marco
