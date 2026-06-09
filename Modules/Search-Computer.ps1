# Modules/Search-Computer.ps1
# Written by Dallas Milem

function Invoke-ComputerSearch {
    $query = Read-Host "`nEnter computer name (partial match supported)"
    if ([string]::IsNullOrWhiteSpace($query)) {
        Write-Host "[ERROR] No input provided." -ForegroundColor Red
        return
    }

    Write-Host "`nSearching for computers matching '$query'..." -ForegroundColor Cyan

    try {
        $props = @("Name","OperatingSystem","OperatingSystemVersion","LastLogonDate",
                   "Enabled","DistinguishedName","Description","IPv4Address","DNSHostName")

        $computers = Get-ADComputer -Filter { Name -like "*" } -Properties $props |
            Where-Object { $_.Name -like "*$query*" } | Select-Object -First 10

        if ($computers.Count -eq 0) {
            Write-Host "[NOT FOUND] No computers matching '$query'." -ForegroundColor Yellow
            return
        }

        if ($computers.Count -gt 1) {
            Write-Host "`n  Multiple matches found:" -ForegroundColor Yellow
            $i = 1
            foreach ($c in $computers) {
                Write-Host ("  [{0}] {1} — {2}" -f $i, $c.Name, $c.OperatingSystem)
                $i++
            }
            $sel = Read-Host "`n  Select number"
            $computer = $computers[[int]$sel - 1]
        } else {
            $computer = $computers[0]
        }

        $pingStatus = "Unreachable"
        try {
            if (Test-Connection -ComputerName $computer.DNSHostName -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                $pingStatus = "Online"
            }
        } catch {}

        $data = [ordered]@{
            "Name"              = $computer.Name
            "DNS Host Name"     = $computer.DNSHostName
            "Operating System"  = $computer.OperatingSystem
            "OS Version"        = $computer.OperatingSystemVersion
            "IPv4 Address"      = $computer.IPv4Address
            "Ping Status"       = $pingStatus
            "Account Enabled"   = $computer.Enabled
            "Last Logon"        = if ($computer.LastLogonDate) { $computer.LastLogonDate.ToString("yyyy-MM-dd HH:mm") } else { "Never" }
            "Description"       = $computer.Description
            "Distinguished Name"= $computer.DistinguishedName
        }

        # BitLocker key retrieval
        $bitlockerKey = Get-BitLockerKeyFromAD -ComputerName $computer.Name
        if ($bitlockerKey) {
            $showKey = Read-Host "`n  BitLocker recovery key found in AD. Display it? [Y/N]"
            if ($showKey -match "^[Yy]") {
                $data["BitLocker Key"] = $bitlockerKey
            } else {
                $data["BitLocker Key"] = "[Key retrieved — display declined]"
            }
        }

        Show-ComputerTable -Data $data

        $exportData = $data
        $choice = Read-Host "Export to HTML report? [Y/N]"
        if ($choice -match "^[Yy]") {
            $path = Export-HTMLReport -Data $exportData -ReportType "ComputerSearch" -Username $computer.Name -Source "LocalAD"
            Write-Host "[OK] Report saved: $path" -ForegroundColor Green
        }

    } catch {
        Write-Host "[ERROR] Computer search failed: $_" -ForegroundColor Red
    }
}

function Get-BitLockerKeyFromAD {
    param([string]$ComputerName)
    try {
        $bitlockerModule = Get-Module -ListAvailable -Name BitLocker
        if (-not $bitlockerModule) { return $null }
        Import-Module BitLocker -ErrorAction Stop

        $computerObj = Get-ADComputer -Identity $ComputerName -ErrorAction Stop
        $keyObj = Get-ADObject -Filter { objectClass -eq 'msFVE-RecoveryInformation' } `
            -SearchBase $computerObj.DistinguishedName `
            -Properties 'msFVE-RecoveryPassword' -ErrorAction Stop | Select-Object -First 1

        if ($keyObj) {
            return $keyObj.'msFVE-RecoveryPassword'
        }
        return $null
    } catch {
        return $null
    }
}

function Show-ComputerTable {
    param([System.Collections.Specialized.OrderedDictionary]$Data)
    $line = "=" * 70
    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host " COMPUTER DETAILS" -ForegroundColor White
    Write-Host $line -ForegroundColor DarkCyan
    foreach ($key in $Data.Keys) {
        $val   = if ($null -eq $Data[$key]) { "N/A" } else { $Data[$key].ToString() }
        $color = if ($key -eq "Ping Status" -and $val -eq "Online") { "Green" } `
                 elseif ($key -eq "Ping Status") { "Red" } else { "White" }
        Write-Host ("  {0,-25} " -f "$key :") -NoNewline
        Write-Host $val -ForegroundColor $color
    }
    Write-Host "$line`n" -ForegroundColor DarkCyan
}
