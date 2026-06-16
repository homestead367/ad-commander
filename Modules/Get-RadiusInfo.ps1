# Modules/Get-RadiusInfo.ps1
# Written by Dallas Milem

function Invoke-RadiusAudit {
    Write-Host "`nRADIUS / NPS (Network Policy Server) Audit" -ForegroundColor Cyan
    Write-Host "  [A]  Scan all servers in AD"
    Write-Host "  [S]  Scan a specific server"
    $scope = Read-Host "`nChoice (default A)"

    $targets = @()
    if ($scope -match "^[Ss]") {
        $name = Read-Host "Server name or hostname"
        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Host "[ERROR] No server name provided." -ForegroundColor Red
            return
        }
        $targets = @($name)
    } else {
        try {
            $servers = Get-ADComputer -Filter { OperatingSystem -like "*Server*" -and Enabled -eq $true } `
                -Properties OperatingSystem, DNSHostName
            $targets = $servers | ForEach-Object { if ($_.DNSHostName) { $_.DNSHostName } else { $_.Name } }
        } catch {
            Write-Host "[WARN] Could not enumerate servers from AD: $_" -ForegroundColor Yellow
            return
        }
    }

    if ($targets.Count -eq 0) {
        Write-Host "[INFO] No servers found to scan." -ForegroundColor Yellow
        return
    }

    Write-Host "`nQuerying $($targets.Count) server(s) for NPS / RADIUS configuration..." -ForegroundColor Cyan

    $scriptBlock = {
        $result = [PSCustomObject]@{
            NPSInstalled  = $false
            ServiceStatus = "N/A"
            RadiusClients = @()
        }

        $feature = Get-WindowsFeature -Name NPAS -ErrorAction SilentlyContinue
        if ($feature -and $feature.InstallState -eq 'Installed') {
            $result.NPSInstalled = $true
        }

        $svc = Get-Service -Name IAS -ErrorAction SilentlyContinue
        if ($svc) { $result.ServiceStatus = $svc.Status.ToString() }

        if ($result.NPSInstalled) {
            $clientsPath = 'HKLM:\SOFTWARE\Microsoft\AAAServer\Parameters\Clients'
            if (Test-Path $clientsPath) {
                Get-ChildItem $clientsPath -ErrorAction SilentlyContinue | ForEach-Object {
                    $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                    $result.RadiusClients += [PSCustomObject]@{
                        Name    = $_.PSChildName
                        Address = $props.Address
                    }
                }
            }
        }

        $result
    }

    $findings = @()
    $skipped  = 0
    foreach ($target in $targets) {
        # Skip servers that don't resolve in DNS — avoids flooding output with
        # WinRM "name cannot be resolved" errors for stale or offline AD records
        try {
            [System.Net.Dns]::GetHostAddresses($target) | Out-Null
        } catch {
            $skipped++
            continue
        }

        try {
            $r = Invoke-Command -ComputerName $target -ScriptBlock $scriptBlock -ErrorAction Stop
            $findings += [PSCustomObject]@{
                Server        = $target
                Reachable     = $true
                NPSInstalled  = $r.NPSInstalled
                ServiceStatus = $r.ServiceStatus
                RadiusClients = $r.RadiusClients
                Error         = $null
            }
        } catch {
            $findings += [PSCustomObject]@{
                Server        = $target
                Reachable     = $false
                NPSInstalled  = $false
                ServiceStatus = "N/A"
                RadiusClients = @()
                Error         = $_.Exception.Message
            }
        }
    }
    if ($skipped -gt 0) {
        Write-Host "  [INFO] Skipped $skipped server(s) with no DNS record (stale or offline AD entries)." -ForegroundColor DarkGray
    }

    Show-RadiusTable -Findings $findings

    $exportData = @{ Findings = $findings }
    $choice = Read-Host "Export to HTML report? [Y/N]"
    if ($choice -match "^[Yy]") {
        $path = Export-HTMLReport -Data $exportData -ReportType "RadiusAudit" -Username "RadiusAudit" -Source (Get-ADSource)
        Write-Host "[OK] Report saved: $path" -ForegroundColor Green
    }
}

function Show-RadiusTable {
    param($Findings)
    $line = "=" * 70
    $npsServers = $Findings | Where-Object { $_.NPSInstalled }

    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host " RADIUS / NPS AUDIT" -ForegroundColor White
    Write-Host $line -ForegroundColor DarkCyan

    Write-Host "`n  SERVERS WITH NPS (RADIUS) ROLE INSTALLED ($($npsServers.Count))" -ForegroundColor Yellow
    Write-Host ("-" * 70) -ForegroundColor DarkGray
    if ($npsServers.Count -eq 0) {
        Write-Host "  (none found - no RADIUS/NPS servers detected)" -ForegroundColor Gray
    } else {
        foreach ($f in $npsServers) {
            Write-Host ("  {0,-30} Service: {1,-10} RADIUS Clients: {2}" -f $f.Server, $f.ServiceStatus, $f.RadiusClients.Count) -ForegroundColor Green
            foreach ($c in $f.RadiusClients) {
                Write-Host ("      - {0,-25} {1}" -f $c.Name, $c.Address) -ForegroundColor Gray
            }
            Write-Host "      AD-Integrated: Yes (server is domain-joined; NPS authenticates against this AD domain)" -ForegroundColor Gray
        }
    }

    $unreachable = $Findings | Where-Object { -not $_.Reachable }
    if ($unreachable.Count -gt 0) {
        Write-Host "`n  UNREACHABLE SERVERS ($($unreachable.Count))" -ForegroundColor Red
        Write-Host ("-" * 70) -ForegroundColor DarkGray
        foreach ($f in $unreachable) {
            Write-Host ("  {0,-30} {1}" -f $f.Server, $f.Error) -ForegroundColor DarkGray
        }
    }

    Write-Host "`n$line`n" -ForegroundColor DarkCyan
}
