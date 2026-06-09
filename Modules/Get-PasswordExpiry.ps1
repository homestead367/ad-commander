# Modules/Get-PasswordExpiry.ps1
# Written by Dallas Milem

function Invoke-PasswordExpiryReport {
    $windowInput = Read-Host "`nLook-ahead window in days (default 14)"
    $days = if ([string]::IsNullOrWhiteSpace($windowInput)) { 14 } else { [int]$windowInput }

    Write-Host "`nQuerying password expiry data..." -ForegroundColor Cyan

    $expiringSoon   = @()
    $alreadyExpired = @()
    $neverExpires   = @()

    try {
        $maxAge = (Get-ADDefaultDomainPasswordPolicy).MaxPasswordAge.TotalDays
        $now    = Get-Date
        $props  = @("DisplayName","SamAccountName","PasswordLastSet","PasswordNeverExpires","PasswordExpired","Enabled")

        $users = Get-ADUser -Filter { Enabled -eq $true } -Properties $props

        foreach ($u in $users) {
            if ($u.PasswordNeverExpires) {
                $neverExpires += [PSCustomObject]@{
                    Name    = $u.DisplayName
                    SAM     = $u.SamAccountName
                    LastSet = if ($u.PasswordLastSet) { $u.PasswordLastSet.ToString("yyyy-MM-dd") } else { "Never" }
                }
                continue
            }

            if (-not $u.PasswordLastSet) { continue }

            $expiryDate = $u.PasswordLastSet.AddDays($maxAge)
            $daysLeft   = [math]::Floor(($expiryDate - $now).TotalDays)

            if ($daysLeft -lt 0) {
                $alreadyExpired += [PSCustomObject]@{
                    Name   = $u.DisplayName
                    SAM    = $u.SamAccountName
                    Expiry = $expiryDate.ToString("yyyy-MM-dd")
                }
            } elseif ($daysLeft -le $days) {
                $expiringSoon += [PSCustomObject]@{
                    Name     = $u.DisplayName
                    SAM      = $u.SamAccountName
                    Expiry   = $expiryDate.ToString("yyyy-MM-dd")
                    DaysLeft = $daysLeft
                }
            }
        }

        $expiringSoon   = $expiringSoon   | Sort-Object DaysLeft
        $alreadyExpired = $alreadyExpired | Sort-Object Expiry
        $neverExpires   = $neverExpires   | Sort-Object Name

    } catch {
        Write-Host "[ERROR] Password expiry query failed: $_" -ForegroundColor Red
        return
    }

    Show-PasswordTable -ExpiringSoon $expiringSoon -AlreadyExpired $alreadyExpired -NeverExpires $neverExpires -Days $days

    $exportData = @{
        LookAheadDays  = $days
        ExpiringSoon   = $expiringSoon
        AlreadyExpired = $alreadyExpired
        NeverExpires   = $neverExpires
    }
    $choice = Read-Host "Export to HTML report? [Y/N]"
    if ($choice -match "^[Yy]") {
        $path = Export-HTMLReport -Data $exportData -ReportType "PasswordExpiry" -Username "PasswordExpiry" -Source "LocalAD"
        Write-Host "[OK] Report saved: $path" -ForegroundColor Green
    }
}

function Show-PasswordTable {
    param($ExpiringSoon, $AlreadyExpired, $NeverExpires, [int]$Days)
    $line = "=" * 70
    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host " PASSWORD EXPIRY DASHBOARD — Next $Days days" -ForegroundColor White
    Write-Host $line -ForegroundColor DarkCyan

    Write-Host "`n  EXPIRING SOON ($($ExpiringSoon.Count))" -ForegroundColor Yellow
    Write-Host ("-" * 70) -ForegroundColor DarkGray
    if ($ExpiringSoon.Count -eq 0) { Write-Host "  (none)" -ForegroundColor Gray }
    else {
        Write-Host ("  {0,-30} {1,-20} {2,-12} {3}" -f "Name", "SAM", "Expires", "Days Left") -ForegroundColor Gray
        foreach ($u in $ExpiringSoon) {
            $color = if ($u.DaysLeft -le 3) { "Red" } elseif ($u.DaysLeft -le 7) { "Yellow" } else { "White" }
            Write-Host ("  {0,-30} {1,-20} {2,-12} {3}" -f $u.Name, $u.SAM, $u.Expiry, $u.DaysLeft) -ForegroundColor $color
        }
    }

    Write-Host "`n  ALREADY EXPIRED ($($AlreadyExpired.Count))" -ForegroundColor Red
    Write-Host ("-" * 70) -ForegroundColor DarkGray
    if ($AlreadyExpired.Count -eq 0) { Write-Host "  (none)" -ForegroundColor Gray }
    else {
        Write-Host ("  {0,-30} {1,-20} {2}" -f "Name", "SAM", "Expired On") -ForegroundColor Gray
        foreach ($u in $AlreadyExpired) {
            Write-Host ("  {0,-30} {1,-20} {2}" -f $u.Name, $u.SAM, $u.Expiry) -ForegroundColor Red
        }
    }

    Write-Host "`n  PASSWORD NEVER EXPIRES ($($NeverExpires.Count))" -ForegroundColor Cyan
    Write-Host ("-" * 70) -ForegroundColor DarkGray
    if ($NeverExpires.Count -eq 0) { Write-Host "  (none)" -ForegroundColor Gray }
    else {
        Write-Host ("  {0,-30} {1,-20} {2}" -f "Name", "SAM", "Last Set") -ForegroundColor Gray
        foreach ($u in $NeverExpires) {
            Write-Host ("  {0,-30} {1,-20} {2}" -f $u.Name, $u.SAM, $u.LastSet)
        }
    }

    Write-Host "`n$line`n" -ForegroundColor DarkCyan
}
