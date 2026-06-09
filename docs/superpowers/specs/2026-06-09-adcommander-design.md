# ADCommander — Design Spec
**Written by Dallas Milem**
**Date:** 2026-06-09

---

## Overview

ADCommander is a unified PowerShell-based Active Directory and Entra ID administration toolkit. It combines the user management features of ADInsight with the domain health capabilities of AD-Health-Checker, and adds six new admin features: stale account reporting, password expiry dashboard, computer search with BitLocker key retrieval, group management, account actions (unlock / force password reset), and a privileged access audit. All features share a single connection, a single HTML report generator, and a consistent interactive menu.

---

## Goals

- Single launcher for all AD/Entra admin tasks
- Shared connection state — authenticate once, use everywhere
- Auto-install required PowerShell modules at startup
- Consistent HTML export across all features
- Read-only by default; write actions (unlock, password reset) require explicit confirmation
- No external dependencies beyond standard Microsoft PowerShell modules

---

## Non-Goals

- Entra ID support for domain-health, GPO, computer, stale accounts, account actions, privileged audit (Local AD only)
- Bulk import/export operations
- Scheduled or automated runs (interactive tool only)
- Any GUI beyond console menus

---

## File Structure

```
ADCommander/
├── ADCommander.ps1               # Main launcher — menu, routing, current-user prompt
├── README.md
└── Modules/
    ├── Install-Requirements.ps1  # Checks & installs required PS modules at startup
    ├── Connect-Source.ps1        # Auth — Local AD / Entra (interactive or SPN)
    ├── Export-HTML.ps1           # Shared HTML report generator (all features)
    ├── Search-User.ps1           # User lookup (AD + Entra)
    ├── Compare-Users.ps1         # Side-by-side user diff (AD + Entra)
    ├── Get-UserGPO.ps1           # GPO resultant set (Local AD only)
    ├── Invoke-HealthCheck.ps1    # AD domain health (refactored from AD-Health-Checker)
    ├── Get-StaleAccounts.ps1     # Inactive users/computers report (Local AD only)
    ├── Get-PasswordExpiry.ps1    # Password expiry dashboard (Local AD only)
    ├── Search-Computer.ps1       # Computer search + BitLocker key retrieval (Local AD only)
    ├── Get-GroupInfo.ps1         # Group search, member list, group comparison (AD + Entra)
    ├── Invoke-AccountActions.ps1 # Unlock accounts, force password reset (Local AD only)
    └── Get-PrivilegedAccess.ps1  # Privileged group audit (Local AD only)
```

---

## Main Launcher — ADCommander.ps1

- Displays banner: `ADCommander v1.0 — Written by Dallas Milem`
- Runs `Install-Requirements` first, before any other action
- Prompts "Run as current user?" with 30-second countdown (defaults yes) — auto-connects to Local AD
- If declined or connection fails, falls through to manual source selection
- Dot-sources all 13 module files
- Main menu loop with grouped sections:

```
  -- USER MANAGEMENT --
    [1]  Search User
    [2]  Compare Two Users
    [3]  Get GPO Attributes          (Local AD only)

  -- COMPUTER MANAGEMENT --
    [4]  Search Computer             (Local AD only)

  -- DOMAIN HEALTH --
    [5]  AD Health Check             (Local AD only)
    [6]  Stale Account Report        (Local AD only)
    [7]  Password Expiry Dashboard   (Local AD only)
    [8]  Privileged Access Audit     (Local AD only)

  -- GROUP MANAGEMENT --
    [9]  Search Group / List Members
    [10] Compare Two Groups

  -- ACCOUNT ACTIONS --
    [11] Unlock Account              (Local AD only)
    [12] Force Password Reset        (Local AD only)

  -- SYSTEM --
    [13] Change Source
    [14] Exit
```

- Local-AD-only options display grayed out with "(unavailable)" when Entra is the active source

---

## Module: Install-Requirements.ps1

**Function: `Install-ADCommanderRequirements`**

Runs at startup. Checks each required module and offers to install missing ones.

| Module | Used By | Install Method |
|---|---|---|
| `ActiveDirectory` | All Local AD features | `Add-WindowsCapability` (RSAT) |
| `GroupPolicy` | GPO report, Health Check | `Add-WindowsCapability` (RSAT) |
| `Microsoft.Graph.Authentication` | Entra features | `Install-Module Microsoft.Graph` |
| `Microsoft.Graph.Users` | Entra user search | `Install-Module Microsoft.Graph` |
| `Microsoft.Graph.Groups` | Entra group features | `Install-Module Microsoft.Graph` |
| `BitLocker` | Computer Search key retrieval | Built-in Windows module, import only |

For RSAT modules: displays the exact `Add-WindowsCapability` command and prompts `[Y/N]` to run it automatically (requires elevation — warns if not running as admin).
For `Microsoft.Graph`: prompts `[Y/N]` to run `Install-Module Microsoft.Graph -Scope CurrentUser -Force`.
For `BitLocker`: attempts `Import-Module BitLocker` silently; marks as unavailable if absent (non-fatal).

Continues to launch even if some modules are missing — missing-module features show a clear error when invoked rather than blocking startup.

---

## Module: Connect-Source.ps1

Unchanged from ADInsight. Manages `$script:ADSource` ("LocalAD" or "Entra"). Exposes:
- `Connect-LocalAD` — verifies ActiveDirectory module, tests DC connectivity
- `Connect-EntraID` — interactive browser or service principal auth via Microsoft.Graph
- `Get-ADSource` — returns current source string

---

## Module: Export-HTML.ps1

Shared HTML generator. Extended from ADInsight to support additional report types.

**Function: `Export-HTMLReport`**
- Parameters: `$Data`, `$ReportType`, `$Username`, `$Source`
- Report types: `SearchResult`, `Comparison`, `GPOReport`, `HealthCheck`, `StaleAccounts`, `PasswordExpiry`, `ComputerSearch`, `GroupInfo`, `GroupComparison`, `PrivilegedAccess`
- Output: `.\Reports\<identifier>_<type>_<timestamp>.html`
- Self-contained HTML with inline CSS, dark header bar, ADCommander branding
- Diff rows highlighted red/green in comparison reports
- Status badges (green/yellow/red) in health and audit reports

---

## Module: Search-User.ps1

Unchanged from ADInsight. Functions: `Invoke-UserSearch`, `Search-LocalADUser`, `Search-EntraUser`, `Show-UserTable`, `Prompt-HTMLExport`.

---

## Module: Compare-Users.ps1

Unchanged from ADInsight. Functions: `Invoke-UserComparison`, `Build-ComparisonRows`, `Show-ComparisonTable`.

---

## Module: Get-UserGPO.ps1

Unchanged from ADInsight. Functions: `Invoke-UserGPOReport`, `Get-GPOResultantSet`, `Get-GPResultFallback`, `Show-GPOTable`, `Prompt-GPOHTMLExport`.

---

## Module: Invoke-HealthCheck.ps1

Refactored from AD-Health-Checker. Broken into per-category functions following ADCommander module conventions.

**Function: `Invoke-ADHealthCheck`** — orchestrator, calls all check functions, collects results, displays summary, offers HTML export.

Check categories (each as its own function):
- `Get-DCDiagResults` — runs `dcdiag /v`, `/test:services`, `/test:advertising`
- `Get-ReplicationResults` — `repadmin /replsummary`, `/showrepl`, `/queue`
- `Get-DFSRResults` — `dfsrmig /getglobalstate`, `dfsrdiag backlog`
- `Get-DNSResults` — SRV record lookup, `ipconfig /all`, DNS zone info
- `Get-FSMOResults` — `netdom query fsmo`, `Get-ADDomain`, `Get-ADForest`, `w32tm` status
- `Get-GPHealthResults` — `gpresult /r`, GPO health checks
- `Get-PrivGroupResults` — Domain Admins and Enterprise Admins membership
- `Get-ForestInfoResults` — functional levels, domain/forest structure

Each function returns a `[PSCustomObject]` with `Category`, `Status` (Pass/Warning/Fail), and `Output` fields. HTML report uses collapsible sections with color-coded status badges identical to the original AD-Health-Checker output style.

---

## Module: Get-StaleAccounts.ps1

**Function: `Invoke-StaleAccountReport`**

Prompts for inactivity threshold (default 90 days). Queries:
- Users inactive for >= threshold days (`LastLogonDate`)
- Computers inactive for >= threshold days
- Disabled user accounts that still hold group memberships (security risk)

Displays three sections in console. Offers HTML export. Reports include account name, last logon, OU, and (for disabled accounts) group list.

---

## Module: Get-PasswordExpiry.ps1

**Function: `Invoke-PasswordExpiryReport`**

Prompts for look-ahead window (default 14 days). Queries all enabled users, calculates expiry from `PasswordLastSet` + domain max password age policy. Displays:
- Users expiring within the window (sorted soonest first)
- Users with "Password Never Expires" flagged
- Users whose passwords are already expired

Offers HTML export.

---

## Module: Search-Computer.ps1

**Function: `Invoke-ComputerSearch`**

Prompts for computer name (partial match supported). Retrieves:
- Name, OS, OS Version, Last Logon, Enabled status
- OU / Distinguished Name
- Description, IPv4 address (from AD)
- Ping status (live `Test-Connection`)
- BitLocker recovery key from AD (if `BitLocker` module available and key exists — prompts confirmation before displaying)

Offers HTML export.

---

## Module: Get-GroupInfo.ps1

**Function: `Invoke-GroupSearch`** — search a group by name, display all members with enabled/disabled status and last logon (Local AD) or account status (Entra).

**Function: `Invoke-GroupComparison`** — compare two groups: shows members in Group 1 only, Group 2 only, and in both. Same diff pattern as user comparison. Offers HTML export.

---

## Module: Invoke-AccountActions.ps1

**Function: `Invoke-UnlockAccount`**
- Prompts for username, finds matching locked accounts
- Displays account details and prompts `[Y/N]` confirmation
- Calls `Unlock-ADAccount`, displays result with timestamp

**Function: `Invoke-ForcePasswordReset`**
- Prompts for username, finds account
- Displays account details and prompts `[Y/N]` confirmation with warning
- Sets `ChangePasswordAtLogon = $true` via `Set-ADUser`
- Optionally sets a temporary password via `Set-ADAccountPassword` if admin provides one

Both functions log the action (who ran it, timestamp, target account) to console output.

---

## Module: Get-PrivilegedAccess.ps1

**Function: `Invoke-PrivilegedAccessAudit`**

Pulls membership of:
- Domain Admins
- Enterprise Admins
- Schema Admins
- Protected Users
- Account Operators
- Backup Operators

For each member shows: Display Name, SAM account, Enabled status, Last Logon, Password Last Set. Flags:
- Disabled accounts in privileged groups (red)
- Accounts inactive 90+ days (yellow)

Offers HTML export.

---

## Error Handling

- Missing modules: friendly message with install instructions, feature exits cleanly back to menu
- User/computer/group not found: clear message, returns to menu
- Write actions (unlock, password reset): require explicit `[Y/N]` confirmation, never proceed silently
- DC unreachable: timeout with fallback message
- Entra auth failure: displays Graph error, returns to source selection

---

## Dependencies

| Module | Required For | Install |
|---|---|---|
| `ActiveDirectory` | All Local AD features | RSAT: `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0` |
| `GroupPolicy` | GPO + Health Check | RSAT: `Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0` |
| `Microsoft.Graph` | Entra features | `Install-Module Microsoft.Graph -Scope CurrentUser` |
| `BitLocker` | Computer key retrieval | Built-in Windows module |

---

## Entra ID Feature Matrix

| Feature | Local AD | Entra ID |
|---|---|---|
| Search User | ✓ | ✓ |
| Compare Users | ✓ | ✓ |
| GPO Attributes | ✓ | — |
| Computer Search | ✓ | — |
| AD Health Check | ✓ | — |
| Stale Accounts | ✓ | — |
| Password Expiry | ✓ | — |
| Group Search | ✓ | ✓ |
| Compare Groups | ✓ | ✓ |
| Unlock Account | ✓ | — |
| Force PW Reset | ✓ | — |
| Privileged Audit | ✓ | — |
