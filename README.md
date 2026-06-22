# ADCommander
**Built by Dallas Milem**

> A unified PowerShell toolkit for Active Directory and Entra ID administration. Combines user management, computer search, domain health diagnostics, group management, account actions, and security auditing — all from a single interactive launcher with HTML report export.

---

## Features

| # | Feature | Local AD | Entra ID |
|---|---|:---:|:---:|
| 1 | Search User | ✓ | ✓ |
| 2 | Compare Two Users | ✓ | ✓ |
| 3 | GPO Attributes | ✓ | |
| 4 | Computer Search + BitLocker Key Retrieval | ✓ | |
| 5 | AD Health Check (DC, Replication, DNS, FSMO, GPO, DFSR) | ✓ | |
| 6 | Stale Account Report | ✓ | |
| 7 | Password Expiry Dashboard | ✓ | |
| 8 | Privileged Access Audit | ✓ | |
| 9 | Search Group / List Members | ✓ | ✓ |
| 10 | Compare Two Groups | ✓ | ✓ |
| 11 | Unlock Account | ✓ | |
| 12 | Force Password Reset | ✓ | |
| 13 | Account Troubleshooting Report | ✓ | |
| 14 | RADIUS / NPS Audit | ✓ | |

---

## Requirements

| Requirement | Details |
|---|---|
| PowerShell | 5.1 or later (PowerShell 7+ recommended) |
| OS | Windows (domain-joined for Local AD features) |
| RSAT | Required for Local AD and GPO features |
| Microsoft.Graph | Required for Entra ID features |

ADCommander checks for and offers to install all required modules automatically at startup.

### Manual Installation

**RSAT (ActiveDirectory + GroupPolicy):**
```powershell
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0
```

**Microsoft Graph PowerShell SDK:**
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser -Force
```

---

## File Structure

```
ADCommander/
├── ADCommander.ps1                  # Run this
├── README.md
├── Modules/
│   ├── Install-Requirements.ps1     # Auto module installer
│   ├── Connect-Source.ps1           # Local AD / Entra ID auth
│   ├── Export-HTML.ps1              # Shared HTML report generator
│   ├── Search-User.ps1              # User search (AD + Entra)
│   ├── Compare-Users.ps1            # User comparison with diff
│   ├── Get-UserGPO.ps1              # GPO resultant set
│   ├── Invoke-HealthCheck.ps1       # Full AD domain health check
│   ├── Get-StaleAccounts.ps1        # Inactive user/computer report
│   ├── Get-PasswordExpiry.ps1       # Password expiry dashboard
│   ├── Search-Computer.ps1          # Computer search + BitLocker
│   ├── Get-GroupInfo.ps1            # Group search and comparison
│   ├── Invoke-AccountActions.ps1    # Unlock accounts, force PW reset
│   ├── Get-PrivilegedAccess.ps1     # Privileged group audit
│   ├── Get-AccountTroubleshoot.ps1  # Per-account lockout/bad-password trace
│   └── Get-RadiusInfo.ps1           # RADIUS/NPS role + client audit
└── Reports/                         # HTML reports saved here (auto-created)
```

---

## Usage

```powershell
.\ADCommander.ps1
```

On launch, ADCommander will:
1. Check and offer to install any missing PowerShell modules
2. Detect your current Windows user and offer to connect automatically (30-second countdown, defaults to Yes)
3. If declined, prompt for source: **[L]** Local AD or **[E]** Entra ID

---

## Entra ID Authentication

```
[I] Interactive browser login  — supports MFA, recommended for interactive use
[S] Service Principal          — Client ID + Secret, for automation/shared machines
```

Required Graph API permissions for App Registration:
- `User.Read.All`
- `GroupMember.Read.All`
- `Policy.Read.All`

---

## HTML Reports

All features offer HTML export after displaying results. Reports are saved to:
```
.\Reports\<name>_<type>_<timestamp>.html
```
Reports are fully self-contained (no external dependencies) and safe to share via email or Teams.

---

## Notes

- **Account Actions** (unlock, force password reset) require confirmation before executing and are logged to console with timestamp and operator name.
- **BitLocker key retrieval** requires the `BitLocker` module and the recovery key stored in AD. You will be prompted before the key is displayed.
- **AD Health Check** requires RSAT tools and falls back gracefully when individual tools (e.g. `dcdiag`, `repadmin`) are unavailable.
- This tool performs **read-only** operations except for Unlock Account and Force Password Reset, both of which require explicit confirmation.
- **RADIUS / NPS Audit** queries servers via WinRM (`Invoke-Command`) and requires WinRM connectivity/permissions to the target servers.
- **Account Troubleshooting Report** queries every domain controller individually for bad-password/lockout attributes, so it's slower than other lookups but pinpoints which DC is likely the source of an account lockout. It also reports last password change, computed password expiry date, and last logon (replicated attribute — approximate, not real-time).

---

## Changelog

| Version | Date | Notes |
|---|---|---|
| 1.0 | 2026-06-09 | Initial release — combines ADInsight + AD-Health-Checker + 6 new admin features |
| 1.1 | 2026-06-10 | Added RADIUS / NPS Audit (option 15) |
| 1.2 | 2026-06-21 | Added Account Troubleshooting Report (option 13); renumbered menu so Exit is always last |
| 1.3 | 2026-06-22 | Account Troubleshooting Report: added last password change, password expiry date, and last logon fields |
