# Modules/Invoke-AccountActions.ps1
# Written by Dallas Milem

function Invoke-UnlockAccount {
    $query = Read-Host "`nEnter username to unlock (SAM or Display Name)"
    if ([string]::IsNullOrWhiteSpace($query)) {
        Write-Host "[ERROR] No input provided." -ForegroundColor Red
        return
    }

    try {
        $users = Get-ADUser -Filter {
            SamAccountName -eq $query -or DisplayName -eq $query
        } -Properties DisplayName, SamAccountName, LockedOut, LastLogonDate, DistinguishedName |
            Where-Object { $_.LockedOut -eq $true }

        if ($users.Count -eq 0) {
            # Check if user exists but isn't locked
            $exists = Get-ADUser -Filter {
                SamAccountName -eq $query -or DisplayName -eq $query
            } -ErrorAction SilentlyContinue

            if ($exists) {
                Write-Host "[INFO] Account '$query' exists but is NOT currently locked out." -ForegroundColor Yellow
            } else {
                Write-Host "[NOT FOUND] No locked account matching '$query'." -ForegroundColor Yellow
            }
            return
        }

        $user = $users | Select-Object -First 1

        Write-Host ""
        Write-Host "  Account:     $($user.DisplayName) ($($user.SamAccountName))" -ForegroundColor Yellow
        Write-Host "  Status:      LOCKED OUT" -ForegroundColor Red
        Write-Host "  Last Logon:  $(if ($user.LastLogonDate) { $user.LastLogonDate.ToString('yyyy-MM-dd HH:mm') } else { 'Never' })"
        Write-Host "  DN:          $($user.DistinguishedName)"
        Write-Host ""

        $confirm = Read-Host "  Unlock this account? [Y/N]"
        if ($confirm -notmatch "^[Yy]") {
            Write-Host "  [CANCELLED] No changes made." -ForegroundColor Gray
            return
        }

        Unlock-ADAccount -Identity $user.SamAccountName -ErrorAction Stop
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Write-Host "  [OK] Account '$($user.SamAccountName)' unlocked at $ts by $env:USERNAME" -ForegroundColor Green

    } catch {
        Write-Host "[ERROR] Unlock failed: $_" -ForegroundColor Red
    }
}

function Invoke-ForcePasswordReset {
    $query = Read-Host "`nEnter username (SAM or Display Name)"
    if ([string]::IsNullOrWhiteSpace($query)) {
        Write-Host "[ERROR] No input provided." -ForegroundColor Red
        return
    }

    try {
        $user = Get-ADUser -Filter {
            SamAccountName -eq $query -or DisplayName -eq $query
        } -Properties DisplayName, SamAccountName, Enabled, LastLogonDate, DistinguishedName |
            Select-Object -First 1

        if ($null -eq $user) {
            Write-Host "[NOT FOUND] No account matching '$query'." -ForegroundColor Yellow
            return
        }

        Write-Host ""
        Write-Host "  Account:     $($user.DisplayName) ($($user.SamAccountName))" -ForegroundColor Yellow
        Write-Host "  Enabled:     $($user.Enabled)"
        Write-Host "  Last Logon:  $(if ($user.LastLogonDate) { $user.LastLogonDate.ToString('yyyy-MM-dd HH:mm') } else { 'Never' })"
        Write-Host ""
        Write-Host "  This will force the user to change their password at next logon." -ForegroundColor Yellow
        Write-Host ""

        $setTemp = Read-Host "  Set a temporary password now? [Y/N]"
        if ($setTemp -match "^[Yy]") {
            $tempPw = Read-Host "  Enter temporary password" -AsSecureString
            try {
                Set-ADAccountPassword -Identity $user.SamAccountName -NewPassword $tempPw -Reset -ErrorAction Stop
                Write-Host "  [OK] Temporary password set." -ForegroundColor Green
            } catch {
                Write-Host "  [ERROR] Could not set password: $_" -ForegroundColor Red
                return
            }
        }

        $confirm = Read-Host "  Force password change at next logon? [Y/N]"
        if ($confirm -notmatch "^[Yy]") {
            Write-Host "  [CANCELLED] No changes made." -ForegroundColor Gray
            return
        }

        Set-ADUser -Identity $user.SamAccountName -ChangePasswordAtLogon $true -ErrorAction Stop
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Write-Host "  [OK] '$($user.SamAccountName)' will be forced to change password at next logon. Action by $env:USERNAME at $ts" -ForegroundColor Green

    } catch {
        Write-Host "[ERROR] Password reset failed: $_" -ForegroundColor Red
    }
}
