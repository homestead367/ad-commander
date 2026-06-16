# Modules/Export-HTML.ps1
# Written by Dallas Milem

function Export-HTMLReport {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Data,

        [Parameter(Mandatory)]
        [ValidateSet("SearchResult","Comparison","GPOReport","HealthCheck",
                     "StaleAccounts","PasswordExpiry","ComputerSearch",
                     "GroupInfo","GroupComparison","PrivilegedAccess","RadiusAudit")]
        [string]$ReportType,

        [Parameter(Mandatory)]
        [string]$Username,

        [string]$Source = "Unknown"
    )

    $reportsDir = Join-Path $PSScriptRoot "..\Reports"
    if (-not (Test-Path $reportsDir)) {
        New-Item -ItemType Directory -Path $reportsDir | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safe      = $Username -replace '[\\/:*?"<>|]', '_'
    $filepath  = Join-Path $reportsDir "${safe}_${ReportType}_${timestamp}.html"

    $css = @"
<style>
  *{box-sizing:border-box}
  body{font-family:Segoe UI,Arial,sans-serif;background:#f4f6f8;margin:0;padding:0}
  header{background:#1a1a2e;color:#fff;padding:18px 32px}
  header h1{margin:0;font-size:1.6em;letter-spacing:1px}
  header p{margin:4px 0 0;font-size:.85em;color:#aaa}
  .container{padding:24px 32px}
  h2{color:#1a1a2e;margin:24px 0 10px}
  h3{color:#333;margin:16px 0 8px;font-size:1em}
  table{border-collapse:collapse;width:100%;background:#fff;
        box-shadow:0 1px 4px rgba(0,0,0,.08);border-radius:6px;
        overflow:hidden;margin-bottom:20px}
  th{background:#1a1a2e;color:#fff;padding:10px 14px;text-align:left;font-size:.88em}
  td{padding:9px 14px;border-bottom:1px solid #e8ecf0;font-size:.88em;vertical-align:top}
  tr:last-child td{border-bottom:none}
  tr.diff td{background:#fff3f3}
  tr.diff td.val1{color:#c0392b}
  tr.diff td.val2{color:#27ae60}
  tr.same td{background:#fff}
  tr.warn td{background:#fffbea}
  tr.danger td{background:#fff0f0}
  .badge{border-radius:3px;padding:2px 7px;font-size:.75em;font-weight:600;white-space:nowrap}
  .badge-ok{background:#27ae60;color:#fff}
  .badge-warn{background:#f39c12;color:#fff}
  .badge-fail{background:#e74c3c;color:#fff}
  .badge-diff{background:#e74c3c;color:#fff}
  .badge-applied{background:#27ae60;color:#fff}
  .badge-denied{background:#e74c3c;color:#fff}
  .badge-info{background:#2980b9;color:#fff}
  .summary-bar{display:flex;gap:16px;margin-bottom:20px;flex-wrap:wrap}
  .summary-card{background:#fff;border-radius:8px;padding:14px 20px;
                box-shadow:0 1px 4px rgba(0,0,0,.08);min-width:120px;text-align:center}
  .summary-card .num{font-size:2em;font-weight:700}
  .summary-card .lbl{font-size:.8em;color:#666;margin-top:2px}
  .ok-num{color:#27ae60}.warn-num{color:#f39c12}.fail-num{color:#e74c3c}
  footer{padding:16px 32px;color:#888;font-size:.8em;
         border-top:1px solid #e0e0e0;margin-top:24px}
  details summary{cursor:pointer;padding:10px 14px;background:#f0f2f5;
                   border-radius:4px;font-weight:600;margin-bottom:4px;
                   list-style:none}
  details summary::-webkit-details-marker{display:none}
  details[open] summary{background:#e2e6ea}
  details .detail-body{padding:12px 14px;background:#fff;
                        border:1px solid #e0e0e0;border-radius:0 0 4px 4px;
                        font-size:.85em;white-space:pre-wrap;font-family:Consolas,monospace;
                        max-height:400px;overflow-y:auto}
</style>
"@

    $hdr = "<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'>" +
           "<title>ADCommander  -  $ReportType</title>$css</head><body>" +
           "<header><h1>ADCommander</h1><p>Written by Dallas Milem &nbsp;|&nbsp; " +
           "Report: $ReportType &nbsp;|&nbsp; $Username &nbsp;|&nbsp; Source: $Source</p></header>" +
           "<div class='container'>"

    $ftr = "</div><footer>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') &nbsp;|&nbsp; " +
           "Source: $Source &nbsp;|&nbsp; ADCommander v1.0  -  Written by Dallas Milem</footer></body></html>"

    $body = switch ($ReportType) {
        "SearchResult"    { Build-SearchHTML    -Data $Data }
        "Comparison"      { Build-ComparisonHTML -Data $Data }
        "GPOReport"       { Build-GPOHTML        -Data $Data }
        "HealthCheck"     { Build-HealthHTML     -Data $Data }
        "StaleAccounts"   { Build-StaleHTML      -Data $Data }
        "PasswordExpiry"  { Build-PasswordHTML   -Data $Data }
        "ComputerSearch"  { Build-ComputerHTML   -Data $Data }
        "GroupInfo"       { Build-GroupInfoHTML  -Data $Data }
        "GroupComparison" { Build-GroupCompHTML  -Data $Data }
        "PrivilegedAccess"{ Build-PrivHTML       -Data $Data }
        "RadiusAudit"     { Build-RadiusHTML     -Data $Data }
    }

    ($hdr + $body + $ftr) | Out-File -FilePath $filepath -Encoding UTF8
    return $filepath
}

# -- Helpers -------------------------------------------------------------------

function script:HE([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return "<em>N/A</em>" }
    return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;').Replace("'",'&#39;')
}

function Build-SearchHTML {
    param([hashtable]$Data)
    $rows = ""
    foreach ($k in $Data.Keys) {
        $rows += "<tr><td><strong>$(HE $k)</strong></td><td>$(HE ([string]$Data[$k]))</td></tr>`n"
    }
    return "<h2>User Details</h2><table><thead><tr><th>Field</th><th>Value</th></tr></thead><tbody>$rows</tbody></table>"
}

function Build-ComparisonHTML {
    param([hashtable]$Data)
    $u1 = HE $Data.User1Name; $u2 = HE $Data.User2Name
    $rows = ""
    foreach ($r in $Data.Rows) {
        $css = if ($r.IsDiff) { "diff" } else { "same" }
        $badge = if ($r.IsDiff) { '<span class="badge badge-diff">DIFF</span>' } else { "" }
        $c1 = if ($r.IsDiff) { ' class="val1"' } else { "" }
        $c2 = if ($r.IsDiff) { ' class="val2"' } else { "" }
        $rows += "<tr class='$css'><td><strong>$(HE $r.Field)</strong>$badge</td>" +
                 "<td$c1>$(HE $r.Val1)</td><td$c2>$(HE $r.Val2)</td></tr>`n"
    }
    return "<h2>User Comparison</h2><table><thead><tr><th>Field</th><th>$u1</th><th>$u2</th></tr></thead><tbody>$rows</tbody></table>"
}

function Build-GPOHTML {
    param([hashtable]$Data)
    $applied = ""; $denied = ""
    foreach ($g in $Data.AppliedGPOs) {
        $applied += "<tr><td>$($g.Order)</td><td>$(HE $g.Name)</td><td>$($g.Scope)</td>" +
                    "<td><span class='badge badge-applied'>Applied</span></td></tr>`n"
    }
    foreach ($g in $Data.DeniedGPOs) {
        $denied += "<tr><td> - </td><td>$(HE $g.Name)</td><td>$($g.Scope)</td>" +
                   "<td><span class='badge badge-denied'>$(HE $g.Reason)</span></td></tr>`n"
    }
    $loop = if ($Data.LoopbackMode -and $Data.LoopbackMode -ne "None") {
        "<p><strong>Loopback Mode:</strong> $($Data.LoopbackMode)</p>" } else { "" }
    return "<h2>GPO Resultant Set  -  $(HE $Data.Username)</h2>$loop" +
           "<table><thead><tr><th>#</th><th>Policy Name</th><th>Scope</th><th>Status</th></tr></thead>" +
           "<tbody>$applied$denied</tbody></table>"
}

function Build-HealthHTML {
    param([hashtable]$Data)
    $pass = ($Data.Results | Where-Object { $_.Status -eq "Pass" }).Count
    $warn = ($Data.Results | Where-Object { $_.Status -eq "Warning" }).Count
    $fail = ($Data.Results | Where-Object { $_.Status -eq "Fail" }).Count
    $summary = "<div class='summary-bar'>" +
               "<div class='summary-card'><div class='num ok-num'>$pass</div><div class='lbl'>Pass</div></div>" +
               "<div class='summary-card'><div class='num warn-num'>$warn</div><div class='lbl'>Warning</div></div>" +
               "<div class='summary-card'><div class='num fail-num'>$fail</div><div class='lbl'>Fail</div></div>" +
               "</div>"
    $sections = ""
    foreach ($r in $Data.Results) {
        $badgeClass = switch ($r.Status) { "Pass" { "badge-ok" } "Warning" { "badge-warn" } default { "badge-fail" } }
        $out = HE $r.Output
        $sections += "<details><summary><span class='badge $badgeClass'>$($r.Status)</span> &nbsp; $(HE $r.Category)</summary>" +
                     "<div class='detail-body'>$out</div></details>`n"
    }
    return "<h2>AD Health Check  -  $(HE $Data.Domain)</h2>$summary$sections"
}

function Build-StaleHTML {
    param([hashtable]$Data)
    $html = "<h2>Stale Account Report  -  Threshold: $($Data.ThresholdDays) days</h2>"

    $html += "<h3>Inactive Users ($($Data.InactiveUsers.Count))</h3>"
    $html += "<table><thead><tr><th>Name</th><th>SAM</th><th>Last Logon</th><th>OU</th></tr></thead><tbody>"
    foreach ($u in $Data.InactiveUsers) {
        $html += "<tr><td>$(HE $u.Name)</td><td>$(HE $u.SAM)</td><td>$(HE $u.LastLogon)</td><td>$(HE $u.OU)</td></tr>`n"
    }
    $html += "</tbody></table>"

    $html += "<h3>Inactive Computers ($($Data.InactiveComputers.Count))</h3>"
    $html += "<table><thead><tr><th>Name</th><th>OS</th><th>Last Logon</th><th>OU</th></tr></thead><tbody>"
    foreach ($c in $Data.InactiveComputers) {
        $html += "<tr><td>$(HE $c.Name)</td><td>$(HE $c.OS)</td><td>$(HE $c.LastLogon)</td><td>$(HE $c.OU)</td></tr>`n"
    }
    $html += "</tbody></table>"

    $html += "<h3>Disabled Accounts with Group Memberships ($($Data.DisabledWithGroups.Count))</h3>"
    $html += "<table><thead><tr><th>Name</th><th>SAM</th><th>Groups</th></tr></thead><tbody>"
    foreach ($u in $Data.DisabledWithGroups) {
        $html += "<tr class='warn'><td>$(HE $u.Name)</td><td>$(HE $u.SAM)</td><td>$(HE $u.Groups)</td></tr>`n"
    }
    $html += "</tbody></table>"
    return $html
}

function Build-PasswordHTML {
    param([hashtable]$Data)
    $html = "<h2>Password Expiry Dashboard  -  Next $($Data.LookAheadDays) Days</h2>"

    $html += "<h3>Expiring Soon ($($Data.ExpiringSoon.Count))</h3>"
    $html += "<table><thead><tr><th>Name</th><th>SAM</th><th>Expires</th><th>Days Left</th></tr></thead><tbody>"
    foreach ($u in $Data.ExpiringSoon) {
        $css = if ([int]$u.DaysLeft -le 3) { "danger" } elseif ([int]$u.DaysLeft -le 7) { "warn" } else { "" }
        $html += "<tr class='$css'><td>$(HE $u.Name)</td><td>$(HE $u.SAM)</td><td>$(HE $u.Expiry)</td><td>$(HE $u.DaysLeft)</td></tr>`n"
    }
    $html += "</tbody></table>"

    $html += "<h3>Already Expired ($($Data.AlreadyExpired.Count))</h3>"
    $html += "<table><thead><tr><th>Name</th><th>SAM</th><th>Expired On</th></tr></thead><tbody>"
    foreach ($u in $Data.AlreadyExpired) {
        $html += "<tr class='danger'><td>$(HE $u.Name)</td><td>$(HE $u.SAM)</td><td>$(HE $u.Expiry)</td></tr>`n"
    }
    $html += "</tbody></table>"

    $html += "<h3>Password Never Expires ($($Data.NeverExpires.Count))</h3>"
    $html += "<table><thead><tr><th>Name</th><th>SAM</th><th>Last Set</th></tr></thead><tbody>"
    foreach ($u in $Data.NeverExpires) {
        $html += "<tr><td>$(HE $u.Name)</td><td>$(HE $u.SAM)</td><td>$(HE $u.LastSet)</td></tr>`n"
    }
    $html += "</tbody></table>"
    return $html
}

function Build-ComputerHTML {
    param([hashtable]$Data)
    $rows = ""
    foreach ($k in $Data.Keys) {
        $rows += "<tr><td><strong>$(HE $k)</strong></td><td>$(HE ([string]$Data[$k]))</td></tr>`n"
    }
    return "<h2>Computer Details</h2><table><thead><tr><th>Field</th><th>Value</th></tr></thead><tbody>$rows</tbody></table>"
}

function Build-GroupInfoHTML {
    param([hashtable]$Data)
    $rows = ""
    foreach ($m in $Data.Members) {
        $css = if ($m.Enabled -eq $false) { "warn" } else { "" }
        $rows += "<tr class='$css'><td>$(HE $m.Name)</td><td>$(HE $m.SAM)</td>" +
                 "<td>$(HE $m.Type)</td><td>$(HE ([string]$m.Enabled))</td><td>$(HE $m.LastLogon)</td></tr>`n"
    }
    return "<h2>Group: $(HE $Data.GroupName) ($($Data.Members.Count) members)</h2>" +
           "<table><thead><tr><th>Display Name</th><th>SAM</th><th>Type</th><th>Enabled</th><th>Last Logon</th></tr></thead>" +
           "<tbody>$rows</tbody></table>"
}

function Build-GroupCompHTML {
    param([hashtable]$Data)
    $html = "<h2>Group Comparison: $(HE $Data.Group1Name) vs $(HE $Data.Group2Name)</h2>"

    $html += "<h3>In $(HE $Data.Group1Name) Only ($($Data.OnlyInGroup1.Count))</h3>"
    $html += "<table><thead><tr><th>Name</th><th>SAM</th></tr></thead><tbody>"
    foreach ($m in $Data.OnlyInGroup1) {
        $html += "<tr class='diff'><td class='val1'>$(HE $m.Name)</td><td class='val1'>$(HE $m.SAM)</td></tr>`n"
    }
    $html += "</tbody></table>"

    $html += "<h3>In $(HE $Data.Group2Name) Only ($($Data.OnlyInGroup2.Count))</h3>"
    $html += "<table><thead><tr><th>Name</th><th>SAM</th></tr></thead><tbody>"
    foreach ($m in $Data.OnlyInGroup2) {
        $html += "<tr class='diff'><td class='val2'>$(HE $m.Name)</td><td class='val2'>$(HE $m.SAM)</td></tr>`n"
    }
    $html += "</tbody></table>"

    $html += "<h3>In Both ($($Data.InBoth.Count))</h3>"
    $html += "<table><thead><tr><th>Name</th><th>SAM</th></tr></thead><tbody>"
    foreach ($m in $Data.InBoth) {
        $html += "<tr><td>$(HE $m.Name)</td><td>$(HE $m.SAM)</td></tr>`n"
    }
    $html += "</tbody></table>"
    return $html
}

function Build-PrivHTML {
    param([hashtable]$Data)
    $html = "<h2>Privileged Access Audit</h2>"
    foreach ($group in $Data.Groups) {
        $html += "<h3>$(HE $group.Name) ($($group.Members.Count) members)</h3>"
        $html += "<table><thead><tr><th>Name</th><th>SAM</th><th>Enabled</th><th>Last Logon</th><th>PW Last Set</th><th>Flag</th></tr></thead><tbody>"
        foreach ($m in $group.Members) {
            $flag = ""; $css = ""
            if ($m.Enabled -eq $false) { $flag = "<span class='badge badge-fail'>Disabled</span>"; $css = "danger" }
            elseif ($m.StaleFlag)      { $flag = "<span class='badge badge-warn'>Inactive 90d+</span>"; $css = "warn" }
            $html += "<tr class='$css'><td>$(HE $m.Name)</td><td>$(HE $m.SAM)</td>" +
                     "<td>$(HE ([string]$m.Enabled))</td><td>$(HE $m.LastLogon)</td>" +
                     "<td>$(HE $m.PwLastSet)</td><td>$flag</td></tr>`n"
        }
        $html += "</tbody></table>"
    }
    return $html
}

function Build-RadiusHTML {
    param([hashtable]$Data)
    $npsServers = $Data.Findings | Where-Object { $_.NPSInstalled }
    $unreachable = $Data.Findings | Where-Object { -not $_.Reachable }

    $html = "<h2>RADIUS / NPS Audit</h2>"
    $html += "<h3>Servers with NPS (RADIUS) Role Installed ($($npsServers.Count))</h3>"
    $html += "<table><thead><tr><th>Server</th><th>Service Status</th><th>RADIUS Clients</th><th>AD-Integrated</th></tr></thead><tbody>"
    foreach ($f in $npsServers) {
        $clients = ($f.RadiusClients | ForEach-Object { "$($_.Name) ($($_.Address))" }) -join ", "
        $html += "<tr><td>$(HE $f.Server)</td><td>$(HE $f.ServiceStatus)</td><td>$(HE $clients)</td><td>Yes</td></tr>`n"
    }
    $html += "</tbody></table>"

    if ($unreachable.Count -gt 0) {
        $html += "<h3>Unreachable Servers ($($unreachable.Count))</h3>"
        $html += "<table><thead><tr><th>Server</th><th>Error</th></tr></thead><tbody>"
        foreach ($f in $unreachable) {
            $html += "<tr class='warn'><td>$(HE $f.Server)</td><td>$(HE $f.Error)</td></tr>`n"
        }
        $html += "</tbody></table>"
    }
    return $html
}
