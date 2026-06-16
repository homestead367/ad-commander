# Modules/Install-Requirements.ps1
# Written by Dallas Milem

function Install-ADCommanderRequirements {
    Write-Host ""
    Write-Host "  Checking required PowerShell modules..." -ForegroundColor Cyan
    Write-Host ""

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")

    # -- ActiveDirectory (RSAT) ------------------------------------------------
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Host "  [MISSING] ActiveDirectory module (RSAT)" -ForegroundColor Yellow
        Write-Host "  Required for: all Local AD features" -ForegroundColor Gray
        $cmd = "Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0"
        Write-Host "  Install command: $cmd" -ForegroundColor Gray
        if ($isAdmin) {
            $choice = Read-Host "  Install now? [Y/N]"
            if ($choice -match "^[Yy]") {
                try {
                    Add-WindowsCapability -Online -Name "Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0" -ErrorAction Stop | Out-Null
                    Write-Host "  [OK] ActiveDirectory module installed." -ForegroundColor Green
                } catch {
                    Write-Host "  [ERROR] Install failed: $_" -ForegroundColor Red
                }
            }
        } else {
            Write-Host "  [INFO] Run as Administrator to auto-install." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [OK] ActiveDirectory module" -ForegroundColor Green
    }

    # -- GroupPolicy (RSAT) ----------------------------------------------------
    if (-not (Get-Module -ListAvailable -Name GroupPolicy)) {
        Write-Host "  [MISSING] GroupPolicy module (RSAT)" -ForegroundColor Yellow
        Write-Host "  Required for: GPO reports, AD Health Check" -ForegroundColor Gray
        $cmd = "Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0"
        Write-Host "  Install command: $cmd" -ForegroundColor Gray
        if ($isAdmin) {
            $choice = Read-Host "  Install now? [Y/N]"
            if ($choice -match "^[Yy]") {
                try {
                    Add-WindowsCapability -Online -Name "Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0" -ErrorAction Stop | Out-Null
                    Write-Host "  [OK] GroupPolicy module installed." -ForegroundColor Green
                } catch {
                    Write-Host "  [ERROR] Install failed: $_" -ForegroundColor Red
                }
            }
        } else {
            Write-Host "  [INFO] Run as Administrator to auto-install." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [OK] GroupPolicy module" -ForegroundColor Green
    }

    # -- Microsoft.Graph -------------------------------------------------------
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Host "  [MISSING] Microsoft.Graph module" -ForegroundColor Yellow
        Write-Host "  Required for: Entra ID features" -ForegroundColor Gray
        Write-Host "  Install command: Install-Module Microsoft.Graph -Scope CurrentUser -Force" -ForegroundColor Gray
        $choice = Read-Host "  Install now? [Y/N]"
        if ($choice -match "^[Yy]") {
            try {
                Write-Host "  Installing Microsoft.Graph (this may take a moment)..." -ForegroundColor Cyan
                Install-Module Microsoft.Graph -Scope CurrentUser -Force -ErrorAction Stop
                Write-Host "  [OK] Microsoft.Graph installed." -ForegroundColor Green
            } catch {
                Write-Host "  [ERROR] Install failed: $_" -ForegroundColor Red
            }
        }
    } else {
        Write-Host "  [OK] Microsoft.Graph module" -ForegroundColor Green
    }

    # -- BitLocker (built-in, non-fatal) ---------------------------------------
    try {
        Import-Module BitLocker -ErrorAction Stop
        Write-Host "  [OK] BitLocker module" -ForegroundColor Green
    } catch {
        Write-Host "  [INFO] BitLocker module unavailable  -  BitLocker key retrieval disabled." -ForegroundColor DarkYellow
    }

    Write-Host ""
}
