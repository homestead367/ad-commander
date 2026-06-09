# Modules/Get-PrivilegedAccess.ps1
# Written by Dallas Milem

function Invoke-PrivilegedAccessAudit {
    Write-Host "`nRunning Privileged Access Audit..." -ForegroundColor Cyan

    $staleThreshold = (Get-Date).AddDays(-90)
    $groupNames = @(
        "Domain Admins",
        "Enterprise Admins",
        "Schema Admins",
        "Protected Users",
        "Account Operators",
        "Backup Operators"
    )

    $auditGroups = @()

    foreach ($groupName in $groupNames) {
        Write-Host "  Querying: $groupName..." -NoNewline -ForegroundColor Cyan
        try {
            $group = Get-ADGroup -Filter { Name -eq $groupName } -ErrorAction SilentlyContinue
            if (-not $group) { Write-Host " not found" -ForegroundColor Gray; continue }

            $rawMembers = Get-ADGroupMember -Identity $group.DistinguishedName -Recursive -ErrorAction Stop
            $members = @()

            foreach ($m in $rawMembers) {
                try {
                    if ($m.objectClass -eq "user") {
                        $u = Get-ADUser $m.SamAccountName -Properties DisplayName, SamAccountName, Enabled, LastLogonDate, PasswordLastSet -ErrorAction Stop
                        $staleFlag = ($u.LastLogonDate -and $u.LastLogonDate -lt $staleThreshold) -or (-not $u.LastLogonDate)
                        $members += [PSCustomObject]@{
                            Name      = $u.DisplayName
                            SAM       = $u.SamAccountName
                            Enabled   = $u.Enabled
                            LastLogon = if ($u.LastLogonDate) { $u.LastLogonDate.ToString("yyyy-MM-dd") } else { "Never" }
                            PwLastSet = if ($u.PasswordLastSet) { $u.PasswordLastSet.ToString("yyyy-MM-dd") } else { "Never" }
                            StaleFlag = $staleFlag
                        }
                    } else {
                        $members += [PSCustomObject]@{
                            Name = $m.Name; SAM = $m.SamAccountName
                            Enabled = $true; LastLogon = "N/A"; PwLastSet = "N/A"; StaleFlag = $false
                        }
                    }
                } catch {
                    $members += [PSCustomObject]@{
                        Name = $m.Name; SAM = $m.SamAccountName
                        Enabled = "?"; LastLogon = "N/A"; PwLastSet = "N/A"; StaleFlag = $false
                    }
                }
            }

            Write-Host " $($members.Count) members" -ForegroundColor Green
            $auditGroups += @{ Name = $groupName; Members = $members }

        } catch {
            Write-Host " ERROR: $_" -ForegroundColor Red
        }
    }

    Show-PrivilegedTable -Groups $auditGroups

    $exportData = @{ Groups = $auditGroups }
    $choice = Read-Host "Export to HTML report? [Y/N]"
    if ($choice -match "^[Yy]") {
        $path = Export-HTMLReport -Data $exportData -ReportType "PrivilegedAccess" -Username "PrivilegedAudit" -Source "LocalAD"
        Write-Host "[OK] Report saved: $path" -ForegroundColor Green
    }
}

function Show-PrivilegedTable {
    param($Groups)
    $line = "=" * 75
    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host " PRIVILEGED ACCESS AUDIT" -ForegroundColor White
    Write-Host $line -ForegroundColor DarkCyan

    foreach ($g in $Groups) {
        Write-Host "`n  $($g.Name.ToUpper()) ($($g.Members.Count) members)" -ForegroundColor Cyan
        Write-Host ("-" * 75) -ForegroundColor DarkGray
        if ($g.Members.Count -eq 0) { Write-Host "  (empty)" -ForegroundColor Gray; continue }

        Write-Host ("  {0,-28} {1,-22} {2,-8} {3,-12} {4}" -f "Name","SAM","Enabled","Last Logon","Flag") -ForegroundColor Gray

        foreach ($m in $g.Members | Sort-Object Name) {
            $flag  = ""
            $color = "White"
            if ($m.Enabled -eq $false) {
                $flag = "[DISABLED]"; $color = "Red"
            } elseif ($m.StaleFlag) {
                $flag = "[INACTIVE 90d+]"; $color = "Yellow"
            }
            Write-Host ("  {0,-28} {1,-22} {2,-8} {3,-12} {4}" -f `
                $m.Name, $m.SAM, $m.Enabled, $m.LastLogon, $flag) -ForegroundColor $color
        }
    }
    Write-Host "`n$line`n" -ForegroundColor DarkCyan
}
