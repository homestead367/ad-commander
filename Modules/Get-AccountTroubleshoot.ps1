# Modules/Get-AccountTroubleshoot.ps1
# Written by Dallas Milem

function Invoke-AccountTroubleshootReport {
    $query = Read-Host "`nEnter username to troubleshoot (SAM or Display Name)"
    if ([string]::IsNullOrWhiteSpace($query)) {
        Write-Host "[ERROR] No input provided." -ForegroundColor Red
        return
    }

    try {
        $props = @(
            "DisplayName","SamAccountName","Enabled","AccountExpirationDate",
            "PasswordExpired","PasswordNeverExpires","PasswordLastSet","LockedOut","LogonHours",
            "LogonWorkstations","MemberOf","LastLogonDate","msDS-UserPasswordExpiryTimeComputed"
        )
        $user = Get-ADUser -Filter {
            SamAccountName -eq $query -or DisplayName -eq $query
        } -Properties $props -ErrorAction Stop | Select-Object -First 1

        if ($null -eq $user) {
            Write-Host "[NOT FOUND] No account matching '$query'." -ForegroundColor Yellow
            return
        }
    } catch {
        Write-Host "[ERROR] AD query failed: $_" -ForegroundColor Red
        return
    }

    Write-Host "`nQuerying domain controllers for bad-password / lockout trace..." -ForegroundColor Cyan
    $dcTrace = Get-AccountLockoutTrace -SamAccountName $user.SamAccountName

    $logonHours = "Not Restricted"
    $unrestricted = [byte[]]@(255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255)
    if ($user.LogonHours -and (Compare-Object $user.LogonHours $unrestricted)) {
        $logonHours = "Custom Schedule Set"
    }

    $groups = @()
    if ($user.MemberOf) {
        $groups = $user.MemberOf | ForEach-Object {
            try { (Get-ADGroup $_).Name } catch { $_ }
        }
    }

    $reportData = [ordered]@{
        "Display Name"          = $user.DisplayName
        "SAM Account Name"      = $user.SamAccountName
        "Account Enabled"       = $user.Enabled
        "Account Expiration"    = if ($user.AccountExpirationDate) { $user.AccountExpirationDate.ToString("yyyy-MM-dd") } else { "Never" }
        "Password Expired"      = $user.PasswordExpired
        "Password Never Expires"= $user.PasswordNeverExpires
        "Last Password Change"  = if ($user.PasswordLastSet) { $user.PasswordLastSet.ToString("yyyy-MM-dd HH:mm:ss") } else { "Never" }
        "Password Expires On"   = if ($user.PasswordNeverExpires) { "Never" }
                                   elseif ($user.'msDS-UserPasswordExpiryTimeComputed' -and $user.'msDS-UserPasswordExpiryTimeComputed' -lt [Int64]::MaxValue) {
                                       [datetime]::FromFileTime($user.'msDS-UserPasswordExpiryTimeComputed').ToString("yyyy-MM-dd HH:mm:ss")
                                   } else { "Unknown" }
        "Last Logon"            = if ($user.LastLogonDate) { $user.LastLogonDate.ToString("yyyy-MM-dd HH:mm:ss") } else { "Never / Unknown" }
        "Locked Out"            = $user.LockedOut
        "Logon Hours"           = $logonHours
        "Logon Workstations"    = if ($user.LogonWorkstations) { $user.LogonWorkstations } else { "Not Restricted" }
        "Group Memberships"     = if ($groups.Count -gt 0) { $groups -join ", " } else { "None" }
    }

    Show-TroubleshootTable -State $reportData -DCTrace $dcTrace

    $exportData = @{ State = $reportData; DCTrace = $dcTrace }
    $choice = Read-Host "Export to HTML report? [Y/N]"
    if ($choice -match "^[Yy]") {
        $path = Export-HTMLReport -Data $exportData -ReportType "AccountTroubleshoot" -Username $user.SamAccountName -Source "LocalAD"
        Write-Host "[OK] Report saved: $path" -ForegroundColor Green
    }
}

function Get-AccountLockoutTrace {
    param([string]$SamAccountName)

    $trace = @()
    try {
        $dcs = Get-ADDomainController -Filter * -ErrorAction Stop
    } catch {
        Write-Host "[ERROR] Could not enumerate domain controllers: $_" -ForegroundColor Red
        return $trace
    }

    foreach ($dc in $dcs) {
        try {
            $u = Get-ADUser -Identity $SamAccountName -Server $dc.HostName `
                -Properties badPwdCount, lastBadPasswordAttempt, LockedOut, AccountLockoutTime `
                -ErrorAction Stop

            $trace += [PSCustomObject]@{
                DC                     = $dc.HostName
                Status                 = "OK"
                BadPwdCount            = $u.badPwdCount
                LastBadPasswordAttempt = if ($u.lastBadPasswordAttempt) { $u.lastBadPasswordAttempt.ToString("yyyy-MM-dd HH:mm:ss") } else { "N/A" }
                LockedOut              = $u.LockedOut
                AccountLockoutTime     = if ($u.AccountLockoutTime) { $u.AccountLockoutTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "N/A" }
                LastBadPasswordRaw     = $u.lastBadPasswordAttempt
            }
        } catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
            # DC answered but doesn't have the object yet (e.g. replication lag) -
            # distinct from a DC that couldn't be reached at all.
            $trace += [PSCustomObject]@{
                DC = $dc.HostName; Status = "NotFound"; BadPwdCount = "N/A"
                LastBadPasswordAttempt = "N/A"; LockedOut = "N/A"; AccountLockoutTime = "N/A"
                LastBadPasswordRaw = $null
            }
        } catch {
            $trace += [PSCustomObject]@{
                DC = $dc.HostName; Status = "Unreachable"; BadPwdCount = "N/A"
                LastBadPasswordAttempt = "N/A"; LockedOut = "N/A"; AccountLockoutTime = "N/A"
                LastBadPasswordRaw = $null
            }
        }
    }

    return $trace
}

function Show-TroubleshootTable {
    param($State, $DCTrace)

    $line = "=" * 75
    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host " ACCOUNT TROUBLESHOOTING REPORT" -ForegroundColor White
    Write-Host $line -ForegroundColor DarkCyan

    Write-Host "`n  ACCOUNT STATE" -ForegroundColor Cyan
    Write-Host ("-" * 75) -ForegroundColor DarkGray
    foreach ($key in $State.Keys) {
        $val = if ($null -eq $State[$key]) { "N/A" } else { $State[$key].ToString() }
        Write-Host ("  {0,-25} {1}" -f "$key :", $val)
    }

    $likelySource = $DCTrace | Where-Object { $_.Status -eq "OK" -and $_.LastBadPasswordRaw } |
        Sort-Object LastBadPasswordRaw -Descending | Select-Object -First 1

    Write-Host "`n  BAD PASSWORD / LOCKOUT TRACE BY DC ($($DCTrace.Count))" -ForegroundColor Cyan
    Write-Host ("-" * 75) -ForegroundColor DarkGray
    if ($DCTrace.Count -eq 0) {
        Write-Host "  (no domain controllers found)" -ForegroundColor Gray
    } else {
        Write-Host ("  {0,-25} {1,-10} {2,-22} {3}" -f "DC", "BadPwd#", "Last Bad Attempt", "Locked Out") -ForegroundColor Gray
        foreach ($d in $DCTrace) {
            if ($d.Status -eq "NotFound") {
                Write-Host ("  {0,-25} {1}" -f $d.DC, "[NOT FOUND - possible replication lag]") -ForegroundColor Yellow
                continue
            }
            if ($d.Status -eq "Unreachable") {
                Write-Host ("  {0,-25} {1}" -f $d.DC, "[UNREACHABLE]") -ForegroundColor DarkGray
                continue
            }
            $isLikely = $likelySource -and $d.DC -eq $likelySource.DC
            $color = if ($isLikely) { "Yellow" } elseif ($d.LockedOut -eq $true) { "Red" } else { "White" }
            $flag = if ($isLikely) { "  <- likely source" } else { "" }
            Write-Host ("  {0,-25} {1,-10} {2,-22} {3}{4}" -f `
                $d.DC, $d.BadPwdCount, $d.LastBadPasswordAttempt, $d.LockedOut, $flag) -ForegroundColor $color
        }
    }
    Write-Host "`n$line`n" -ForegroundColor DarkCyan
}
