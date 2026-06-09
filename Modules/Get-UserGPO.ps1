# Modules/Get-UserGPO.ps1
# Written by Dallas Milem

function Invoke-UserGPOReport {
    $username = Read-Host "`nEnter username for GPO report (SAM account name)"
    if ([string]::IsNullOrWhiteSpace($username)) {
        Write-Host "[ERROR] No username provided." -ForegroundColor Red
        return
    }

    Write-Host "`nPulling GPO Resultant Set for '$username'..." -ForegroundColor Cyan

    $gpoData = $null

    # Try GPMC module first
    if (Get-Module -ListAvailable -Name GroupPolicy) {
        $gpoData = Get-GPOResultantSet -Username $username
    }

    # Fall back to gpresult
    if ($null -eq $gpoData) {
        Write-Host "[INFO] GPMC module unavailable, falling back to gpresult..." -ForegroundColor Yellow
        $gpoData = Get-GPResultFallback -Username $username
    }

    if ($null -eq $gpoData) {
        Write-Host "[ERROR] Could not retrieve GPO data. Ensure this machine is domain-joined and RSAT is installed." -ForegroundColor Red
        return
    }

    Show-GPOTable -Data $gpoData
    Prompt-GPOHTMLExport -Data $gpoData -Username $username
}

function Get-GPOResultantSet {
    param([string]$Username)
    try {
        Import-Module GroupPolicy -ErrorAction Stop

        $tempFile = [System.IO.Path]::GetTempFileName() + ".xml"
        $null = Get-GPResultantSetOfPolicy -User $Username -ReportType XML -Path $tempFile -ErrorAction Stop

        [xml]$rsop = Get-Content $tempFile -ErrorAction Stop
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

        $applied = @()
        $denied  = @()
        $order   = 1

        $gpoNodes = $rsop.SelectNodes("//GPO")
        foreach ($gpo in $gpoNodes) {
            $name  = $gpo.Name
            $scope = if ($gpo.ParentNode.LocalName -eq "UserResults") { "User" } else { "Computer" }
            $applied += [PSCustomObject]@{
                Order = $order++
                Name  = $name
                Scope = $scope
            }
        }

        $filteredNodes = $rsop.SelectNodes("//FilteredGPO")
        foreach ($fgpo in $filteredNodes) {
            $name   = $fgpo.Name
            $reason = $fgpo.FilterStatus
            $denied += [PSCustomObject]@{
                Name   = $name
                Scope  = "User"
                Reason = $reason
            }
        }

        $loopback = "None"
        $loopNode = $rsop.SelectSingleNode("//LoopbackMode")
        if ($loopNode) { $loopback = $loopNode.InnerText }

        return @{
            Username     = $Username
            AppliedGPOs  = $applied
            DeniedGPOs   = $denied
            LoopbackMode = $loopback
            Source       = "GPMC"
        }
    }
    catch {
        Write-Host "[WARN] GPMC method failed: $_" -ForegroundColor Yellow
        return $null
    }
}

function Get-GPResultFallback {
    param([string]$Username)
    try {
        $output = & gpresult /USER $Username /SCOPE USER /R 2>&1

        $applied   = @()
        $denied    = @()
        $inApplied = $false
        $inDenied  = $false
        $order     = 1

        foreach ($line in $output) {
            if ($line -match "Applied Group Policy Objects")         { $inApplied = $true;  $inDenied = $false; continue }
            if ($line -match "The following GPOs were not applied")  { $inDenied  = $true;  $inApplied = $false; continue }
            if ($line -match "^(COMPUTER SETTINGS|USER SETTINGS|Resultant Set)") { $inApplied = $false; $inDenied = $false }
            if ($line -match "^\s*$") { continue }

            if ($inApplied -and $line -match "^\s+(.+)$") {
                $name = $Matches[1].Trim()
                if ($name -ne "" -and $name -notmatch "^-+$") {
                    $applied += [PSCustomObject]@{ Order = $order++; Name = $name; Scope = "User" }
                }
            }

            if ($inDenied -and $line -match "^\s+(.+)$") {
                $name = $Matches[1].Trim()
                if ($name -ne "" -and $name -notmatch "^-+$") {
                    $denied += [PSCustomObject]@{ Name = $name; Scope = "User"; Reason = "Filtered" }
                }
            }
        }

        return @{
            Username     = $Username
            AppliedGPOs  = $applied
            DeniedGPOs   = $denied
            LoopbackMode = "None"
            Source       = "gpresult"
        }
    }
    catch {
        Write-Host "[ERROR] gpresult fallback failed: $_" -ForegroundColor Red
        return $null
    }
}

function Show-GPOTable {
    param([hashtable]$Data)
    $line = ("=" * 72)

    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host " GPO RESULTANT SET — $($Data.Username.ToUpper())  [via $($Data.Source)]" -ForegroundColor White
    Write-Host $line -ForegroundColor DarkCyan

    if ($Data.LoopbackMode -and $Data.LoopbackMode -ne "None") {
        Write-Host "  Loopback Mode: $($Data.LoopbackMode)" -ForegroundColor Magenta
        Write-Host ""
    }

    Write-Host "  APPLIED POLICIES" -ForegroundColor Green
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    if ($Data.AppliedGPOs.Count -eq 0) {
        Write-Host "  (none)" -ForegroundColor Gray
    } else {
        Write-Host ("  {0,-4} {1,-45} {2}" -f "#", "Policy Name", "Scope") -ForegroundColor Gray
        foreach ($gpo in $Data.AppliedGPOs) {
            Write-Host ("  {0,-4} {1,-45} {2}" -f $gpo.Order, $gpo.Name, $gpo.Scope)
        }
    }

    Write-Host ""
    Write-Host "  DENIED / FILTERED POLICIES" -ForegroundColor Red
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    if ($Data.DeniedGPOs.Count -eq 0) {
        Write-Host "  (none)" -ForegroundColor Gray
    } else {
        Write-Host ("  {0,-45} {1,-12} {2}" -f "Policy Name", "Scope", "Reason") -ForegroundColor Gray
        foreach ($gpo in $Data.DeniedGPOs) {
            Write-Host ("  {0,-45} {1,-12} {2}" -f $gpo.Name, $gpo.Scope, $gpo.Reason) -ForegroundColor Yellow
        }
    }

    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ""
}

function Prompt-GPOHTMLExport {
    param([hashtable]$Data, [string]$Username)
    $choice = Read-Host "Export to HTML report? [Y/N]"
    if ($choice -match "^[Yy]") {
        $path = Export-HTMLReport -Data $Data -ReportType "GPOReport" -Username $Username -Source "LocalAD"
        Write-Host "[OK] Report saved: $path" -ForegroundColor Green
    }
}
