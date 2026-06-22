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
