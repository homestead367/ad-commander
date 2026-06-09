# Modules/Get-GroupInfo.ps1
# Written by Dallas Milem

function Invoke-GroupSearch {
    $query = Read-Host "`nEnter group name (partial match supported)"
    if ([string]::IsNullOrWhiteSpace($query)) {
        Write-Host "[ERROR] No input provided." -ForegroundColor Red
        return
    }

    $source = Get-ADSource
    Write-Host "`nSearching $source for group '$query'..." -ForegroundColor Cyan

    switch ($source) {
        "LocalAD" { Get-LocalADGroupInfo -Query $query }
        "Entra"   { Get-EntraGroupInfo   -Query $query }
    }
}

function Get-LocalADGroupInfo {
    param([string]$Query)
    try {
        $groups = Get-ADGroup -Filter { Name -like "*" } -Properties Description, GroupScope, GroupCategory |
            Where-Object { $_.Name -like "*$Query*" } | Select-Object -First 10

        if ($groups.Count -eq 0) { Write-Host "[NOT FOUND] No groups matching '$Query'." -ForegroundColor Yellow; return }

        $group = Select-GroupFromList -Groups $groups -NameProp "Name"

        $members = Get-ADGroupMember -Identity $group.DistinguishedName -Recursive |
            ForEach-Object {
                $props = @("DisplayName","SamAccountName","Enabled","LastLogonDate","ObjectClass")
                try {
                    if ($_.objectClass -eq "user") {
                        $u = Get-ADUser $_.SamAccountName -Properties $props -ErrorAction Stop
                        [PSCustomObject]@{
                            Name     = $u.DisplayName
                            SAM      = $u.SamAccountName
                            Type     = "User"
                            Enabled  = $u.Enabled
                            LastLogon = if ($u.LastLogonDate) { $u.LastLogonDate.ToString("yyyy-MM-dd") } else { "Never" }
                        }
                    } else {
                        [PSCustomObject]@{
                            Name = $_.Name; SAM = $_.SamAccountName
                            Type = $_.objectClass; Enabled = $true; LastLogon = "N/A"
                        }
                    }
                } catch {
                    [PSCustomObject]@{ Name = $_.Name; SAM = $_.SamAccountName; Type = $_.objectClass; Enabled = "?"; LastLogon = "N/A" }
                }
            }

        Show-GroupMemberTable -GroupName $group.Name -Members $members

        $exportData = @{ GroupName = $group.Name; Members = $members }
        $choice = Read-Host "Export to HTML report? [Y/N]"
        if ($choice -match "^[Yy]") {
            $path = Export-HTMLReport -Data $exportData -ReportType "GroupInfo" -Username $group.Name -Source "LocalAD"
            Write-Host "[OK] Report saved: $path" -ForegroundColor Green
        }
    } catch {
        Write-Host "[ERROR] Group search failed: $_" -ForegroundColor Red
    }
}

function Get-EntraGroupInfo {
    param([string]$Query)
    try {
        Import-Module Microsoft.Graph.Groups -ErrorAction SilentlyContinue
        $groups = Get-MgGroup -Filter "startswith(displayName,'$Query')" -Top 10 -ErrorAction Stop
        if ($groups.Count -eq 0) { Write-Host "[NOT FOUND] No groups matching '$Query'." -ForegroundColor Yellow; return }

        $group = Select-GroupFromList -Groups $groups -NameProp "DisplayName"

        $members = Get-MgGroupMember -GroupId $group.Id -All | ForEach-Object {
            [PSCustomObject]@{
                Name     = $_.AdditionalProperties["displayName"]
                SAM      = $_.AdditionalProperties["userPrincipalName"]
                Type     = $_.'@odata.type' -replace '#microsoft.graph.',''
                Enabled  = $_.AdditionalProperties["accountEnabled"]
                LastLogon = "N/A"
            }
        }

        Show-GroupMemberTable -GroupName $group.DisplayName -Members $members

        $exportData = @{ GroupName = $group.DisplayName; Members = $members }
        $choice = Read-Host "Export to HTML report? [Y/N]"
        if ($choice -match "^[Yy]") {
            $path = Export-HTMLReport -Data $exportData -ReportType "GroupInfo" -Username $group.DisplayName -Source "Entra"
            Write-Host "[OK] Report saved: $path" -ForegroundColor Green
        }
    } catch {
        Write-Host "[ERROR] Entra group search failed: $_" -ForegroundColor Red
    }
}

function Invoke-GroupComparison {
    $query1 = Read-Host "`nEnter first group name"
    $query2 = Read-Host "Enter second group name"
    if ([string]::IsNullOrWhiteSpace($query1) -or [string]::IsNullOrWhiteSpace($query2)) {
        Write-Host "[ERROR] Both group names required." -ForegroundColor Red
        return
    }

    $source = Get-ADSource
    Write-Host "`nFetching both groups from $source..." -ForegroundColor Cyan

    $members1 = @(); $members2 = @()
    $name1 = $query1; $name2 = $query2

    switch ($source) {
        "LocalAD" {
            $g1 = Get-ADGroup -Filter { Name -like "*" } | Where-Object { $_.Name -like "*$query1*" } | Select-Object -First 1
            $g2 = Get-ADGroup -Filter { Name -like "*" } | Where-Object { $_.Name -like "*$query2*" } | Select-Object -First 1
            if ($g1) { $name1 = $g1.Name; $members1 = Get-ADGroupMember -Identity $g1.DistinguishedName -Recursive | Select-Object Name, SamAccountName }
            if ($g2) { $name2 = $g2.Name; $members2 = Get-ADGroupMember -Identity $g2.DistinguishedName -Recursive | Select-Object Name, SamAccountName }
        }
        "Entra" {
            Import-Module Microsoft.Graph.Groups -ErrorAction SilentlyContinue
            $g1 = Get-MgGroup -Filter "startswith(displayName,'$query1')" -Top 1 -ErrorAction SilentlyContinue
            $g2 = Get-MgGroup -Filter "startswith(displayName,'$query2')" -Top 1 -ErrorAction SilentlyContinue
            if ($g1) {
                $name1 = $g1.DisplayName
                $members1 = Get-MgGroupMember -GroupId $g1.Id -All | ForEach-Object {
                    [PSCustomObject]@{ Name = $_.AdditionalProperties["displayName"]; SamAccountName = $_.AdditionalProperties["userPrincipalName"] }
                }
            }
            if ($g2) {
                $name2 = $g2.DisplayName
                $members2 = Get-MgGroupMember -GroupId $g2.Id -All | ForEach-Object {
                    [PSCustomObject]@{ Name = $_.AdditionalProperties["displayName"]; SamAccountName = $_.AdditionalProperties["userPrincipalName"] }
                }
            }
        }
    }

    $sams1 = $members1 | ForEach-Object { $_.SamAccountName }
    $sams2 = $members2 | ForEach-Object { $_.SamAccountName }

    $onlyIn1 = $members1 | Where-Object { $_.SamAccountName -notin $sams2 } | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; SAM = $_.SamAccountName } }
    $onlyIn2 = $members2 | Where-Object { $_.SamAccountName -notin $sams1 } | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; SAM = $_.SamAccountName } }
    $inBoth  = $members1 | Where-Object { $_.SamAccountName -in $sams2 }    | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; SAM = $_.SamAccountName } }

    Show-GroupComparisonTable -Name1 $name1 -Name2 $name2 -Only1 $onlyIn1 -Only2 $onlyIn2 -Both $inBoth

    $exportData = @{
        Group1Name   = $name1; Group2Name = $name2
        OnlyInGroup1 = $onlyIn1; OnlyInGroup2 = $onlyIn2; InBoth = $inBoth
    }
    $choice = Read-Host "Export to HTML report? [Y/N]"
    if ($choice -match "^[Yy]") {
        $path = Export-HTMLReport -Data $exportData -ReportType "GroupComparison" -Username "${name1}_vs_${name2}" -Source (Get-ADSource)
        Write-Host "[OK] Report saved: $path" -ForegroundColor Green
    }
}

function Select-GroupFromList {
    param($Groups, [string]$NameProp)
    if ($Groups.Count -eq 1) { return $Groups[0] }
    Write-Host "`n  Multiple matches found:" -ForegroundColor Yellow
    $i = 1
    foreach ($g in $Groups) { Write-Host ("  [{0}] {1}" -f $i, $g.$NameProp); $i++ }
    $sel = Read-Host "`n  Select number"
    return $Groups[[int]$sel - 1]
}

function Show-GroupMemberTable {
    param([string]$GroupName, $Members)
    $line = "=" * 72
    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host " GROUP: $GroupName ($($Members.Count) members)" -ForegroundColor White
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ("  {0,-30} {1,-25} {2,-10} {3,-8} {4}" -f "Name","SAM","Type","Enabled","Last Logon") -ForegroundColor Gray
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    foreach ($m in $Members | Sort-Object Name) {
        $color = if ($m.Enabled -eq $false) { "Yellow" } else { "White" }
        Write-Host ("  {0,-30} {1,-25} {2,-10} {3,-8} {4}" -f $m.Name, $m.SAM, $m.Type, $m.Enabled, $m.LastLogon) -ForegroundColor $color
    }
    Write-Host "$line`n" -ForegroundColor DarkCyan
}

function Show-GroupComparisonTable {
    param([string]$Name1, [string]$Name2, $Only1, $Only2, $Both)
    $line = "=" * 72
    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host " GROUP COMPARISON: $Name1 vs $Name2" -ForegroundColor White
    Write-Host $line -ForegroundColor DarkCyan

    Write-Host "`n  IN '$Name1' ONLY ($($Only1.Count))" -ForegroundColor Red
    foreach ($m in $Only1) { Write-Host ("  {0,-30} {1}" -f $m.Name, $m.SAM) -ForegroundColor Red }

    Write-Host "`n  IN '$Name2' ONLY ($($Only2.Count))" -ForegroundColor Green
    foreach ($m in $Only2) { Write-Host ("  {0,-30} {1}" -f $m.Name, $m.SAM) -ForegroundColor Green }

    Write-Host "`n  IN BOTH ($($Both.Count))" -ForegroundColor Gray
    foreach ($m in $Both) { Write-Host ("  {0,-30} {1}" -f $m.Name, $m.SAM) }
    Write-Host "$line`n" -ForegroundColor DarkCyan
}
