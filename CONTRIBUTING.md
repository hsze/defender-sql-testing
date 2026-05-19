# Contributing

Thank you for your interest in improving this Defender for SQL testing lab.

## How to contribute

1. **Fork** the repository and create a feature branch.
2. Make your changes.
3. Test your changes (see below).
4. Open a **pull request** with a clear description of what you changed and why.

## What to contribute

- Bug fixes in PowerShell scripts or Bicep templates.
- New KQL queries for additional alert types or analytics scenarios.
- Documentation improvements (quickstart, troubleshooting, prerequisites).
- Support for additional deployment scenarios (e.g., new VM SKUs, regions).
- PaaS alert simulation scripts (currently on the roadmap).

## Testing your changes

Before submitting a PR, verify:

- **PowerShell syntax**: All `.ps1` files parse without errors.
  ```powershell
  Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
      $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors)
      if ($errors) { Write-Warning "$($_.Name): $($errors.Count) parse errors" }
  }
  ```
- **Bicep validation**: Templates build without errors.
  ```powershell
  az bicep build --file infrastructure\bicep\main.bicep
  az bicep build --file arc-enabled\infrastructure\bicep\main.bicep
  ```
- **No secrets**: Ensure no passwords, keys, or tokens are committed.

## Guidelines

- Keep scripts idempotent where possible (safe to re-run).
- Use comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.EXAMPLE`) for PowerShell scripts.
- Use `@description()` decorators for Bicep parameters and resources.
- Avoid Unicode emoji in documentation if possible (use plain ASCII for maximum compatibility).
- Do not add dependencies on external tools beyond the Az PowerShell modules and Azure CLI.

## Code of conduct

Be respectful and constructive. This is a collaborative lab project.
