# DC Decommissioning Wizard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Decommission Wizard" feature to ADCommander that walks an operator through safely decommissioning a domain controller — DHCP cleanup, DNS cleanup, demotion (DCPROMO), AD metadata cleanup, and verification — runnable step-by-step or all at once.

**Architecture:** One new module, `Modules/Invoke-DCDecommission.ps1`, follows the existing per-module pattern (e.g. `Invoke-AccountActions.ps1`, `Get-RadiusInfo.ps1`): self-contained functions that prompt via `Read-Host`, confirm before destructive actions, log with timestamp + `$env:USERNAME`, and offer HTML export via `Export-HTMLReport`. A shared `Test-DCDecommissionReadiness` helper runs the FSMO/GC/replication/role-inventory pre-flight check once and is reused by every step. The top-level menu gains a single `[15] Decommission Wizard` entry whose own internal sub-menu (steps 1-5 plus "Full Decommission") replaces what would otherwise be 6 separate top-level menu items.

**Tech Stack:** PowerShell 5.1+, `ActiveDirectory` module (RSAT), `ADDSDeployment` module (for `Uninstall-ADDSDomainController`), `DnsServer`/`DhcpServer` modules, `Invoke-Command`/WinRM for remote targets.

**Testing approach:** This codebase has no Pester suite and no mocking layer for AD/DNS/DHCP cmdlets (consistent with every other module here — `Get-AccountTroubleshoot.ps1`, `Invoke-AccountActions.ps1`, etc. have none either, since they require a live domain to exercise meaningfully). Each task's "test" step is a PowerShell parser syntax check, the same technique already used in this project to validate `Get-AccountTroubleshoot.ps1`:

```powershell
pwsh -NoProfile -Command '
$errors = $null; $tokens = $null
[System.Management.Automation.Language.Parser]::ParseFile("<file>", [ref]$tokens, [ref]$errors)
if ($errors.Count -eq 0) { Write-Host "OK: no syntax errors" } else { $errors | ForEach-Object { Write-Host $_.Message } }
'
```

Live verification against a real lab AD/DC is out of scope for this plan and must be done manually afterward (the operator has previously confirmed they will run that testing themselves).

---

## File Structure

- **Create:** `Modules/Invoke-DCDecommission.ps1` — pre-flight helper + 5 step functions + wizard + full-decommission orchestrator
- **Modify:** `Modules/Export-HTML.ps1` — add `"DCDecommission"` to the `ValidateSet`, add `Build-DCDecommissionHTML`
- **Modify:** `ADCommander.ps1` — dot-source the new module, add `-- DC DECOMMISSIONING --` menu section, renumber `Change Source`/`Exit`, update `switch` and error message
- **Modify:** `README.md` — changelog entry for the new feature (the Features table and safety note were already added in a prior commit on this branch)

---

### Task 1: Pre-flight readiness check

**Files:**
- Create: `Modules/Invoke-DCDecommission.ps1`

- [ ] **Step 1: Write the module header and `Test-DCDecommissionReadiness` function**

```powershell
# Modules/Invoke-DCDecommission.ps1
# Written by Dallas Milem

function Test-DCDecommissionReadiness {
    param(
        [string]$TargetDC
    )

    if ([string]::IsNullOrWhiteSpace($TargetDC)) {
        $TargetDC = Read-Host "`nEnter the target domain controller (FQDN or hostname) to decommission"
    }
    if ([string]::IsNullOrWhiteSpace($TargetDC)) {
        Write-Host "[ERROR] No target DC provided." -ForegroundColor Red
        return $null
    }

    $result = [PSCustomObject]@{
        TargetDC                = $TargetDC
        IsLocal                 = $false
        Blocked                 = $false
        BlockReasons            = @()
        IsGlobalCatalog         = $false
        ReplicationPartnerCount = 0
        DnsInstalled            = $false
        DhcpInstalled           = $false
    }

    $shortTarget = ($TargetDC -split '\.')[0]
    $localNames  = @($env:COMPUTERNAME, "localhost", "127.0.0.1")
    if ($localNames -contains $TargetDC -or $localNames -contains $shortTarget) {
        $result.IsLocal = $true
    }

    if (-not $result.IsLocal) {
        try {
            [System.Net.Dns]::GetHostAddresses($TargetDC) | Out-Null
        } catch {
            $result.Blocked = $true
            $result.BlockReasons += "Target '$TargetDC' does not resolve in DNS."
            return $result
        }
    }

    try {
        $dc  = Get-ADDomainController -Identity $TargetDC -ErrorAction Stop
        $dom = Get-ADDomain -ErrorAction Stop
        $for = Get-ADForest -ErrorAction Stop
    } catch {
        $result.Blocked = $true
        $result.BlockReasons += "Could not query AD for '$TargetDC': $_"
        return $result
    }

    # Hard block: FSMO role ownership. Reuses the same role/holder model as
    # Invoke-FSMORoleTransfer in Invoke-HealthCheck.ps1.
    $fsmoRoles = @(
        @{ Name = "PDC Emulator";          Role = "PDCEmulator";          Holder = $dom.PDCEmulator },
        @{ Name = "RID Master";            Role = "RIDMaster";            Holder = $dom.RIDMaster },
        @{ Name = "Infrastructure Master"; Role = "InfrastructureMaster"; Holder = $dom.InfrastructureMaster },
        @{ Name = "Schema Master";         Role = "SchemaMaster";         Holder = $for.SchemaMaster },
        @{ Name = "Domain Naming Master";  Role = "DomainNamingMaster";   Holder = $for.DomainNamingMaster }
    )
    $heldRoles = $fsmoRoles | Where-Object {
        $holderShort = ($_.Holder -split '\.')[0]
        $holderShort -eq $shortTarget -or $_.Holder -eq $TargetDC
    }
    if ($heldRoles.Count -gt 0) {
        $result.Blocked = $true
        foreach ($r in $heldRoles) {
            $result.BlockReasons += "Holds the $($r.Name) FSMO role. Transfer it first, e.g.: Move-ADDirectoryServerOperationMasterRole -Identity <newDC> -OperationMasterRole $($r.Role)"
        }
    }

    # Hard block: last Global Catalog in its site.
    $result.IsGlobalCatalog = [bool]$dc.IsGlobalCatalog
    if ($result.IsGlobalCatalog) {
        try {
            $siteGCs = Get-ADDomainController -Filter { Site -eq $dc.Site -and IsGlobalCatalog -eq $true } -ErrorAction Stop
        } catch {
            $siteGCs = @($dc)
        }
        $otherGCs = $siteGCs | Where-Object { $_.Name -ne $dc.Name }
        if (@($otherGCs).Count -eq 0) {
            $result.Blocked = $true
            $result.BlockReasons += "Is the only Global Catalog in site '$($dc.Site)'. Promote another DC in that site to GC first."
        }
    }

    # Informational only: replication partner count never blocks.
    try {
        $partners = Get-ADReplicationPartnerMetadata -Target $TargetDC -PartnerType Inbound -ErrorAction Stop
        $result.ReplicationPartnerCount = @($partners).Count
    } catch {
        $result.ReplicationPartnerCount = -1
    }

    # Role inventory: drives whether DHCP/DNS Cleanup steps have anything to do.
    try {
        if ($result.IsLocal) {
            $dnsFeat  = Get-WindowsFeature -Name DNS  -ErrorAction SilentlyContinue
            $dhcpFeat = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
        } else {
            $featResult = Invoke-Command -ComputerName $TargetDC -ScriptBlock {
                [PSCustomObject]@{
                    Dns  = Get-WindowsFeature -Name DNS  -ErrorAction SilentlyContinue
                    Dhcp = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
                }
            } -ErrorAction Stop
            $dnsFeat  = $featResult.Dns
            $dhcpFeat = $featResult.Dhcp
        }
        $result.DnsInstalled  = [bool]($dnsFeat  -and $dnsFeat.Installed)
        $result.DhcpInstalled = [bool]($dhcpFeat -and $dhcpFeat.Installed)
    } catch {
        # Non-blocking: role inventory just won't be known.
    }

    return $result
}

function Show-DCDecommissionReadiness {
    param([Parameter(Mandatory)][PSCustomObject]$Readiness)

    Write-Host ""
    Write-Host "  Target DC:            $($Readiness.TargetDC)" -ForegroundColor Yellow
    Write-Host "  Execution mode:       $(if ($Readiness.IsLocal) { 'Local' } else { 'Remote (WinRM)' })"
    Write-Host "  Global Catalog:       $($Readiness.IsGlobalCatalog)"
    Write-Host "  Replication partners: $(if ($Readiness.ReplicationPartnerCount -lt 0) { 'Unknown' } else { $Readiness.ReplicationPartnerCount })"
    Write-Host "  DNS Server role:      $($Readiness.DnsInstalled)"
    Write-Host "  DHCP Server role:     $($Readiness.DhcpInstalled)"
    Write-Host ""

    if ($Readiness.Blocked) {
        Write-Host "  [BLOCKED] This DC cannot be decommissioned yet:" -ForegroundColor Red
        foreach ($reason in $Readiness.BlockReasons) {
            Write-Host "    - $reason" -ForegroundColor Red
        }
        Write-Host ""
    }
}
```

- [ ] **Step 2: Run the syntax check**

Run:
```bash
pwsh -NoProfile -Command '
$errors = $null; $tokens = $null
[System.Management.Automation.Language.Parser]::ParseFile("Modules/Invoke-DCDecommission.ps1", [ref]$tokens, [ref]$errors)
if ($errors.Count -eq 0) { Write-Host "OK: no syntax errors" } else { $errors | ForEach-Object { Write-Host $_.Message } }
'
```
Expected: `OK: no syntax errors`

- [ ] **Step 3: Commit**

```bash
git add Modules/Invoke-DCDecommission.ps1
git commit -m "feat: add DC decommission pre-flight readiness check"
```

---

### Task 2: DHCP Cleanup step

**Files:**
- Modify: `Modules/Invoke-DCDecommission.ps1`

- [ ] **Step 1: Append `Invoke-DCDhcpCleanup`**

```powershell
function Invoke-DCDhcpCleanup {
    param(
        [string]$TargetDC,
        [PSCustomObject]$Readiness,
        [switch]$SkipExport
    )

    if (-not $Readiness) {
        $Readiness = Test-DCDecommissionReadiness -TargetDC $TargetDC
        if (-not $Readiness) { return $null }
        Show-DCDecommissionReadiness -Readiness $Readiness
    }
    if ($Readiness.Blocked) { return $null }

    $target = $Readiness.TargetDC
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    if (-not $Readiness.DhcpInstalled) {
        Write-Host "  [INFO] DHCP Server role not present on '$target' - nothing to clean up." -ForegroundColor Cyan
        return [PSCustomObject]@{ Step = "DHCP Cleanup"; Status = "Skipped"; Timestamp = $ts; Detail = "DHCP role not installed" }
    }

    Write-Host ""
    Write-Host "  This will unauthorize '$target' as a DHCP server in AD and uninstall the DHCP Server feature." -ForegroundColor Yellow
    $confirm = Read-Host "  Proceed? [Y/N]"
    if ($confirm -notmatch "^[Yy]") {
        Write-Host "  [CANCELLED] No changes made." -ForegroundColor Gray
        return [PSCustomObject]@{ Step = "DHCP Cleanup"; Status = "Cancelled"; Timestamp = $ts; Detail = "Operator declined confirmation" }
    }

    try {
        Remove-DhcpServerInDC -DnsName $target -ErrorAction Stop
        Write-Host "  [OK] '$target' unauthorized as DHCP server in AD." -ForegroundColor Green

        if ($Readiness.IsLocal) {
            Uninstall-WindowsFeature -Name DHCP -ErrorAction Stop | Out-Null
        } else {
            Invoke-Command -ComputerName $target -ScriptBlock {
                Uninstall-WindowsFeature -Name DHCP -ErrorAction Stop
            } -ErrorAction Stop | Out-Null
        }
        Write-Host "  [OK] DHCP Server feature uninstalled on '$target'. Action by $env:USERNAME at $ts" -ForegroundColor Green

        $record = [PSCustomObject]@{ Step = "DHCP Cleanup"; Status = "Success"; Timestamp = $ts; Detail = "Unauthorized in AD and feature uninstalled on $target" }
    } catch {
        Write-Host "  [ERROR] DHCP cleanup failed: $_" -ForegroundColor Red
        $record = [PSCustomObject]@{ Step = "DHCP Cleanup"; Status = "Failed"; Timestamp = $ts; Detail = "$_" }
    }

    if (-not $SkipExport) {
        $choice = Read-Host "  Export to HTML report? [Y/N]"
        if ($choice -match "^[Yy]") {
            $path = Export-HTMLReport -Data @{ Steps = @($record) } -ReportType "DCDecommission" -Username $target -Source "LocalAD"
            Write-Host "  [OK] Report saved: $path" -ForegroundColor Green
        }
    }

    return $record
}
```

- [ ] **Step 2: Run the syntax check** (same command as Task 1, Step 2). Expected: `OK: no syntax errors`

- [ ] **Step 3: Commit**

```bash
git add Modules/Invoke-DCDecommission.ps1
git commit -m "feat: add DHCP Cleanup decommission step"
```

---

### Task 3: DNS Cleanup step

**Files:**
- Modify: `Modules/Invoke-DCDecommission.ps1`

- [ ] **Step 1: Append `Invoke-DCDnsCleanup`**

```powershell
function Invoke-DCDnsCleanup {
    param(
        [string]$TargetDC,
        [PSCustomObject]$Readiness,
        [switch]$SkipExport
    )

    if (-not $Readiness) {
        $Readiness = Test-DCDecommissionReadiness -TargetDC $TargetDC
        if (-not $Readiness) { return $null }
        Show-DCDecommissionReadiness -Readiness $Readiness
    }
    if ($Readiness.Blocked) { return $null }

    $target = $Readiness.TargetDC
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    if (-not $Readiness.DnsInstalled) {
        Write-Host "  [INFO] DNS Server role not present on '$target' - nothing to clean up." -ForegroundColor Cyan
        return [PSCustomObject]@{ Step = "DNS Cleanup"; Status = "Skipped"; Timestamp = $ts; Detail = "DNS role not installed" }
    }

    Write-Host ""
    Write-Host "  This will remove DNS records referencing '$target' and uninstall the DNS Server feature." -ForegroundColor Yellow
    $confirm = Read-Host "  Proceed? [Y/N]"
    if ($confirm -notmatch "^[Yy]") {
        Write-Host "  [CANCELLED] No changes made." -ForegroundColor Gray
        return [PSCustomObject]@{ Step = "DNS Cleanup"; Status = "Cancelled"; Timestamp = $ts; Detail = "Operator declined confirmation" }
    }

    try {
        $domain    = (Get-ADDomain -ErrorAction Stop).DNSRoot
        $shortName = ($target -split '\.')[0]

        # Query a surviving DC for DNS records, never the target being decommissioned.
        $surviving = Get-ADDomainController -Filter * -ErrorAction Stop |
            Where-Object { $_.HostName -ne $target } | Select-Object -First 1
        if (-not $surviving) {
            throw "No other domain controller available to query DNS records from."
        }

        $records = Get-DnsServerResourceRecord -ZoneName $domain -ComputerName $surviving.HostName -ErrorAction Stop |
            Where-Object { $_.HostName -eq $shortName }

        foreach ($rec in $records) {
            Remove-DnsServerResourceRecord -ZoneName $domain -ComputerName $surviving.HostName -InputObject $rec -Force -ErrorAction Stop
        }
        Write-Host "  [OK] Removed $($records.Count) DNS record(s) referencing '$target'." -ForegroundColor Green

        if ($Readiness.IsLocal) {
            Uninstall-WindowsFeature -Name DNS -ErrorAction Stop | Out-Null
        } else {
            Invoke-Command -ComputerName $target -ScriptBlock {
                Uninstall-WindowsFeature -Name DNS -ErrorAction Stop
            } -ErrorAction Stop | Out-Null
        }
        Write-Host "  [OK] DNS Server feature uninstalled on '$target'. Action by $env:USERNAME at $ts" -ForegroundColor Green

        $record = [PSCustomObject]@{ Step = "DNS Cleanup"; Status = "Success"; Timestamp = $ts; Detail = "Removed $($records.Count) DNS record(s) and uninstalled feature on $target" }
    } catch {
        Write-Host "  [ERROR] DNS cleanup failed: $_" -ForegroundColor Red
        $record = [PSCustomObject]@{ Step = "DNS Cleanup"; Status = "Failed"; Timestamp = $ts; Detail = "$_" }
    }

    if (-not $SkipExport) {
        $choice = Read-Host "  Export to HTML report? [Y/N]"
        if ($choice -match "^[Yy]") {
            $path = Export-HTMLReport -Data @{ Steps = @($record) } -ReportType "DCDecommission" -Username $target -Source "LocalAD"
            Write-Host "  [OK] Report saved: $path" -ForegroundColor Green
        }
    }

    return $record
}
```

- [ ] **Step 2: Run the syntax check** (same command as Task 1, Step 2). Expected: `OK: no syntax errors`

- [ ] **Step 3: Commit**

```bash
git add Modules/Invoke-DCDecommission.ps1
git commit -m "feat: add DNS Cleanup decommission step"
```

---

### Task 4: Demote step

**Files:**
- Modify: `Modules/Invoke-DCDecommission.ps1`

- [ ] **Step 1: Append `Invoke-DCDemote`**

```powershell
function Invoke-DCDemote {
    param(
        [string]$TargetDC,
        [PSCustomObject]$Readiness,
        [switch]$SkipExport
    )

    if (-not $Readiness) {
        $Readiness = Test-DCDecommissionReadiness -TargetDC $TargetDC
        if (-not $Readiness) { return $null }
        Show-DCDecommissionReadiness -Readiness $Readiness
    }
    if ($Readiness.Blocked) { return $null }

    $target = $Readiness.TargetDC
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    Write-Host ""
    Write-Host "  [WARNING] This will DEMOTE '$target' as a domain controller. This is irreversible without re-promoting." -ForegroundColor Red
    $confirm = Read-Host "  Proceed with demotion? [Y/N]"
    if ($confirm -notmatch "^[Yy]") {
        Write-Host "  [CANCELLED] No changes made." -ForegroundColor Gray
        return [PSCustomObject]@{ Step = "Demote Domain Controller"; Status = "Cancelled"; Timestamp = $ts; Detail = "Operator declined confirmation" }
    }

    $localAdminPwd = Read-Host "  Enter a local Administrator password to set on '$target' after demotion" -AsSecureString

    try {
        if ($Readiness.IsLocal) {
            Uninstall-ADDSDomainController -LocalAdministratorPassword $localAdminPwd -RemoveDnsDelegation -Confirm:$false -ErrorAction Stop | Out-Null
        } else {
            $cred = Get-Credential -Message "Credentials with rights to demote '$target'"
            Invoke-Command -ComputerName $target -Credential $cred -ArgumentList $localAdminPwd -ScriptBlock {
                param($pwd)
                Uninstall-ADDSDomainController -LocalAdministratorPassword $pwd -RemoveDnsDelegation -Confirm:$false -ErrorAction Stop
            } -ErrorAction Stop | Out-Null
        }
        Write-Host "  [OK] '$target' demoted successfully. Action by $env:USERNAME at $ts" -ForegroundColor Green
        $record = [PSCustomObject]@{ Step = "Demote Domain Controller"; Status = "Success"; Timestamp = $ts; Detail = "Demoted $target" }
    } catch {
        Write-Host "  [ERROR] Demotion failed: $_" -ForegroundColor Red
        $record = [PSCustomObject]@{ Step = "Demote Domain Controller"; Status = "Failed"; Timestamp = $ts; Detail = "$_" }
    }

    if (-not $SkipExport) {
        $choice = Read-Host "  Export to HTML report? [Y/N]"
        if ($choice -match "^[Yy]") {
            $path = Export-HTMLReport -Data @{ Steps = @($record) } -ReportType "DCDecommission" -Username $target -Source "LocalAD"
            Write-Host "  [OK] Report saved: $path" -ForegroundColor Green
        }
    }

    return $record
}
```

Note: deliberately **not** passing `-Force` to `Uninstall-ADDSDomainController` — that switch is meant for forcing removal of the *last* DC in a domain, which would also tear down the domain itself. Omitting it means the cmdlet's own built-in safety check still applies on top of our pre-flight check.

- [ ] **Step 2: Run the syntax check** (same command as Task 1, Step 2). Expected: `OK: no syntax errors`

- [ ] **Step 3: Commit**

```bash
git add Modules/Invoke-DCDecommission.ps1
git commit -m "feat: add Demote Domain Controller decommission step"
```

---

### Task 5: AD Metadata Cleanup step

**Files:**
- Modify: `Modules/Invoke-DCDecommission.ps1`

- [ ] **Step 1: Append `Invoke-DCMetadataCleanup`**

```powershell
function Invoke-DCMetadataCleanup {
    param(
        [string]$TargetDC,
        [PSCustomObject]$Readiness,
        [switch]$SkipExport
    )

    if (-not $Readiness) {
        $Readiness = Test-DCDecommissionReadiness -TargetDC $TargetDC
        if (-not $Readiness) { return $null }
        Show-DCDecommissionReadiness -Readiness $Readiness
    }
    # After a successful demotion the target no longer holds FSMO/GC roles, so a
    # Blocked result here most likely means the DC was never actually demoted.
    if ($Readiness.Blocked) { return $null }

    $target    = $Readiness.TargetDC
    $shortName = ($target -split '\.')[0]
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    try {
        $domain = Get-ADDomain -ErrorAction Stop
        $ntdsLeftover = Get-ADObject -Filter "ObjectClass -eq 'nTDSDSA'" `
            -SearchBase "CN=Sites,CN=Configuration,$($domain.DistinguishedName)" -ErrorAction SilentlyContinue |
            Where-Object { $_.DistinguishedName -like "*$shortName*" }
        $serverLeftover = Get-ADObject -Filter "ObjectClass -eq 'server' -and Name -eq '$shortName'" `
            -SearchBase "CN=Sites,CN=Configuration,$($domain.DistinguishedName)" -ErrorAction SilentlyContinue
    } catch {
        Write-Host "  [ERROR] Could not query AD metadata: $_" -ForegroundColor Red
        return [PSCustomObject]@{ Step = "AD Metadata Cleanup"; Status = "Failed"; Timestamp = $ts; Detail = "$_" }
    }

    $leftovers = @($ntdsLeftover) + @($serverLeftover) | Where-Object { $_ }

    if (@($leftovers).Count -eq 0) {
        Write-Host "  [OK] No leftover AD metadata found for '$target' - demotion was clean." -ForegroundColor Green
        return [PSCustomObject]@{ Step = "AD Metadata Cleanup"; Status = "Skipped"; Timestamp = $ts; Detail = "No leftover metadata found" }
    }

    Write-Host ""
    Write-Host "  Found $(@($leftovers).Count) leftover AD object(s) for '$target':" -ForegroundColor Yellow
    $leftovers | ForEach-Object { Write-Host "    - $($_.DistinguishedName)" }
    Write-Host ""
    Write-Host "  [WARNING] Removing these objects directly modifies AD outside the normal demotion path." -ForegroundColor Red
    $confirm = Read-Host "  Type the DC name ('$target') to confirm removal"
    if ($confirm -ne $target) {
        Write-Host "  [CANCELLED] Confirmation did not match. No changes made." -ForegroundColor Gray
        return [PSCustomObject]@{ Step = "AD Metadata Cleanup"; Status = "Cancelled"; Timestamp = $ts; Detail = "Confirmation did not match" }
    }

    try {
        foreach ($obj in $leftovers) {
            Remove-ADObject -Identity $obj.DistinguishedName -Recursive -Confirm:$false -ErrorAction Stop
        }
        Write-Host "  [OK] Removed $(@($leftovers).Count) leftover AD object(s). Action by $env:USERNAME at $ts" -ForegroundColor Green
        $record = [PSCustomObject]@{ Step = "AD Metadata Cleanup"; Status = "Success"; Timestamp = $ts; Detail = "Removed $(@($leftovers).Count) leftover object(s)" }
    } catch {
        Write-Host "  [ERROR] Metadata cleanup failed: $_" -ForegroundColor Red
        $record = [PSCustomObject]@{ Step = "AD Metadata Cleanup"; Status = "Failed"; Timestamp = $ts; Detail = "$_" }
    }

    if (-not $SkipExport) {
        $choice = Read-Host "  Export to HTML report? [Y/N]"
        if ($choice -match "^[Yy]") {
            $path = Export-HTMLReport -Data @{ Steps = @($record) } -ReportType "DCDecommission" -Username $target -Source "LocalAD"
            Write-Host "  [OK] Report saved: $path" -ForegroundColor Green
        }
    }

    return $record
}
```

- [ ] **Step 2: Run the syntax check** (same command as Task 1, Step 2). Expected: `OK: no syntax errors`

- [ ] **Step 3: Commit**

```bash
git add Modules/Invoke-DCDecommission.ps1
git commit -m "feat: add AD Metadata Cleanup decommission step"
```

---

### Task 6: Verify step

**Files:**
- Modify: `Modules/Invoke-DCDecommission.ps1`

- [ ] **Step 1: Append `Invoke-DCDecommissionVerify`**

```powershell
function Invoke-DCDecommissionVerify {
    param(
        [string]$TargetDC,
        [switch]$SkipExport
    )

    if ([string]::IsNullOrWhiteSpace($TargetDC)) {
        $TargetDC = Read-Host "`nEnter the domain controller name to verify decommission for"
    }
    if ([string]::IsNullOrWhiteSpace($TargetDC)) {
        Write-Host "[ERROR] No target DC provided." -ForegroundColor Red
        return $null
    }

    $ts        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $shortName = ($TargetDC -split '\.')[0]
    $checks    = @()

    try {
        $stillListed = Get-ADDomainController -Filter * -ErrorAction Stop | Where-Object {
            $_.HostName -eq $TargetDC -or $_.Name -eq $shortName
        }
        $checks += [PSCustomObject]@{ Check = "Removed from AD domain controller list"; Pass = (@($stillListed).Count -eq 0) }
    } catch {
        $checks += [PSCustomObject]@{ Check = "Removed from AD domain controller list"; Pass = $false }
    }

    try {
        $domain  = Get-ADDomain -ErrorAction Stop
        $records = Get-DnsServerResourceRecord -ZoneName $domain.DNSRoot -ErrorAction Stop |
            Where-Object { $_.HostName -eq $shortName }
        $checks += [PSCustomObject]@{ Check = "No lingering DNS records"; Pass = (@($records).Count -eq 0) }
    } catch {
        $checks += [PSCustomObject]@{ Check = "No lingering DNS records (could not query DNS)"; Pass = $false }
    }

    try {
        $domain         = Get-ADDomain -ErrorAction Stop
        $serverLeftover = Get-ADObject -Filter "ObjectClass -eq 'server' -and Name -eq '$shortName'" `
            -SearchBase "CN=Sites,CN=Configuration,$($domain.DistinguishedName)" -ErrorAction SilentlyContinue
        $checks += [PSCustomObject]@{ Check = "No lingering Sites & Services objects"; Pass = (@($serverLeftover).Count -eq 0) }
    } catch {
        $checks += [PSCustomObject]@{ Check = "No lingering Sites & Services objects"; Pass = $false }
    }

    Write-Host ""
    Write-Host "  DECOMMISSION VERIFICATION - $TargetDC" -ForegroundColor Cyan
    Write-Host ("-" * 60) -ForegroundColor DarkGray
    foreach ($c in $checks) {
        $status = if ($c.Pass) { "[PASS]" } else { "[FAIL]" }
        $color  = if ($c.Pass) { "Green" } else { "Red" }
        Write-Host ("  {0,-8} {1}" -f $status, $c.Check) -ForegroundColor $color
    }
    Write-Host ""

    $overall = if (@($checks | Where-Object { -not $_.Pass }).Count -eq 0) { "Success" } else { "Failed" }
    $detail  = ($checks | ForEach-Object { "$($_.Check): $(if ($_.Pass) { 'PASS' } else { 'FAIL' })" }) -join "; "
    $record  = [PSCustomObject]@{ Step = "Verify Decommission"; Status = $overall; Timestamp = $ts; Detail = $detail }

    if (-not $SkipExport) {
        $choice = Read-Host "  Export to HTML report? [Y/N]"
        if ($choice -match "^[Yy]") {
            $path = Export-HTMLReport -Data @{ Steps = @($record) } -ReportType "DCDecommission" -Username $TargetDC -Source "LocalAD"
            Write-Host "  [OK] Report saved: $path" -ForegroundColor Green
        }
    }

    return $record
}
```

- [ ] **Step 2: Run the syntax check** (same command as Task 1, Step 2). Expected: `OK: no syntax errors`

- [ ] **Step 3: Commit**

```bash
git add Modules/Invoke-DCDecommission.ps1
git commit -m "feat: add Verify Decommission step"
```

---

### Task 7: Wizard sub-menu and Full Decommission orchestrator

**Files:**
- Modify: `Modules/Invoke-DCDecommission.ps1`

- [ ] **Step 1: Append `Invoke-DCFullDecommission` and `Invoke-DCDecommissionWizard`**

```powershell
function Invoke-DCFullDecommission {
    $target = Read-Host "`nEnter the target domain controller (FQDN or hostname) to fully decommission"
    if ([string]::IsNullOrWhiteSpace($target)) {
        Write-Host "[ERROR] No target DC provided." -ForegroundColor Red
        return
    }

    $readiness = Test-DCDecommissionReadiness -TargetDC $target
    if (-not $readiness) { return }
    Show-DCDecommissionReadiness -Readiness $readiness
    if ($readiness.Blocked) { return }

    Write-Host "  This will run DHCP Cleanup, DNS Cleanup, Demote, AD Metadata Cleanup, and Verify" -ForegroundColor Yellow
    Write-Host "  against '$target', confirming before each step. It stops immediately if any step fails." -ForegroundColor Yellow

    $steps = @(
        @{ Name = "DHCP Cleanup";             Fn = { Invoke-DCDhcpCleanup       -TargetDC $target -Readiness $readiness -SkipExport } },
        @{ Name = "DNS Cleanup";              Fn = { Invoke-DCDnsCleanup        -TargetDC $target -Readiness $readiness -SkipExport } },
        @{ Name = "Demote Domain Controller"; Fn = { Invoke-DCDemote            -TargetDC $target -Readiness $readiness -SkipExport } },
        @{ Name = "AD Metadata Cleanup";      Fn = { Invoke-DCMetadataCleanup   -TargetDC $target -Readiness $readiness -SkipExport } },
        @{ Name = "Verify Decommission";      Fn = { Invoke-DCDecommissionVerify -TargetDC $target -SkipExport } }
    )

    $records = @()
    foreach ($step in $steps) {
        Write-Host ""
        Write-Host "  -- $($step.Name) --" -ForegroundColor Cyan
        $proceed = Read-Host "  Run this step now? [Y/N]"
        if ($proceed -notmatch "^[Yy]") {
            Write-Host "  [SKIPPED] $($step.Name) was skipped by operator." -ForegroundColor Gray
            $records += [PSCustomObject]@{ Step = $step.Name; Status = "Skipped"; Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); Detail = "Skipped by operator before running" }
            continue
        }

        $result = & $step.Fn
        if ($result) { $records += $result }

        if ($result -and $result.Status -eq "Failed") {
            Write-Host ""
            Write-Host "  [STOPPED] Full Decommission halted after '$($step.Name)' failed." -ForegroundColor Red
            break
        }
    }

    Write-Host ""
    Write-Host "  FULL DECOMMISSION SUMMARY - $target" -ForegroundColor Cyan
    Write-Host ("-" * 60) -ForegroundColor DarkGray
    foreach ($r in $records) {
        $color = switch ($r.Status) { "Success" { "Green" } "Failed" { "Red" } default { "Yellow" } }
        Write-Host ("  {0,-25} {1}" -f $r.Step, $r.Status) -ForegroundColor $color
    }
    Write-Host ""

    $choice = Read-Host "  Export combined HTML report? [Y/N]"
    if ($choice -match "^[Yy]") {
        $path = Export-HTMLReport -Data @{ Steps = $records } -ReportType "DCDecommission" -Username $target -Source "LocalAD"
        Write-Host "  [OK] Report saved: $path" -ForegroundColor Green
    }
}

function Invoke-DCDecommissionWizard {
    $running = $true
    while ($running) {
        Write-Host ""
        Write-Host "  ------------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "  DECOMMISSION WIZARD" -ForegroundColor White
        Write-Host "  ------------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "    [1]  DHCP Cleanup"
        Write-Host "    [2]  DNS Cleanup"
        Write-Host "    [3]  Demote Domain Controller"
        Write-Host "    [4]  AD Metadata Cleanup"
        Write-Host "    [5]  Verify Decommission"
        Write-Host "    [6]  Full Decommission (runs 1-5 in order)"
        Write-Host "    [0]  Back to main menu"
        Write-Host ""
        $choice = Read-Host "  Select step"

        switch ($choice.Trim()) {
            "1" { Invoke-DCDhcpCleanup         | Out-Null }
            "2" { Invoke-DCDnsCleanup          | Out-Null }
            "3" { Invoke-DCDemote              | Out-Null }
            "4" { Invoke-DCMetadataCleanup     | Out-Null }
            "5" { Invoke-DCDecommissionVerify  | Out-Null }
            "6" { Invoke-DCFullDecommission }
            "0" { $running = $false }
            default { Write-Host "  [ERROR] Invalid option. Enter 0-6." -ForegroundColor Red }
        }
    }
}
```

- [ ] **Step 2: Run the syntax check** (same command as Task 1, Step 2). Expected: `OK: no syntax errors`

- [ ] **Step 3: Commit**

```bash
git add Modules/Invoke-DCDecommission.ps1
git commit -m "feat: add Decommission Wizard sub-menu and Full Decommission orchestrator"
```

---

### Task 8: HTML report builder

**Files:**
- Modify: `Modules/Export-HTML.ps1:10-13` (ValidateSet)
- Modify: `Modules/Export-HTML.ps1` (switch in `Export-HTMLReport`, end of file for new builder)

- [ ] **Step 1: Add `"DCDecommission"` to the `ValidateSet`**

In `Modules/Export-HTML.ps1`, change:

```powershell
        [ValidateSet("SearchResult","Comparison","GPOReport","HealthCheck",
                     "StaleAccounts","PasswordExpiry","ComputerSearch",
                     "GroupInfo","GroupComparison","PrivilegedAccess","RadiusAudit",
                     "AccountTroubleshoot")]
```

to:

```powershell
        [ValidateSet("SearchResult","Comparison","GPOReport","HealthCheck",
                     "StaleAccounts","PasswordExpiry","ComputerSearch",
                     "GroupInfo","GroupComparison","PrivilegedAccess","RadiusAudit",
                     "AccountTroubleshoot","DCDecommission")]
```

- [ ] **Step 2: Add the dispatch case**

In the `$body = switch ($ReportType) { ... }` block, change:

```powershell
        "AccountTroubleshoot" { Build-TroubleshootHTML -Data $Data }
    }
```

to:

```powershell
        "AccountTroubleshoot" { Build-TroubleshootHTML -Data $Data }
        "DCDecommission"      { Build-DCDecommissionHTML -Data $Data }
    }
```

- [ ] **Step 3: Append `Build-DCDecommissionHTML` at the end of the file**

```powershell
function Build-DCDecommissionHTML {
    param([hashtable]$Data)
    $html = "<h2>Domain Controller Decommission Report</h2>"
    $html += "<table><thead><tr><th>Step</th><th>Status</th><th>Timestamp</th><th>Detail</th></tr></thead><tbody>"
    foreach ($s in $Data.Steps) {
        $css = switch ($s.Status) {
            "Failed"    { "danger" }
            "Skipped"   { "warn" }
            "Cancelled" { "warn" }
            default     { "" }
        }
        $badgeClass = switch ($s.Status) {
            "Success" { "badge-ok" }
            "Failed"  { "badge-fail" }
            default   { "badge-warn" }
        }
        $html += "<tr class='$css'><td>$(HE $s.Step)</td>" +
                 "<td><span class='badge $badgeClass'>$(HE $s.Status)</span></td>" +
                 "<td>$(HE $s.Timestamp)</td><td>$(HE $s.Detail)</td></tr>`n"
    }
    $html += "</tbody></table>"
    return $html
}
```

- [ ] **Step 4: Run the syntax check**

Run:
```bash
pwsh -NoProfile -Command '
$errors = $null; $tokens = $null
[System.Management.Automation.Language.Parser]::ParseFile("Modules/Export-HTML.ps1", [ref]$tokens, [ref]$errors)
if ($errors.Count -eq 0) { Write-Host "OK: no syntax errors" } else { $errors | ForEach-Object { Write-Host $_.Message } }
'
```
Expected: `OK: no syntax errors`

- [ ] **Step 5: Commit**

```bash
git add Modules/Export-HTML.ps1
git commit -m "feat: add DCDecommission HTML report builder"
```

---

### Task 9: Wire into ADCommander.ps1

**Files:**
- Modify: `ADCommander.ps1`

- [ ] **Step 1: Dot-source the new module**

Change:

```powershell
. (Join-Path $modulePath "Get-RadiusInfo.ps1")
```

to:

```powershell
. (Join-Path $modulePath "Get-RadiusInfo.ps1")
. (Join-Path $modulePath "Invoke-DCDecommission.ps1")
```

- [ ] **Step 2: Add the new menu section and renumber `Change Source`/`Exit`**

Change:

```powershell
    Write-Host "  -- AUTHENTICATION INFRASTRUCTURE --" -ForegroundColor DarkCyan
    Write-Host "    [14]  RADIUS / NPS Audit" -NoNewline
    if (-not $isLocal) { Write-Host "  (Local AD only)" -ForegroundColor DarkGray } else { Write-Host "" }
    Write-Host ""
    Write-Host "  -- SYSTEM --" -ForegroundColor DarkCyan
    Write-Host "    [15]  Change Source"
    Write-Host "    [16]  Exit"
    Write-Host ""
```

to:

```powershell
    Write-Host "  -- AUTHENTICATION INFRASTRUCTURE --" -ForegroundColor DarkCyan
    Write-Host "    [14]  RADIUS / NPS Audit" -NoNewline
    if (-not $isLocal) { Write-Host "  (Local AD only)" -ForegroundColor DarkGray } else { Write-Host "" }
    Write-Host ""
    Write-Host "  -- DC DECOMMISSIONING --" -ForegroundColor DarkCyan
    Write-Host "    [15]  Decommission Wizard" -NoNewline
    if (-not $isLocal) { Write-Host "  (Local AD only)" -ForegroundColor DarkGray } else { Write-Host "" }
    Write-Host ""
    Write-Host "  -- SYSTEM --" -ForegroundColor DarkCyan
    Write-Host "    [16]  Change Source"
    Write-Host "    [17]  Exit"
    Write-Host ""
```

- [ ] **Step 3: Update the `switch` block**

Change:

```powershell
        "14" { if (Assert-LocalAD) { Invoke-RadiusAudit } }
        "15" {
            Show-Banner
            Install-ADCommanderRequirements
            $connected = $false
            while (-not $connected) {
                $connected = Select-Source
                if (-not $connected) {
                    Write-Host "  Connection failed. Try again." -ForegroundColor Yellow
                    Write-Host ""
                }
            }
        }
        "16" {
            Write-Host "`n  Goodbye.`n" -ForegroundColor Cyan
            $running = $false
        }
        default { Write-Host "  [ERROR] Invalid option. Enter 1-16." -ForegroundColor Red }
```

to:

```powershell
        "14" { if (Assert-LocalAD) { Invoke-RadiusAudit } }
        "15" { if (Assert-LocalAD) { Invoke-DCDecommissionWizard } }
        "16" {
            Show-Banner
            Install-ADCommanderRequirements
            $connected = $false
            while (-not $connected) {
                $connected = Select-Source
                if (-not $connected) {
                    Write-Host "  Connection failed. Try again." -ForegroundColor Yellow
                    Write-Host ""
                }
            }
        }
        "17" {
            Write-Host "`n  Goodbye.`n" -ForegroundColor Cyan
            $running = $false
        }
        default { Write-Host "  [ERROR] Invalid option. Enter 1-17." -ForegroundColor Red }
```

- [ ] **Step 4: Run the syntax check**

Run:
```bash
pwsh -NoProfile -Command '
$errors = $null; $tokens = $null
[System.Management.Automation.Language.Parser]::ParseFile("ADCommander.ps1", [ref]$tokens, [ref]$errors)
if ($errors.Count -eq 0) { Write-Host "OK: no syntax errors" } else { $errors | ForEach-Object { Write-Host $_.Message } }
'
```
Expected: `OK: no syntax errors`

- [ ] **Step 5: Commit**

```bash
git add ADCommander.ps1
git commit -m "feat: wire Decommission Wizard into main menu"
```

---

### Task 10: README changelog and final review

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a changelog entry**

In the Changelog table at the bottom of `README.md`, after the `1.3` row, add:

```markdown
| 1.4 | 2026-06-22 | Added Decommission Wizard (option 15): DHCP/DNS cleanup, demote, AD metadata cleanup, verify, and full-decommission orchestration |
```

- [ ] **Step 2: Confirm the File Structure block already lists the new module**

Check that `## File Structure` in `README.md` includes:

```
│   └── Invoke-DCDecommission.ps1    # DC decommission: DHCP/DNS cleanup, demote, AD metadata cleanup, verify
```

(This line and the Features table rows / safety note were already added in commit `63c57a9` on this branch — no action needed if present; add them if missing.)

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: changelog entry for Decommission Wizard"
```

---

## Manual verification (not automated, do after all tasks complete)

This cannot be exercised without a real lab AD domain. After implementation:

1. Run `Invoke-DCDecommissionWizard` against a **non-FSMO, non-last-GC** lab DC that has DHCP and DNS roles installed.
2. Confirm the pre-flight check correctly blocks when pointed at a DC that *does* hold a FSMO role or is the only GC in its site.
3. Run each step individually (option 1-5) against the same target, confirming each prompts and logs correctly.
4. Run "Full Decommission" (option 6) end-to-end, confirming it stops on a simulated failure (e.g., temporarily blocking WinRM mid-run) and reports the partial summary correctly.
5. Confirm the HTML export opens cleanly and matches the existing report style.
