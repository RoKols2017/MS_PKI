# Check file locks script
$files = Get-ChildItem -Path src -Recurse -Include *.ps1,*.psm1

Write-Host "Checking file locks..." -ForegroundColor Cyan
Write-Host ""

foreach ($file in $files) {
    $locked = $false
    $errorMsg = ""
    
    try {
        $stream = [System.IO.File]::Open($file.FullName, 'Open', 'ReadWrite', 'None')
        $stream.Close()
    }
    catch {
        $locked = $true
        $errorMsg = $_.Exception.Message
    }
    
    if ($locked) {
        Write-Host "LOCKED: $($file.Name)" -ForegroundColor Red
        Write-Host "  Error: $errorMsg" -ForegroundColor Gray
    }
    else {
        Write-Host "OK: $($file.Name)" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Done!" -ForegroundColor Cyan
