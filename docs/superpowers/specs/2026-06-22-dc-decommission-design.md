# Domain Controller Decommissioning — Design

## Goal

Add a new feature that walks an operator through safely decommissioning a domain
controller: DHCP cleanup, DNS cleanup, the actual demotion (DCPROMO), AD metadata
cleanup, and verification. Each step can be run individually ("one by one") or
chained together ("all at once") via a wizard, with confirmation before every
destructive action either way.

## New module: `Modules/Invoke-DCDecommission.ps1`

### Menu entry (new `-- DC DECOMMISSIONING --` section, Local AD only)

A single top-level menu item, **Decommission Wizard** — `Invoke-DCDecommissionWizard`.
Selecting it opens an internal sub-menu (not separate top-level numbered menu
items) listing:

1. **DHCP Cleanup** — `Invoke-DCDhcpCleanup`
2. **DNS Cleanup** — `Invoke-DCDnsCleanup`
3. **Demote Domain Controller** — `Invoke-DCDemote`
4. **AD Metadata Cleanup** — `Invoke-DCMetadataCleanup`
5. **Verify Decommission** — `Invoke-DCDecommissionVerify`
6. **Full Decommission** — runs steps 1-5 in order

Sub-menu options 1-5 are independently runnable ("one by one"). Option 6, **Full
Decommission**, runs them in this exact order, prompting Y/N before each step,
and **stops immediately on the first failure**, reporting which steps completed
and which didn't. The sub-menu loop returns to itself after each step so the
operator can run another step or exit back to the main menu.

### Shared pre-flight check (`Test-DCDecommissionReadiness`, internal helper)

Run at the start of every step (1-5) and once at the top of the Wizard (its
result is then passed to the chained steps so the operator isn't re-prompted for
the target DC name 5 times).

Inputs: target DC name (prompted via `Read-Host` if not supplied as a parameter).

Behavior:

- Determine local vs. remote: compare target name against `$env:COMPUTERNAME` /
  `localhost` / `127.0.0.1` (case-insensitive). Local → run cmdlets directly.
  Remote → use `Invoke-Command -ComputerName <target>` (WinRM), matching the
  pattern already used in `Get-RadiusInfo.ps1`. Pre-check DNS resolution of the
  target before attempting WinRM, same as the RADIUS audit's skip-unresolvable
  pattern.
- **FSMO role check** — `Get-ADDomain` (PDCEmulator, RIDMaster,
  InfrastructureMaster) and `Get-ADForest` (SchemaMaster, DomainNamingMaster).
  If the target hostname matches any role owner: **hard block**. Output lists
  the role(s) held and a sample
  `Move-ADDirectoryServerOperationMasterRole -Identity <newDC> -OperationMasterRole <role>`
  command. No further action taken; the calling step returns immediately.
- **Global Catalog check** — `(Get-ADDomainController -Identity $target).IsGlobalCatalog`.
  If true, enumerate other DCs in the same `Site` and check whether any other is
  also a GC. If this is the **only** GC in its site: **hard block** (risk to
  authentication/sites relying on that site's GC). Reuses the same block-and-return
  pattern as the FSMO check.
- **Replication partner check** — `Get-ADReplicationPartnerMetadata` (or
  `repadmin /showrepl` fallback if the cmdlet errors) to count DCs replicating
  from the target. **Informational only** — displayed as a count, never blocks.
- **Role inventory** — checks whether DNS Server / DHCP Server Windows features
  are installed on the target (`Get-WindowsFeature DNS`, `Get-WindowsFeature DHCP`,
  run locally or via `Invoke-Command`). Displayed so the operator knows which of
  steps 1-2 actually apply; running DHCP/DNS Cleanup on a DC without those roles
  short-circuits with an "[INFO] role not installed, nothing to do" message
  rather than erroring.

Returns a `[PSCustomObject]` with target, IsLocal, blocked (bool), block reasons,
GC/replication info, and role inventory. Every step checks `.Blocked` first and
aborts with the reasons printed if true.

### Step 1 — DHCP Cleanup (`Invoke-DCDhcpCleanup`)

1. Run pre-flight check; abort on block.
2. If DHCP Server feature not installed on target: print "[INFO] DHCP Server
   role not present on this DC — nothing to clean up." and return.
3. Show target + intended actions (unauthorize in AD, uninstall DHCP feature),
   prompt **[Y/N]**.
4. `Get-DhcpServerInDC` to confirm AD registration, then
   `Remove-DhcpServerInDC -DnsName <target>`.
5. `Uninstall-WindowsFeature DHCP` (local) or via `Invoke-Command` (remote).
6. Print per-substep OK/FAILED with timestamp + `$env:USERNAME`, matching
   `Invoke-AccountActions.ps1`'s logging style.
7. Offer HTML export (`Export-HTMLReport -ReportType "DCDecommission"`).

### Step 2 — DNS Cleanup (`Invoke-DCDnsCleanup`)

1. Pre-flight check; abort on block.
2. If DNS Server feature not installed: "[INFO] DNS Server role not present —
   nothing to clean up." and return.
3. Show target + intended actions (remove DNS records referencing the DC,
   uninstall DNS feature), prompt **[Y/N]**.
4. Enumerate and remove the target's A/PTR/NS records from AD-integrated zones
   it's authoritative for (`Get-DnsServerResourceRecord` /
   `Remove-DnsServerResourceRecord`, run against a *surviving* DC, not the
   target being removed, to avoid querying a DNS server about to be torn down).
5. `Uninstall-WindowsFeature DNS` on the target (local or remote).
6. Same logging/export pattern as Step 1.

### Step 3 — Demote (`Invoke-DCDemote`)

1. Pre-flight check; abort on block.
2. Show target + a clear warning that this performs the actual domain
   controller demotion, prompt **[Y/N]**.
3. If remote: `Get-Credential` for an account with rights to demote, then
   `Invoke-Command -ComputerName <target> -Credential <cred>` running
   `Uninstall-ADDSDomainController -Force -RemoveDnsDelegation -ErrorAction Stop`
   (suppressing the interactive confirmation since we already confirmed).
   If local: run the cmdlet directly.
4. Catch and surface failures clearly — this is the step most likely to fail on
   connectivity/credential issues, so the error message is passed through
   verbatim rather than swallowed.
5. Same logging/export pattern as Steps 1-2.

### Step 4 — AD Metadata Cleanup (`Invoke-DCMetadataCleanup`)

1. Pre-flight check; abort on block. (Note: after a successful demotion in Step
   3, the target will no longer hold FSMO/GC roles, so this mostly guards
   against running cleanup against a DC that was never actually demoted.)
2. Check for leftover NTDS Settings object and server object under
   `Get-ADObject` (Sites & Services) for the target.
3. If nothing found: "[OK] No leftover AD metadata found — demotion was clean."
   and return (no destructive action needed).
4. If leftovers found (e.g., demotion was forced/offline and metadata cleanup
   didn't complete): show what was found, require an **additional explicit
   confirmation** beyond the standard Y/N (type the DC name to confirm) since
   this directly removes AD objects outside the normal demotion path, then
   `Remove-ADObject` on the leftover objects.
5. Same logging/export pattern.

### Step 5 — Verify (`Invoke-DCDecommissionVerify`)

1. No pre-flight block check needed (read-only) — just resolve the target name.
2. Confirm the target no longer appears in `Get-ADDomainController -Filter *`.
3. Confirm no lingering DNS records reference it (cross-check against Step 2's
   logic, read-only this time).
4. Confirm no lingering AD Sites & Services objects (cross-check against Step 4).
5. Print a clean PASS/FAIL summary per check.
6. Offer HTML export.

### Decommission Wizard (`Invoke-DCDecommissionWizard`, top-level menu entry)

Entry point for the whole feature. Shows the internal sub-menu (steps 1-5 plus
**Full Decommission**) and loops until the operator chooses to exit back to the
main menu.

**Full Decommission** (sub-menu option 6):

1. Prompt for target DC once.
2. Run pre-flight check once; abort on block before anything else runs.
3. Run Steps 1 → 2 → 3 → 4 → 5 in order, passing the already-known target into
   each (steps accept an optional `-TargetDC` parameter so standalone use still
   prompts interactively, but Full Decommission doesn't re-prompt).
4. Confirm **[Y/N] before each step**, same as standalone use.
5. On any step failure: stop immediately, print which steps completed
   successfully and which one failed (with its error), and skip remaining
   steps.
6. At the end (whether completed fully or stopped early), offer one combined
   HTML export covering all steps that ran, their status, and timestamps.

## `Export-HTML.ps1` changes

- Add `"DCDecommission"` to `Export-HTMLReport`'s `ValidateSet`.
- Add `Build-DCDecommissionHTML` builder, following the `Build-TroubleshootHTML`
  pattern: a table of Step / Status / Timestamp / Details.

## `ADCommander.ps1` changes

- Dot-source `Get-AccountTroubleshoot.ps1`-style: add
  `. (Join-Path $modulePath "Invoke-DCDecommission.ps1")`.
- New `-- DC DECOMMISSIONING --` menu section with a single entry,
  **Decommission Wizard**, marked `(Local AD only)` like other Local-AD-only
  features. The 6 steps live inside `Invoke-DCDecommissionWizard`'s own
  sub-menu, not as separate top-level numbered menu items.
- Renumber the full menu gapless, Exit always last, update the `switch` block
  and the `default` error message range.

## Safety notes (for README)

- Steps 1-4 are genuinely destructive (DHCP/DNS role removal, AD demotion,
  direct `Remove-ADObject` calls). Each requires explicit confirmation, and
  Step 4's destructive path requires typing the DC name to confirm.
- Pre-flight checks hard-block on FSMO role ownership and "last GC in site" —
  these must be resolved (role transfer, ensuring another GC exists) outside
  this tool before decommissioning can proceed. Replication partner count is
  shown for awareness only and never blocks.
- Remote demotion requires credentials with rights to demote a domain
  controller and WinRM connectivity to the target.

## Out of scope

- Automatic FSMO role transfer (operator transfers roles manually, then
  retries).
- Decommissioning via Entra ID / hybrid scenarios — Local AD only, consistent
  with other infrastructure-level features (RADIUS/NPS Audit, AD Health Check).
- Any role removal beyond DNS/DHCP (e.g., certificate authority, file/print
  services) — only the two roles explicitly named in scope.
