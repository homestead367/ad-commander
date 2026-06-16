# Modules/Get-StaleAccounts.ps1
# Written by Dallas Milem

function Invoke-StaleAccountReport {
    $thresholdInput = Read-Host "`nInactivity threshold in days (default 90)"
    $days = if ([string]::IsNullOrWhiteSpace($thresholdInput)) { 90 } else { [int]$thresholdInput }
    $cutoff = (Get-Date).AddDays(-$days)

    Write-Host "`nQuerying stale accounts (threshold: $days days)..." -ForegroundColor Cyan

    # -- Inactive users --------------------------------------------------------
    $inactiveUsers = @()
    try {
        $users = Get-ADUser -Filter { Enabled -eq $true -and LastLogonDate -lt $cutoff } `
            -Properties DisplayName, SamAccountName, LastLogonDate, DistinguishedName |
            Where-Object { $_.LastLogonDate -ne $null }

        $inactiveUsers = $users | ForEach-Object {
            [PSCustomObject]@{
                Name     = $_.DisplayName
                SAM      = $_.SamAccountName
                LastLogon = $_.LastLogonDate.ToString("yyyy-MM-dd")
                OU       = ($_.DistinguishedName -replace '^CN=[^,]+,','')
            }
        } | Sort-Object LastLogon
    } catch { Write-Host "[WARN] Could not query inactive users: $_" -ForegroundColor Yellow }

    # -- Inactive computers ----------------------------------------------------
    $inactiveComputers = @()
    try {
        $computers = Get-ADComputer -Filter { Enabled -eq $true -and LastLogonDate -lt $cutoff } `
            -Properties Name, OperatingSystem, LastLogonDate, DistinguishedName |
            Where-Object { $_.LastLogonDate -ne $null }

        $inactiveComputers = $computers | ForEach-Object {
            [PSCustomObject]@{
                Name      = $_.Name
                OS        = $_.OperatingSystem
                LastLogon = $_.LastLogonDate.ToString("yyyy-MM-dd")
                OU        = ($_.DistinguishedName -replace '^CN=[^,]+,','')
            }
        } | Sort-Object LastLogon
    } catch { Write-Host "[WARN] Could not query inactive computers: $_" -ForegroundColor Yellow }

    # -- Disabled accounts with group memberships ------------------------------
    $disabledWithGroups = @()
    try {
        $disabled = Get-ADUser -Filter { Enabled -eq $false } `
            -Properties DisplayName, SamAccountName, MemberOf |
            Where-Object { $_.MemberOf.Count -gt 0 }

        $disabledWithGroups = $disabled | ForEach-Object {
            $groups = $_.MemberOf | ForEach-Object {
                try { (Get-ADGroup $_).Name } catch { $_ }
            }
            [PSCustomObject]@{
                Name   = $_.DisplayName
                SAM    = $_.SamAccountName
                Groups = $groups -join ", "
            }
        } | Sort-Object Name
    } catch { Write-Host "[WARN] Could not query disabled accounts: $_" -ForegroundColor Yellow }

    Show-StaleTable -InactiveUsers $inactiveUsers -InactiveComputers $inactiveComputers -Disabled $disabledWithGroups -Days $days

    $exportData = @{
        ThresholdDays      = $days
        InactiveUsers      = $inactiveUsers
        InactiveComputers  = $inactiveComputers
        DisabledWithGroups = $disabledWithGroups
    }
    $choice = Read-Host "Export to HTML report? [Y/N]"
    if ($choice -match "^[Yy]") {
        $path = Export-HTMLReport -Data $exportData -ReportType "StaleAccounts" -Username "StaleReport" -Source "LocalAD"
        Write-Host "[OK] Report saved: $path" -ForegroundColor Green
    }
}

function Show-StaleTable {
    param($InactiveUsers, $InactiveComputers, $Disabled, [int]$Days)
    $line = "=" * 70
    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host " STALE ACCOUNT REPORT  -  Threshold: $Days days" -ForegroundColor White
    Write-Host $line -ForegroundColor DarkCyan

    Write-Host "`n  INACTIVE USERS ($($InactiveUsers.Count))" -ForegroundColor Yellow
    Write-Host ("-" * 70) -ForegroundColor DarkGray
    if ($InactiveUsers.Count -eq 0) { Write-Host "  (none)" -ForegroundColor Gray }
    else {
        Write-Host ("  {0,-30} {1,-20} {2}" -f "Name", "SAM", "Last Logon") -ForegroundColor Gray
        foreach ($u in $InactiveUsers) {
            Write-Host ("  {0,-30} {1,-20} {2}" -f $u.Name, $u.SAM, $u.LastLogon)
        }
    }

    Write-Host "`n  INACTIVE COMPUTERS ($($InactiveComputers.Count))" -ForegroundColor Yellow
    Write-Host ("-" * 70) -ForegroundColor DarkGray
    if ($InactiveComputers.Count -eq 0) { Write-Host "  (none)" -ForegroundColor Gray }
    else {
        Write-Host ("  {0,-25} {1,-30} {2}" -f "Name", "OS", "Last Logon") -ForegroundColor Gray
        foreach ($c in $InactiveComputers) {
            Write-Host ("  {0,-25} {1,-30} {2}" -f $c.Name, $c.OS, $c.LastLogon)
        }
    }

    Write-Host "`n  DISABLED ACCOUNTS WITH GROUP MEMBERSHIPS ($($Disabled.Count))" -ForegroundColor Red
    Write-Host ("-" * 70) -ForegroundColor DarkGray
    if ($Disabled.Count -eq 0) { Write-Host "  (none)" -ForegroundColor Gray }
    else {
        foreach ($u in $Disabled) {
            Write-Host ("  {0,-30} {1}" -f $u.SAM, $u.Groups) -ForegroundColor Yellow
        }
    }

    Write-Host "`n$line`n" -ForegroundColor DarkCyan
}
