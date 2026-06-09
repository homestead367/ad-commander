# Modules/Connect-Source.ps1
# Written by Dallas Milem

$script:ADSource = $null

function Connect-LocalAD {
    Write-Host "`nChecking ActiveDirectory module..." -ForegroundColor Cyan

    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Host "[ERROR] ActiveDirectory module not found." -ForegroundColor Red
        Write-Host "Install RSAT: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0" -ForegroundColor Yellow
        return $false
    }

    Import-Module ActiveDirectory -ErrorAction SilentlyContinue

    Write-Host "Testing domain controller connectivity..." -ForegroundColor Cyan
    try {
        $dc = Get-ADDomainController -Discover -ErrorAction Stop
        Write-Host "[OK] Connected to domain: $($dc.Domain) via $($dc.HostName)" -ForegroundColor Green
        $script:ADSource = "LocalAD"
        return $true
    }
    catch {
        Write-Host "[ERROR] Cannot reach a domain controller: $_" -ForegroundColor Red
        return $false
    }
}

function Connect-EntraID {
    Write-Host "`nChecking Microsoft.Graph module..." -ForegroundColor Cyan

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Host "[ERROR] Microsoft.Graph module not found." -ForegroundColor Red
        Write-Host "Install it: Install-Module Microsoft.Graph -Scope CurrentUser" -ForegroundColor Yellow
        return $false
    }

    Write-Host ""
    Write-Host "Select authentication method:" -ForegroundColor Cyan
    Write-Host "  [I] Interactive browser login (MFA supported)"
    Write-Host "  [S] Service Principal (Client ID + Secret)"
    Write-Host ""
    $authChoice = Read-Host "Choice"

    try {
        switch ($authChoice.ToUpper()) {
            "I" {
                Write-Host "Opening browser for authentication..." -ForegroundColor Cyan
                Connect-MgGraph -Scopes "User.Read.All","GroupMember.Read.All","Policy.Read.All" -ErrorAction Stop | Out-Null
            }
            "S" {
                $tenantId     = Read-Host "Tenant ID"
                $clientId     = Read-Host "Client ID"
                $clientSecret = Read-Host "Client Secret" -AsSecureString
                $credential   = New-Object System.Management.Automation.PSCredential($clientId, $clientSecret)
                Connect-MgGraph -TenantId $tenantId -ClientSecretCredential $credential -ErrorAction Stop | Out-Null
            }
            default {
                Write-Host "[ERROR] Invalid choice." -ForegroundColor Red
                return $false
            }
        }

        $ctx = Get-MgContext
        Write-Host "[OK] Connected to Entra tenant: $($ctx.TenantId)" -ForegroundColor Green
        $script:ADSource = "Entra"
        return $true
    }
    catch {
        Write-Host "[ERROR] Entra authentication failed: $_" -ForegroundColor Red
        return $false
    }
}

function Get-ADSource {
    return $script:ADSource
}
