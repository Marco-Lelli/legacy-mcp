# Contributing to LegacyMCP

Thank you for your interest in contributing to LegacyMCP.

---

## What you can contribute to

LegacyMCP is open-core. Contributions are welcome on the **Core layer** —
everything covered by the scope of Carl Webster's ADDS_Inventory.ps1.

The enterprise layer (GPO analysis, PKI analysis, ESC analysis, DOCX
generation, Azure deployment) is maintained privately by Impresoft 4ward
and is not open for external contributions.

If you are unsure whether your contribution falls in scope, open an issue
first and describe what you want to add.

---

## How to contribute

1. **Fork** the repository and create a branch from `main`.
2. **Make your changes** — one logical change per pull request.
3. **Run the tests** before submitting:
```bash
   python -m venv .venv
   .venv\Scripts\activate
   pip install -e ".[dev]"
   pytest --tb=short -q
```
   All tests must pass. If you add new functionality, add tests for it.
4. **Open a pull request** with a clear description of what changes and why.

---

## Commit style

Use short, descriptive commit messages with a prefix:

| Prefix | Use for |
|--------|---------|
| `feat:` | New tool or feature |
| `fix:` | Bug fix |
| `docs:` | Documentation only |
| `test:` | Test additions or fixes |
| `refactor:` | Code restructuring without behavior change |

Example: `feat: add get_upn_suffix_summary tool`

---

## Code style

- **Python**: follow PEP 8. No external formatter required, but keep
  lines under 100 characters where possible.
- **PowerShell**: PowerShell 5.1 compatible. ASCII-only characters —
  no em dashes, curly quotes, or any character above U+007F.
  Every block that can fail must have an explicit `try/catch`.
- **Tests**: place unit tests in `tests/unit/`. Use the existing
  `contoso-sample.json` fixture for offline mode tests.

---

## Reporting issues

Open an issue on GitHub with:
- LegacyMCP version (or git commit hash)
- Windows Server version of the target environment
- Python version
- Steps to reproduce
- Relevant log output from the LegacyMCP EventLog

---

## License

By contributing to LegacyMCP you agree that your contributions will be
licensed under the MIT License that covers this project.
See [LICENSE](LICENSE) for the full text.

No CLA required. No DCO required. Standard GitHub terms apply.
