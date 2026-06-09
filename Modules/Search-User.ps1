# Modules/Search-User.ps1
# Written by Dallas Milem

function Invoke-UserSearch {
    $query = Read-Host "`nEnter username (SAM, UPN, or Display Name)"
    if ([string]::IsNullOrWhiteSpace($query)) {
        Write-Host "[ERROR] No input provided." -ForegroundColor Red
        return
    }

    $source = Get-ADSource
    Write-Host "`nSearching $source for '$query'..." -ForegroundColor Cyan

    $userData = $null
    switch ($source) {
        "LocalAD" { $userData = Search-LocalADUser -Query $query }
        "Entra"   { $userData = Search-EntraUser   -Query $query }
    }

    if ($null -eq $userData) {
        Write-Host "[NOT FOUND] No user matching '$query'." -ForegroundColor Yellow
        return
    }

    Show-UserTable -Data $userData
    Prompt-HTMLExport -Data $userData -ReportType "SearchResult" -Username $userData["SAM Account Name"]
}

function Search-LocalADUser {
    param([string]$Query)
    try {
        $props = @(
            "DisplayName","SamAccountName","UserPrincipalName","EmailAddress",
            "Department","Title","Manager","Enabled","LastLogonDate",
            "PasswordLastSet","PasswordNeverExpires","PasswordExpired",
            "LockedOut","MemberOf","DistinguishedName","LogonHours","AccountExpirationDate"
        )
        $user = Get-ADUser -Filter {
            SamAccountName -eq $Query -or UserPrincipalName -eq $Query -or DisplayName -eq $Query
        } -Properties $props -ErrorAction Stop | Select-Object -First 1

        if ($null -eq $user) { return $null }

        $managerName = "N/A"
        if ($user.Manager) {
            try { $managerName = (Get-ADUser $user.Manager).DisplayName } catch {}
        }

        $groups = @()
        if ($user.MemberOf) {
            $groups = $user.MemberOf | ForEach-Object {
                try { (Get-ADGroup $_).Name } catch { $_ }
            }
        }

        $pwExpiry = "N/A"
        if ($user.PasswordLastSet -and -not $user.PasswordNeverExpires) {
            try {
                $policy = Get-ADDefaultDomainPasswordPolicy
                if ($policy.MaxPasswordAge.TotalDays -gt 0) {
                    $pwExpiry = $user.PasswordLastSet.AddDays($policy.MaxPasswordAge.TotalDays).ToString("yyyy-MM-dd HH:mm")
                }
            } catch {}
        } elseif ($user.PasswordNeverExpires) {
            $pwExpiry = "Never Expires"
        }

        $logonHours = "Not Restricted"
        $unrestricted = [byte[]]@(255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255)
        if ($user.LogonHours -and (Compare-Object $user.LogonHours $unrestricted)) {
            $logonHours = "Custom Schedule Set"
        }

        return [ordered]@{
            "Display Name"       = $user.DisplayName
            "SAM Account Name"   = $user.SamAccountName
            "UPN"                = $user.UserPrincipalName
            "Email"              = $user.EmailAddress
            "Department"         = $user.Department
            "Title"              = $user.Title
            "Manager"            = $managerName
            "Account Enabled"    = $user.Enabled
            "Locked Out"         = $user.LockedOut
            "Last Logon"         = if ($user.LastLogonDate) { $user.LastLogonDate.ToString("yyyy-MM-dd HH:mm") } else { "Never" }
            "Password Last Set"  = if ($user.PasswordLastSet) { $user.PasswordLastSet.ToString("yyyy-MM-dd HH:mm") } else { "N/A" }
            "Password Expiry"    = $pwExpiry
            "Logon Hours"        = $logonHours
            "Group Memberships"  = if ($groups.Count -gt 0) { $groups -join ", " } else { "None" }
            "Distinguished Name" = $user.DistinguishedName
        }
    }
    catch {
        Write-Host "[ERROR] AD query failed: $_" -ForegroundColor Red
        return $null
    }
}

function Search-EntraUser {
    param([string]$Query)
    try {
        Import-Module Microsoft.Graph.Users  -ErrorAction SilentlyContinue
        Import-Module Microsoft.Graph.Groups -ErrorAction SilentlyContinue

        $filter      = "displayName eq '$Query' or userPrincipalName eq '$Query' or onPremisesSamAccountName eq '$Query'"
        $selectProps = "id,displayName,userPrincipalName,onPremisesSamAccountName,mail,department,jobTitle,accountEnabled,lastPasswordChangeDateTime,signInActivity,onPremisesDistinguishedName"
        $user = Get-MgUser -Filter $filter -Property $selectProps -Top 1 -ErrorAction Stop | Select-Object -First 1

        if ($null -eq $user) { return $null }

        $managerName = "N/A"
        try {
            $mgr = Get-MgUserManager -UserId $user.Id -ErrorAction SilentlyContinue
            if ($mgr) { $managerName = $mgr.AdditionalProperties["displayName"] }
        } catch {}

        $groups = @()
        try {
            $groups = (Get-MgUserMemberOf -UserId $user.Id -ErrorAction SilentlyContinue) |
                Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' } |
                ForEach-Object { $_.AdditionalProperties["displayName"] }
        } catch {}

        $lastLogon = "N/A"
        if ($user.SignInActivity) {
            $lastLogon = $user.SignInActivity.LastSignInDateTime
        }

        return [ordered]@{
            "Display Name"       = $user.DisplayName
            "SAM Account Name"   = $user.OnPremisesSamAccountName
            "UPN"                = $user.UserPrincipalName
            "Email"              = $user.Mail
            "Department"         = $user.Department
            "Title"              = $user.JobTitle
            "Manager"            = $managerName
            "Account Enabled"    = $user.AccountEnabled
            "Last Logon"         = $lastLogon
            "Password Last Set"  = $user.LastPasswordChangeDateTime
            "Group Memberships"  = if ($groups.Count -gt 0) { $groups -join ", " } else { "None" }
            "Distinguished Name" = $user.OnPremisesDistinguishedName
        }
    }
    catch {
        Write-Host "[ERROR] Entra query failed: $_" -ForegroundColor Red
        return $null
    }
}

function Show-UserTable {
    param([System.Collections.Specialized.OrderedDictionary]$Data)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    Write-Host " USER DETAILS" -ForegroundColor White
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    foreach ($key in $Data.Keys) {
        $val = if ($null -eq $Data[$key]) { "N/A" } else { $Data[$key].ToString() }
        Write-Host ("  {0,-25} {1}" -f "$key :", $val)
    }
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    Write-Host ""
}

function Prompt-HTMLExport {
    param(
        [System.Collections.Specialized.OrderedDictionary]$Data,
        [string]$ReportType,
        [string]$Username
    )
    $choice = Read-Host "Export to HTML report? [Y/N]"
    if ($choice -match "^[Yy]") {
        $path = Export-HTMLReport -Data $Data -ReportType $ReportType -Username $Username -Source (Get-ADSource)
        Write-Host "[OK] Report saved: $path" -ForegroundColor Green
    }
}
