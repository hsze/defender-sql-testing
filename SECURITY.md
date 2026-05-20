# Security Policy

## Scope

This repository is a **testing and validation lab** for Microsoft Defender for Cloud SQL protection. It is designed to generate simulated security alerts in isolated Azure environments -- it is NOT a penetration testing toolkit and should NOT be used against production systems.

## Lab-only warning

The scripts in this repository:

- Create SQL Server logins with elevated privileges (`sysadmin` role).
- Enable the `sa` account with a user-supplied password.
- Disable SQL Server password policy checking on test logins.
- Open network ports (RDP 3389, SQL 1433) with broad NSG rules.
- Pass credentials via `Invoke-AzVMRunCommand` parameters.

**These configurations are intentionally permissive for lab testing.** Do not use these scripts or patterns in production environments. Always:

- Use a dedicated, isolated Azure subscription or resource group for testing.
- Use unique, strong passwords that are not reused from other systems.
- Clean up all resources immediately after testing with `Remove-Resources.ps1`.
- Rotate or delete any credentials created during the lab.

## Reporting security issues

If you discover a security vulnerability in the scripts or documentation in this repository, please report it responsibly:

1. **Do NOT open a public GitHub issue** for security vulnerabilities.
2. Contact the repository maintainer directly via email or private message.
3. Include a description of the issue, steps to reproduce, and potential impact.

We will acknowledge receipt within 48 hours and work to address the issue promptly.

## Supported versions

Only the latest version on the `master` branch is actively maintained. There are no LTS or backport commitments for this lab repository.

## Credential handling

- Passwords are accepted as `[SecureString]` parameters in deployment scripts.
- The simulation wrapper (`Run-AllIaaSSimulations.ps1`) accepts passwords as plain strings because they are passed to `Invoke-AzVMRunCommand -Parameter` and interpolated into remote scripts. This is a known limitation of the VM Run Command interface.
- **Never commit passwords or secrets to this repository.**
- The `.gitignore` excludes common secret file patterns (`secrets.json`, `*.key`, `*.pfx`, `local.settings.json`).
