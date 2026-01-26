# Add BOM to files that were resaved
$files = @(
    'src\lib\CertUtil.psm1',
    'src\lib\Http.psm1',
    'src\lib\Logging.psm1',
    'src\lib\PkiCommon.psm1',
    'src\lib\PkiSecurity.psm1'
)

foreach ($file in $files) {
    $fullPath = Join-Path $PSScriptRoot $file
    if (Test-Path $fullPath) {
        try {
            Write-Host "Processing: $file"
            $content = Get-Content -Path $fullPath -Raw -Encoding UTF8
            $utf8BOM = New-Object System.Text.UTF8Encoding $true
            [System.IO.File]::WriteAllText($fullPath, $content, $utf8BOM)
            Write-Host "  Fixed: $file" -ForegroundColor Green
        }
        catch {
            Write-Host "  Error: $file - $_" -ForegroundColor Red
        }
    }
}

Write-Host "`nDone!" -ForegroundColor Cyan
