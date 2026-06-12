# Modules/Invoke-HealthCheck.ps1
# Written by Dallas Milem

function Invoke-ADHealthCheck {
    $domain = $env:USERDNSDOMAIN
    if ([string]::IsNullOrEmpty($domain)) {
        try { $domain = (Get-ADDomain).DNSRoot } catch {}
    }
    if ([string]::IsNullOrEmpty($domain)) {
        $domain = Read-Host "`nCould not auto-detect domain. Enter domain DNS name"
    }

    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    Write-Host "  AD HEALTH CHECK — $($domain.ToUpper())" -ForegroundColor White
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    Write-Host ""

    $results = @()
    $checks = @(
        @{ Name = "DC Diagnostics";        Fn = { Get-DCDiagResults } },
        @{ Name = "AD Replication";        Fn = { Get-ReplicationResults } },
        @{ Name = "DFSR / Sysvol";         Fn = { Get-DFSRResults } },
        @{ Name = "DNS and Network";         Fn = { Get-DNSResults -Domain $domain } },
        @{ Name = "FSMO Roles and Time";     Fn = { Get-FSMOResults } },
        @{ Name = "Group Policy Health";   Fn = { Get-GPHealthResults } },
        @{ Name = "Privileged Groups";     Fn = { Get-PrivGroupResults } },
        @{ Name = "Forest and Domain Info";  Fn = { Get-ForestInfoResults } }
    )

    foreach ($check in $checks) {
        Write-Host "  Running: $($check.Name)..." -NoNewline -ForegroundColor Cyan
        try {
            $result = & $check.Fn
            $color  = switch ($result.Status) { "Pass" { "Green" } "Warning" { "Yellow" } default { "Red" } }
            Write-Host " $($result.Status)" -ForegroundColor $color
            $results += $result
        } catch {
            Write-Host " ERROR" -ForegroundColor Red
            $results += [PSCustomObject]@{ Category = $check.Name; Status = "Fail"; Output = $_.ToString() }
        }
    }

    $pass = ($results | Where-Object { $_.Status -eq "Pass" }).Count
    $warn = ($results | Where-Object { $_.Status -eq "Warning" }).Count
    $fail = ($results | Where-Object { $_.Status -eq "Fail" }).Count

    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    Write-Host ("  SUMMARY  Pass: {0}  Warning: {1}  Fail: {2}" -f $pass, $warn, $fail) -ForegroundColor White
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    Write-Host ""

    $exportData = @{ Domain = $domain; Results = $results }
    $choice = Read-Host "Export to HTML report? [Y/N]"
    if ($choice -match "^[Yy]") {
        $path = Export-HTMLReport -Data $exportData -ReportType "HealthCheck" -Username $domain -Source "LocalAD"
        Write-Host "[OK] Report saved: $path" -ForegroundColor Green
    }
}

function Get-DCDiagResults {
    $output = ""
    $status = "Pass"
    try {
        $tests = @("/test:services", "/test:advertising", "/test:fsmocheck")
        foreach ($t in $tests) {
            $out = & dcdiag $t 2>&1 | Out-String
            $output += "--- dcdiag $t ---`n$out`n"
            if ($out -match "failed|error|FAIL") { $status = "Fail" }
            elseif ($out -match "warning|warn" -and $status -ne "Fail") { $status = "Warning" }
        }
    } catch { $output = "dcdiag not available: $_"; $status = "Warning" }
    return [PSCustomObject]@{ Category = "DC Diagnostics"; Status = $status; Output = $output }
}

function Get-ReplicationResults {
    $output = ""
    $status = "Pass"
    try {
        $summary = & repadmin /replsummary 2>&1 | Out-String
        $output += "--- repadmin /replsummary ---`n$summary`n"
        if ($summary -match "error|fail|\*FAIL") { $status = "Fail" }
        elseif ($summary -match "warning|warn" -and $status -ne "Fail") { $status = "Warning" }

        $queue = & repadmin /queue 2>&1 | Out-String
        $output += "--- repadmin /queue ---`n$queue`n"
        if ($queue -match "[1-9][0-9]* operation") { $status = if ($status -eq "Fail") { "Fail" } else { "Warning" } }
    } catch { $output = "repadmin not available: $_"; $status = "Warning" }
    return [PSCustomObject]@{ Category = "AD Replication"; Status = $status; Output = $output }
}

function Get-DFSRResults {
    $output = ""
    $status = "Pass"
    try {
        $mig = & dfsrmig /getglobalstate 2>&1 | Out-String
        $output += "--- dfsrmig /getglobalstate ---`n$mig`n"
        if ($mig -match "error|fail") { $status = "Fail" }

        try {
            $dcs = (Get-ADDomainController -Filter *).HostName | Select-Object -First 2
            if ($dcs.Count -ge 2) {
                $backlog = & dfsrdiag backlog /SendingMember:$($dcs[0]) /ReceivingMember:$($dcs[1]) /RGName:"Domain System Volume" /RFName:"SYSVOL Share" 2>&1 | Out-String
                $output += "--- dfsrdiag backlog ---`n$backlog`n"
                if ($backlog -match "error|fail") { $status = if ($status -ne "Fail") { "Warning" } else { "Fail" } }
            }
        } catch { $output += "dfsrdiag backlog: skipped (single DC or unavailable)`n" }
    } catch { $output = "DFSR tools not available: $_"; $status = "Warning" }
    return [PSCustomObject]@{ Category = "DFSR / Sysvol"; Status = $status; Output = $output }
}

function Get-DNSResults {
    param([string]$Domain)
    $output = ""
    $status = "Pass"
    try {
        $srv = & nslookup -type=SRV "_ldap._tcp.$Domain" 2>&1 | Out-String
        $output += "--- SRV record: _ldap._tcp.$Domain ---`n$srv`n"
        if ($srv -match "can't find|SERVFAIL|no response") { $status = "Fail" }

        $kdc = & nslookup -type=SRV "_kerberos._tcp.$Domain" 2>&1 | Out-String
        $output += "--- SRV record: _kerberos._tcp.$Domain ---`n$kdc`n"
        if ($kdc -match "can't find|SERVFAIL" -and $status -ne "Fail") { $status = "Warning" }

        $ipcfg = & ipconfig /all 2>&1 | Out-String
        $output += "--- ipconfig /all ---`n$ipcfg`n"
    } catch { $output = "DNS check failed: $_"; $status = "Warning" }
    return [PSCustomObject]@{ Category = "DNS and Network"; Status = $status; Output = $output }
}

function Get-FSMOResults {
    $output = ""
    $status = "Pass"
    try {
        $fsmo = & netdom query fsmo 2>&1 | Out-String
        $output += "--- netdom query fsmo ---`n$fsmo`n"
        if ($fsmo -match "error|fail") { $status = "Fail" }

        try {
            $dom = Get-ADDomain
            $for = Get-ADForest
            $output += "--- FSMO Role Holders ---`n"
            $output += "PDC Emulator:          $($dom.PDCEmulator)`n"
            $output += "RID Master:            $($dom.RIDMaster)`n"
            $output += "Infrastructure Master: $($dom.InfrastructureMaster)`n"
            $output += "Schema Master:         $($for.SchemaMaster)`n"
            $output += "Domain Naming Master:  $($for.DomainNamingMaster)`n"
        } catch {}

        $time = & w32tm /query /status 2>&1 | Out-String
        $output += "`n--- w32tm /query /status ---`n$time`n"
        if ($time -match "error|not running") { $status = if ($status -ne "Fail") { "Warning" } else { "Fail" } }
    } catch { $output = "FSMO check failed: $_"; $status = "Warning" }
    return [PSCustomObject]@{ Category = "FSMO Roles and Time"; Status = $status; Output = $output }
}

function Get-GPHealthResults {
    $output = ""
    $status = "Pass"
    try {
        $gpr = & gpresult /r 2>&1 | Out-String
        $output += "--- gpresult /r ---`n$gpr`n"
        if ($gpr -match "error|failed") { $status = "Warning" }

        try {
            Import-Module GroupPolicy -ErrorAction Stop
            $gpos = Get-GPO -All
            $output += "`n--- GPO Count: $($gpos.Count) ---`n"
            $unlinked = $gpos | Where-Object { $_.GpoStatus -eq "AllSettingsDisabled" }
            if ($unlinked.Count -gt 0) {
                $output += "Disabled GPOs ($($unlinked.Count)):`n"
                $unlinked | ForEach-Object { $output += "  - $($_.DisplayName)`n" }
                $status = if ($status -ne "Fail") { "Warning" } else { "Fail" }
            }
        } catch { $output += "GroupPolicy module unavailable for GPO enumeration.`n" }
    } catch { $output = "GP health check failed: $_"; $status = "Warning" }
    return [PSCustomObject]@{ Category = "Group Policy Health"; Status = $status; Output = $output }
}

function Get-PrivGroupResults {
    $output = ""
    $status = "Pass"
    try {
        foreach ($grp in @("Domain Admins", "Enterprise Admins")) {
            try {
                $members = Get-ADGroupMember -Identity $grp -Recursive -ErrorAction Stop
                $output += "--- $grp ($($members.Count) members) ---`n"
                foreach ($m in $members) { $output += "  $($m.SamAccountName)`n" }
                $output += "`n"
            } catch { $output += "$($grp): not found or access denied`n" }
        }
    } catch { $output = "Privileged group check failed: $_"; $status = "Warning" }
    return [PSCustomObject]@{ Category = "Privileged Groups"; Status = $status; Output = $output }
}

function Get-ForestInfoResults {
    $output = ""
    $status = "Pass"
    try {
        $dom = Get-ADDomain
        $for = Get-ADForest

        $domLevels = @{ 0="2000"; 1="2003 Interim"; 2="2003"; 3="2008"; 4="2008 R2"; 5="2012"; 6="2012 R2"; 7="2016"; 10="2019/2022" }
        $domLevel  = if ($domLevels.ContainsKey([int]$dom.DomainMode)) { $domLevels[[int]$dom.DomainMode] } else { $dom.DomainMode }
        $forLevel  = if ($domLevels.ContainsKey([int]$for.ForestMode))  { $domLevels[[int]$for.ForestMode]  } else { $for.ForestMode }

        $output += "Domain:             $($dom.DNSRoot)`n"
        $output += "Domain Functional:  Windows Server $domLevel`n"
        $output += "Forest:             $($for.Name)`n"
        $output += "Forest Functional:  Windows Server $forLevel`n"
        $output += "Domain Controllers: $(($dom.ReplicaDirectoryServers + $dom.ReadOnlyReplicaDirectoryServers) -join ', ')`n"
        $output += "Sites:              $($for.Sites -join ', ')`n"
        $output += "Domains in Forest:  $($for.Domains -join ', ')`n"
    } catch { $output = "Forest info failed: $_"; $status = "Warning" }
    return [PSCustomObject]@{ Category = "Forest and Domain Info"; Status = $status; Output = $output }
}
