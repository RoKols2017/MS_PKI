# Check encoding script
Get-ChildItem -Path src -Recurse -Include *.ps1,*.psm1 | ForEach-Object {
    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    $hasBOM = ($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)
    $status = if ($hasBOM) { "OK" } else { "NEEDS FIX" }
    $color = if ($hasBOM) { "Green" } else { "Red" }
    Write-Host "$($_.Name): $status" -ForegroundColor $color
}
