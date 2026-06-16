#Requires -Version 5.1
<#
.SYNOPSIS
    ADCommander  -  Unified Active Directory & Entra ID Administration Toolkit
.DESCRIPTION
    All-in-one AD admin tool: user search, computer search, group management,
    domain health checks, GPO reporting, stale accounts, password expiry,
    privileged access auditing, and account actions.
    Written by Dallas Milem
.NOTES
    Version: 1.0
    Author:  Dallas Milem
#>

# Unblock all module files so Windows doesn't prompt per-file when the script
# is run after being extracted from a downloaded ZIP archive
$modulePath = Join-Path $PSScriptRoot "Modules"
Get-ChildItem -Path $modulePath -Filter "*.ps1" | Unblock-File -ErrorAction SilentlyContinue
Unblock-File -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue

# Load all modules at script scope so their functions are immediately available
. (Join-Path $modulePath "Install-Requirements.ps1")
. (Join-Path $modulePath "Connect-Source.ps1")
. (Join-Path $modulePath "Export-HTML.ps1")
. (Join-Path $modulePath "Search-User.ps1")
. (Join-Path $modulePath "Compare-Users.ps1")
. (Join-Path $modulePath "Get-UserGPO.ps1")
. (Join-Path $modulePath "Search-Computer.ps1")
. (Join-Path $modulePath "Invoke-HealthCheck.ps1")
. (Join-Path $modulePath "Get-StaleAccounts.ps1")
. (Join-Path $modulePath "Get-PasswordExpiry.ps1")
. (Join-Path $modulePath "Get-PrivilegedAccess.ps1")
. (Join-Path $modulePath "Get-GroupInfo.ps1")
. (Join-Path $modulePath "Invoke-AccountActions.ps1")
. (Join-Path $modulePath "Get-RadiusInfo.ps1")

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  +================================================================+" -ForegroundColor Cyan
    Write-Host "  |            ADCommander  v1.0                                   |" -ForegroundColor Cyan
    Write-Host "  |       Written by Dallas Milem                                  |" -ForegroundColor Cyan
    Write-Host "  |  Unified AD & Entra Administration Toolkit                     |" -ForegroundColor Cyan
    Write-Host "  +================================================================+" -ForegroundColor Cyan
    Write-Host ""
}

function Confirm-RunAsCurrentUser {
    $currentUser = "$env:USERDOMAIN\$env:USERNAME"
    Write-Host "  Detected current user: " -NoNewline
    Write-Host $currentUser -ForegroundColor Yellow
    Write-Host ""

    $deadline       = (Get-Date).AddSeconds(30)
    $answered       = $false
    $useCurrentUser = $true

    while ((Get-Date) -lt $deadline -and -not $answered) {
        $remaining = [math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
        Write-Host "`r  Run as current user? [Y/N]  (auto-yes in ${remaining}s)  " -NoNewline
        if ($Host.UI.RawUI.KeyAvailable) {
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            if ($key.Character -in @('Y','y'))     { $useCurrentUser = $true;  $answered = $true }
            elseif ($key.Character -in @('N','n')) { $useCurrentUser = $false; $answered = $true }
        }
        Start-Sleep -Milliseconds 200
    }
    Write-Host ""

    if ($useCurrentUser) {
        Write-Host "  Connecting as $currentUser..." -ForegroundColor Cyan
        if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
            Write-Host "  [ERROR] ActiveDirectory module not found." -ForegroundColor Red
            Write-Host "  Install RSAT: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0" -ForegroundColor Yellow
            return $false
        }
        Import-Module ActiveDirectory -ErrorAction SilentlyContinue
        try {
            $dc = Get-ADDomainController -Discover -ErrorAction Stop
            Write-Host "  [OK] Connected to domain: $($dc.Domain) via $($dc.HostName)" -ForegroundColor Green
            $script:ADSource = "LocalAD"
            return $true
        } catch {
            Write-Host "  [ERROR] Cannot reach a domain controller: $_" -ForegroundColor Red
            Write-Host "  Falling through to manual source selection..." -ForegroundColor Yellow
            return $false
        }
    }
    return $false
}

function Select-Source {
    Write-Host "  Select data source:" -ForegroundColor White
    Write-Host "    [L]  Local AD Domain Controller"
    Write-Host "    [E]  Entra ID (Azure AD)"
    Write-Host ""
    $choice = Read-Host "  Choice"
    switch ($choice.ToUpper()) {
        "L" { return Connect-LocalAD }
        "E" { return Connect-EntraID }
        default {
            Write-Host "  [ERROR] Invalid choice. Enter L or E." -ForegroundColor Red
            return $false
        }
    }
}

function Show-Menu {
    $source = Get-ADSource
    $isLocal = $source -eq "LocalAD"
    $srcColor = if ($source) { "Green" } else { "Red" }
    $na = if (-not $isLocal) { " (unavailable)" } else { "" }

    Write-Host ""
    Write-Host "  ------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ("  Active Source: {0}" -f $(if ($source) { $source } else { "None" })) -ForegroundColor $srcColor
    Write-Host "  ------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  -- USER MANAGEMENT --" -ForegroundColor DarkCyan
    Write-Host "    [1]   Search User"
    Write-Host "    [2]   Compare Two Users"
    Write-Host "    [3]   Get GPO Attributes" -NoNewline
    if (-not $isLocal) { Write-Host "  (Local AD only)" -ForegroundColor DarkGray } else { Write-Host "" }
    Write-Host ""
    Write-Host "  -- COMPUTER MANAGEMENT --" -ForegroundColor DarkCyan
    Write-Host "    [4]   Search Computer" -NoNewline
    if (-not $isLocal) { Write-Host "  (Local AD only)" -ForegroundColor DarkGray } else { Write-Host "" }
    Write-Host ""
    Write-Host "  -- DOMAIN HEALTH --" -ForegroundColor DarkCyan
    Write-Host "    [5]   AD Health Check" -NoNewline
    if (-not $isLocal) { Write-Host "  (Local AD only)" -ForegroundColor DarkGray } else { Write-Host "" }
    Write-Host "    [6]   Stale Account Report" -NoNewline
    if (-not $isLocal) { Write-Host "  (Local AD only)" -ForegroundColor DarkGray } else { Write-Host "" }
    Write-Host "    [7]   Password Expiry Dashboard" -NoNewline
    if (-not $isLocal) { Write-Host "  (Local AD only)" -ForegroundColor DarkGray } else { Write-Host "" }
    Write-Host "    [8]   Privileged Access Audit" -NoNewline
    if (-not $isLocal) { Write-Host "  (Local AD only)" -ForegroundColor DarkGray } else { Write-Host "" }
    Write-Host ""
    Write-Host "  -- GROUP MANAGEMENT --" -ForegroundColor DarkCyan
    Write-Host "    [9]   Search Group / List Members"
    Write-Host "    [10]  Compare Two Groups"
    Write-Host ""
    Write-Host "  -- ACCOUNT ACTIONS --" -ForegroundColor DarkCyan
    Write-Host "    [11]  Unlock Account" -NoNewline
    if (-not $isLocal) { Write-Host "  (Local AD only)" -ForegroundColor DarkGray } else { Write-Host "" }
    Write-Host "    [12]  Force Password Reset" -NoNewline
    if (-not $isLocal) { Write-Host "  (Local AD only)" -ForegroundColor DarkGray } else { Write-Host "" }
    Write-Host ""
    Write-Host "  -- AUTHENTICATION INFRASTRUCTURE --" -ForegroundColor DarkCyan
    Write-Host "    [15]  RADIUS / NPS Audit" -NoNewline
    if (-not $isLocal) { Write-Host "  (Local AD only)" -ForegroundColor DarkGray } else { Write-Host "" }
    Write-Host ""
    Write-Host "  -- SYSTEM --" -ForegroundColor DarkCyan
    Write-Host "    [13]  Change Source"
    Write-Host "    [14]  Exit"
    Write-Host ""
}

function Assert-LocalAD {
    if ((Get-ADSource) -ne "LocalAD") {
        Write-Host "  [INFO] This feature requires Local AD. Use [13] to change source." -ForegroundColor Yellow
        return $false
    }
    return $true
}

# -- Main ----------------------------------------------------------------------
Show-Banner
Install-ADCommanderRequirements

$connected = Confirm-RunAsCurrentUser
if (-not $connected) {
    Write-Host ""
    while (-not $connected) {
        $connected = Select-Source
        if (-not $connected) {
            Write-Host "  Connection failed. Try again." -ForegroundColor Yellow
            Write-Host ""
        }
    }
}

$running = $true
while ($running) {
    Show-Menu
    $choice = Read-Host "  Select option"

    switch ($choice.Trim()) {
        "1"  { Invoke-UserSearch }
        "2"  { Invoke-UserComparison }
        "3"  { if (Assert-LocalAD) { Invoke-UserGPOReport } }
        "4"  { if (Assert-LocalAD) { Invoke-ComputerSearch } }
        "5"  { if (Assert-LocalAD) { Invoke-ADHealthCheck } }
        "6"  { if (Assert-LocalAD) { Invoke-StaleAccountReport } }
        "7"  { if (Assert-LocalAD) { Invoke-PasswordExpiryReport } }
        "8"  { if (Assert-LocalAD) { Invoke-PrivilegedAccessAudit } }
        "9"  { Invoke-GroupSearch }
        "10" { Invoke-GroupComparison }
        "11" { if (Assert-LocalAD) { Invoke-UnlockAccount } }
        "12" { if (Assert-LocalAD) { Invoke-ForcePasswordReset } }
        "15" { if (Assert-LocalAD) { Invoke-RadiusAudit } }
        "13" {
            Show-Banner
            Install-ADCommanderRequirements
            $connected = $false
            while (-not $connected) {
                $connected = Select-Source
                if (-not $connected) {
                    Write-Host "  Connection failed. Try again." -ForegroundColor Yellow
                    Write-Host ""
                }
            }
        }
        "14" {
            Write-Host "`n  Goodbye.`n" -ForegroundColor Cyan
            $running = $false
        }
        default { Write-Host "  [ERROR] Invalid option. Enter 1-15." -ForegroundColor Red }
    }
}
