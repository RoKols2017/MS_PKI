# Find process locking files
$testFile = "c:\py_projects\MS_ PKI\src\lib\CertUtil.psm1"

Write-Host "Finding process locking: $testFile" -ForegroundColor Cyan
Write-Host ""

# Try to get file handle info using WMI
try {
    $processes = Get-Process | Where-Object { $_.Path -like "*cursor*" -or $_.Path -like "*code*" }
    if ($processes) {
        Write-Host "Found potential editor processes:" -ForegroundColor Yellow
        $processes | ForEach-Object {
            Write-Host "  $($_.ProcessName) (PID: $($_.Id))" -ForegroundColor Gray
        }
    }
    else {
        Write-Host "No Cursor/Code processes found" -ForegroundColor Gray
    }
}
catch {
    Write-Host "Could not check processes: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "Note: Files are locked. Close Cursor completely and try again." -ForegroundColor Yellow
