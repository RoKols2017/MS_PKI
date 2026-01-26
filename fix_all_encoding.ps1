# Fix encoding for all PowerShell files
$files = @(
    'src\lib\CertUtil.psm1',
    'src\lib\Http.psm1',
    'src\lib\Logging.psm1',
    'src\lib\PkiCommon.psm1',
    'src\lib\PkiSecurity.psm1',
    'src\Get-CA0Config.ps1',
    'src\Initialize-PkiConfig.ps1',
    'src\pki-align\Invoke-PkiAlignment.ps1',
    'src\pki-audit\Invoke-PkiAudit.ps1',
    'src\pki-rollback\Invoke-PkiRollback.ps1',
    'src\pki-validate\Invoke-PkiValidation.ps1'
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
    else {
        Write-Host "  Not found: $file" -ForegroundColor Yellow
    }
}

Write-Host "`nDone!" -ForegroundColor Cyan
