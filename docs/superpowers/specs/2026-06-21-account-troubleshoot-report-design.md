# Account Troubleshooting Report — Design

## Goal
Add a new menu tool that runs a single-account diagnostic report — lockouts, bad-password
trace across DCs, logon restrictions, and group memberships — to speed up account
troubleshooting. Also renumber the main menu so it's gapless and Exit is always last.

## New module: `Modules/Get-AccountTroubleshoot.ps1`

`Invoke-AccountTroubleshootReport` (Local AD only):

1. Prompt for username (SAM or Display Name), resolve via `Get-ADUser`.
2. **Identity/state header**: DisplayName, SAM, Enabled, AccountExpirationDate,
   PasswordExpired, PasswordNeverExpires, LockedOut.
3. **Lockout trace across DCs**: enumerate `Get-ADDomainController -Filter *`, query each
   DC with `Get-ADUser -Server <dc> -Properties badPwdCount,lastBadPasswordAttempt,
   LockedOut,AccountLockoutTime`. Per-DC failures are caught individually and reported as
   "unreachable" rather than aborting. Output sorted so the DC with the most recent
   `lastBadPasswordAttempt` is flagged as the likely lockout source.
4. **Logon restrictions**: LogonHours (custom vs unrestricted, same byte-array compare as
   `Search-User.ps1`), LogonWorkstations.
5. **Group memberships**: resolved group names, same pattern as `Search-User.ps1`.

Console rendering via `Show-TroubleshootTable`, following the section-header style used in
`Get-PasswordExpiry.ps1` / `Get-PrivilegedAccess.ps1`. HTML export via a new
`"AccountTroubleshoot"` entry in `Export-HTMLReport`'s `ValidateSet` and a
`Build-TroubleshootHTML` builder in `Export-HTML.ps1`.

## Menu changes (`ADCommander.ps1`)

New `-- TROUBLESHOOTING --` section after `-- ACCOUNT ACTIONS --`. Full menu renumbered
gapless, Change Source second-to-last, Exit always last:

```
1  Search User
2  Compare Two Users
3  Get GPO Attributes
4  Search Computer
5  AD Health Check
6  Stale Account Report
7  Password Expiry Dashboard
8  Privileged Access Audit
9  Search Group / List Members
10 Compare Two Groups
11 Unlock Account
12 Force Password Reset
13 Account Troubleshooting Report   <- new
14 RADIUS / NPS Audit
15 Change Source
16 Exit
```

`switch` block and `default` error message (`Enter 1-16`) updated to match. `ADCommander.ps1`
also gains a `. (Join-Path $modulePath "Get-AccountTroubleshoot.ps1")` dot-source line.

## Out of scope
- Entra ID support for this report (lockout/bad-password attributes are AD-specific).
- Any new account-action (unlock/reset) capability — this is read-only diagnostics.
