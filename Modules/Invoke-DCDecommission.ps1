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
        GCSiteCheckFailed       = $false
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
        $siteGCs = $null
        try {
            $allDCs  = Get-ADDomainController -Filter * -ErrorAction Stop
            $siteGCs = $allDCs | Where-Object { $_.Site -eq $dc.Site -and $_.IsGlobalCatalog }
        } catch {
            $result.GCSiteCheckFailed = $true
        }
        if (-not $result.GCSiteCheckFailed) {
            $otherGCs = $siteGCs | Where-Object { $_.Name -ne $dc.Name }
            if (@($otherGCs).Count -eq 0) {
                $result.Blocked = $true
                $result.BlockReasons += "Is the only Global Catalog in site '$($dc.Site)'. Promote another DC in that site to GC first."
            }
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

    if ($Readiness.GCSiteCheckFailed) {
        Write-Host "  [WARNING] Could not verify Global Catalog uniqueness for this DC's site. Check manually before proceeding." -ForegroundColor Yellow
        Write-Host ""
    }

    if ($Readiness.Blocked) {
        Write-Host "  [BLOCKED] This DC cannot be decommissioned yet:" -ForegroundColor Red
        foreach ($reason in $Readiness.BlockReasons) {
            Write-Host "    - $reason" -ForegroundColor Red
        }
        Write-Host ""
    }
}

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
            $uninstallResult = Uninstall-WindowsFeature -Name DHCP -ErrorAction Stop
        } else {
            $uninstallResult = Invoke-Command -ComputerName $target -ScriptBlock {
                Uninstall-WindowsFeature -Name DHCP -ErrorAction Stop
            } -ErrorAction Stop
        }

        if (-not $uninstallResult.Success) {
            throw "DHCP Server feature removal reported failure on '$target'."
        }

        $restartNote = if ($uninstallResult.RestartNeeded -eq "Yes") { " A restart is required to complete removal." } else { "" }
        Write-Host "  [OK] DHCP Server feature uninstalled on '$target'.$restartNote Action by $env:USERNAME at $ts" -ForegroundColor Green

        $record = [PSCustomObject]@{ Step = "DHCP Cleanup"; Status = "Success"; Timestamp = $ts; Detail = "Unauthorized in AD and feature uninstalled on $target.$restartNote" }
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

        $surviving = Get-ADDomainController -Filter * -ErrorAction Stop | Where-Object {
            $candidateShort = ($_.HostName -split '\.')[0]
            $candidateShort -notlike $shortName -and $_.HostName -notlike $target
        } | Select-Object -First 1
        if (-not $surviving) {
            throw "No other domain controller available to query DNS records from."
        }

        $records = Get-DnsServerResourceRecord -ZoneName $domain -ComputerName $surviving.HostName -ErrorAction Stop |
            Where-Object { $_.HostName -eq $shortName -and $_.RecordType -in @("A","AAAA") }

        foreach ($rec in $records) {
            Remove-DnsServerResourceRecord -ZoneName $domain -ComputerName $surviving.HostName -InputObject $rec -Force -ErrorAction Stop
        }
        Write-Host "  [OK] Removed $($records.Count) DNS record(s) referencing '$target'." -ForegroundColor Green

        if ($Readiness.IsLocal) {
            $uninstallResult = Uninstall-WindowsFeature -Name DNS -ErrorAction Stop
        } else {
            $uninstallResult = Invoke-Command -ComputerName $target -ScriptBlock {
                Uninstall-WindowsFeature -Name DNS -ErrorAction Stop
            } -ErrorAction Stop
        }

        if (-not $uninstallResult.Success) {
            throw "DNS Server feature removal reported failure on '$target'."
        }

        $restartNote = if ($uninstallResult.RestartNeeded -eq "Yes") { " A restart is required to complete removal." } else { "" }
        Write-Host "  [OK] DNS Server feature uninstalled on '$target'.$restartNote Action by $env:USERNAME at $ts" -ForegroundColor Green

        $record = [PSCustomObject]@{ Step = "DNS Cleanup"; Status = "Success"; Timestamp = $ts; Detail = "Removed $($records.Count) DNS record(s) and uninstalled feature on $target.$restartNote" }
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

    Import-Module ADDSDeployment -ErrorAction SilentlyContinue

    try {
        try {
            $demoteParams = @{
                LocalAdministratorPassword = $localAdminPwd
                Confirm                    = $false
                ErrorAction                = "Stop"
            }
            if ($Readiness.DnsInstalled) {
                $demoteParams["RemoveDnsDelegation"] = $true
            }

            if ($Readiness.IsLocal) {
                $demoteResult = Uninstall-ADDSDomainController @demoteParams
            } else {
                $cred = Get-Credential -Message "Credentials with rights to demote '$target'"
                if (-not $cred) {
                    Write-Host "  [CANCELLED] No changes made." -ForegroundColor Gray
                    return [PSCustomObject]@{ Step = "Demote Domain Controller"; Status = "Cancelled"; Timestamp = $ts; Detail = "Operator cancelled credential prompt" }
                }
                # NOTE: a SecureString can be passed across this single Invoke-Command hop, but if
                # Uninstall-ADDSDomainController itself needs to reach other DCs using the operator's
                # credentials (double-hop), CredSSP or similar delegation may be required - this is a
                # known PowerShell remoting limitation, not a bug in this script.
                $demoteResult = Invoke-Command -ComputerName $target -Credential $cred -ArgumentList $demoteParams -ScriptBlock {
                    param($demoteParams)
                    Uninstall-ADDSDomainController @demoteParams
                } -ErrorAction Stop
            }

            $rebootNote = " A reboot will occur automatically to finish removing AD DS."
            Write-Host "  [OK] '$target' demoted successfully.$rebootNote Action by $env:USERNAME at $ts" -ForegroundColor Green
            $record = [PSCustomObject]@{ Step = "Demote Domain Controller"; Status = "Success"; Timestamp = $ts; Detail = "Demoted $target.$rebootNote" }
        } catch {
            Write-Host "  [ERROR] Demotion failed: $_" -ForegroundColor Red
            $record = [PSCustomObject]@{ Step = "Demote Domain Controller"; Status = "Failed"; Timestamp = $ts; Detail = "$_" }
        }
    } finally {
        if ($localAdminPwd) { $localAdminPwd.Dispose() }
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
