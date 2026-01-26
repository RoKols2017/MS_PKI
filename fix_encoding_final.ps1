# Final encoding fix script
# Run this script after closing all PowerShell files in the editor

$files = Get-ChildItem -Path src -Recurse -Include *.ps1,*.psm1

foreach ($file in $files) {
    Write-Host "Processing: $($file.Name)"
    
    try {
        # Read content as bytes to preserve encoding
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        
        # Check if already has BOM
        $hasBOM = ($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)
        
        if ($hasBOM) {
            Write-Host "  Already has BOM: $($file.Name)" -ForegroundColor Gray
            continue
        }
        
        # Read content as text
        $content = Get-Content -Path $file.FullName -Raw -Encoding UTF8
        
        # Write with UTF-8 BOM
        $utf8WithBom = New-Object System.Text.UTF8Encoding $true
        $newBytes = $utf8WithBom.GetBytes($content)
        [System.IO.File]::WriteAllBytes($file.FullName, $newBytes)
        
        Write-Host "  Fixed: $($file.Name)" -ForegroundColor Green
    }
    catch {
        Write-Host "  Error: $($file.Name) - $_" -ForegroundColor Red
        Write-Host "  Make sure the file is not open in any editor!" -ForegroundColor Yellow
    }
}

Write-Host "`nDone! Please verify encoding with check_encoding.ps1" -ForegroundColor Cyan
