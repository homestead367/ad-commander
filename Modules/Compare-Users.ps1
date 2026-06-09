# Modules/Compare-Users.ps1
# Written by Dallas Milem

function Invoke-UserComparison {
    $query1 = Read-Host "`nEnter first username (SAM, UPN, or Display Name)"
    $query2 = Read-Host "Enter second username (SAM, UPN, or Display Name)"

    if ([string]::IsNullOrWhiteSpace($query1) -or [string]::IsNullOrWhiteSpace($query2)) {
        Write-Host "[ERROR] Both usernames are required." -ForegroundColor Red
        return
    }

    $source = Get-ADSource
    Write-Host "`nFetching both users from $source..." -ForegroundColor Cyan

    switch ($source) {
        "LocalAD" {
            $user1 = Search-LocalADUser -Query $query1
            $user2 = Search-LocalADUser -Query $query2
        }
        "Entra" {
            $user1 = Search-EntraUser -Query $query1
            $user2 = Search-EntraUser -Query $query2
        }
    }

    if ($null -eq $user1) { Write-Host "[NOT FOUND] '$query1' not found." -ForegroundColor Yellow; return }
    if ($null -eq $user2) { Write-Host "[NOT FOUND] '$query2' not found." -ForegroundColor Yellow; return }

    $comparisonRows = Build-ComparisonRows -User1 $user1 -User2 $user2

    Show-ComparisonTable -Rows $comparisonRows -User1Name $query1 -User2Name $query2

    $exportData = @{
        User1Name = $query1
        User2Name = $query2
        Rows      = $comparisonRows
    }

    $choice = Read-Host "Export to HTML report? [Y/N]"
    if ($choice -match "^[Yy]") {
        $path = Export-HTMLReport -Data $exportData -ReportType "Comparison" -Username "${query1}_vs_${query2}" -Source (Get-ADSource)
        Write-Host "[OK] Report saved: $path" -ForegroundColor Green
    }
}

function Build-ComparisonRows {
    param(
        [System.Collections.Specialized.OrderedDictionary]$User1,
        [System.Collections.Specialized.OrderedDictionary]$User2
    )
    $rows = @()
    $allKeys = @()
    foreach ($k in $User1.Keys) { if ($allKeys -notcontains $k) { $allKeys += $k } }
    foreach ($k in $User2.Keys) { if ($allKeys -notcontains $k) { $allKeys += $k } }

    foreach ($key in $allKeys) {
        $v1    = if ($User1.Contains($key)) { $User1[$key] } else { $null }
        $v2    = if ($User2.Contains($key)) { $User2[$key] } else { $null }
        $v1str = if ($null -eq $v1) { "" } else { $v1.ToString() }
        $v2str = if ($null -eq $v2) { "" } else { $v2.ToString() }

        $rows += [PSCustomObject]@{
            Field  = $key
            Val1   = $v1str
            Val2   = $v2str
            IsDiff = ($v1str -ne $v2str)
        }
    }
    return $rows
}

function Show-ComparisonTable {
    param(
        [PSCustomObject[]]$Rows,
        [string]$User1Name,
        [string]$User2Name
    )
    $colW = 28
    $line = ("=" * ($colW * 3 + 10))

    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host " USER COMPARISON" -ForegroundColor White
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ("  {0,-25} {1,-28} {2}" -f "Field", $User1Name.ToUpper(), $User2Name.ToUpper()) -ForegroundColor Gray
    Write-Host ("-" * ($colW * 3 + 10)) -ForegroundColor DarkGray

    foreach ($row in $Rows) {
        $v1 = if ([string]::IsNullOrEmpty($row.Val1)) { "N/A" } else { $row.Val1 }
        $v2 = if ([string]::IsNullOrEmpty($row.Val2)) { "N/A" } else { $row.Val2 }

        if ($row.IsDiff) {
            Write-Host ("  {0,-25}" -f "$($row.Field) :") -NoNewline -ForegroundColor Yellow
            Write-Host (" {0,-28}" -f $v1) -NoNewline -ForegroundColor Red
            Write-Host (" $v2  [DIFF]") -ForegroundColor Green
        } else {
            Write-Host ("  {0,-25} {1,-28} {2}" -f "$($row.Field) :", $v1, $v2)
        }
    }
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ""
}
