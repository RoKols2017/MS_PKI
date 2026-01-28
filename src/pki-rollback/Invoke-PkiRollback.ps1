# Invoke-PkiRollback.ps1
# Откат применённых изменений PKI выравнивания

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$AlignmentPlanPath,
    
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    
    [string[]]$ChangeIds = @(),
    
    [switch]$All
)

#region Инициализация

$ErrorActionPreference = 'Stop'
$script:StartTime = Get-Date

# Импорт модулей
$libPath = Join-Path $PSScriptRoot '..\lib'
Import-Module (Join-Path $libPath 'Logging.psm1') -Force
Import-Module (Join-Path $libPath 'PkiCommon.psm1') -Force

# Инициализация логирования
Initialize-Logging -OutputPath $OutputPath -Level 'Info'
Write-Log -Level Info -Message "Начало отката изменений PKI" -Operation 'Rollback' -OutputPath $OutputPath

# Проверка прав
try {
    Assert-Administrator
}
catch {
    Write-Log -Level Error -Message $_ -Operation 'Rollback' -OutputPath $OutputPath
    exit 3
}

# Проверка существования плана
if (-not (Test-Path $AlignmentPlanPath)) {
    Write-Log -Level Error -Message "План выравнивания не найден: $AlignmentPlanPath" -Operation 'Rollback' -OutputPath $OutputPath
    exit 2
}

#endregion

#region Загрузка плана

try {
    $plan = Get-Content -Path $AlignmentPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Log -Level Info -Message "План загружен: $AlignmentPlanPath" -Operation 'Rollback' -OutputPath $OutputPath
    Write-Log -Level Info -Message "Всего изменений в плане: $($plan.changes.Count)" -Operation 'Rollback' -OutputPath $OutputPath
    Write-Log -Level Info -Message "Применённых изменений: $(($plan.changes | Where-Object { $_.applied -eq $true }).Count)" -Operation 'Rollback' -OutputPath $OutputPath
}
catch {
    Write-Log -Level Error -Message "Ошибка загрузки плана: $_" -Exception $_ -Operation 'Rollback' -OutputPath $OutputPath
    exit 2
}

#endregion

#region Определение изменений для отката

$changesToRollback = @()

if ($All) {
    $changesToRollback = $plan.changes | Where-Object { 
        $_.applied -eq $true -and 
        $null -ne $_.rollbackAction 
    }
    Write-Log -Level Info -Message "Режим: откат всех применённых изменений" -Operation 'Rollback' -OutputPath $OutputPath
}
elseif ($ChangeIds.Count -gt 0) {
    $changesToRollback = $plan.changes | Where-Object { 
        $_.changeId -in $ChangeIds -and 
        $_.applied -eq $true -and 
        $null -ne $_.rollbackAction 
    }
    Write-Log -Level Info -Message "Режим: откат указанных изменений (ID: $($ChangeIds -join ', '))" -Operation 'Rollback' -OutputPath $OutputPath
}
else {
    Write-Log -Level Error -Message "Не указаны изменения для отката. Используйте -All или -ChangeIds" -Operation 'Rollback' -OutputPath $OutputPath
    exit 2
}

if ($changesToRollback.Count -eq 0) {
    Write-Log -Level Warning -Message "Нет изменений для отката" -Operation 'Rollback' -OutputPath $OutputPath
    Write-Host "`nНет изменений для отката." -ForegroundColor Yellow
    exit 0
}

Write-Log -Level Info -Message "Найдено изменений для отката: $($changesToRollback.Count)" -Operation 'Rollback' -OutputPath $OutputPath

#endregion

#region WhatIf режим

if ($WhatIfPreference) {
    Write-Host "`n=== ПЛАН ОТКАТА (WhatIf режим) ===" -ForegroundColor Cyan
    Write-Host "Изменений для отката: $($changesToRollback.Count)" -ForegroundColor Yellow
    
    foreach ($change in $changesToRollback) {
        Write-Host "`n- [$($change.category)] $($change.description)" -ForegroundColor White
        Write-Host "  ID: $($change.changeId)" -ForegroundColor Gray
        Write-Host "  Время применения: $($change.timestamp)" -ForegroundColor Gray
    }
    
    Write-Host "`n⚠️ Режим WhatIf. Используйте без -WhatIf для выполнения отката." -ForegroundColor Yellow
    exit 10
}

#endregion

#region Выполнение отката

Write-Host "`n=== ОТКАТ ИЗМЕНЕНИЙ ===" -ForegroundColor Red
Write-Host "Изменений для отката: $($changesToRollback.Count)" -ForegroundColor Yellow

# Откатываем в обратном порядке (LIFO)
$changesToRollback = $changesToRollback | Sort-Object { $_.timestamp } -Descending

$rolledBackCount = 0
$failedCount = 0
$skippedCount = 0

foreach ($change in $changesToRollback) {
    try {
        Write-Host "`nОткат: $($change.description)" -ForegroundColor Cyan
        Write-Host "  ID: $($change.changeId)" -ForegroundColor Gray
        
        if (-not $change.rollbackAction) {
            Write-Host "  ⚠️ Rollback action не определён, пропуск" -ForegroundColor Yellow
            $skippedCount++
            continue
        }
        
        Write-Log -Level Info -Message "Откат изменения: $($change.description) (ID: $($change.changeId))" -Operation 'Rollback' -OutputPath $OutputPath
        
        # Выполнение rollback action
        $result = & $change.rollbackAction $change
        
        if ($result) {
            $change.rolledBack = $true
            $rolledBackCount++
            Write-Host "  ✅ Откачено успешно" -ForegroundColor Green
            Write-Log -Level Info -Message "Изменение откачено успешно: $($change.changeId)" -Operation 'Rollback' -OutputPath $OutputPath
        }
        else {
            $failedCount++
            Write-Host "  ❌ Ошибка отката" -ForegroundColor Red
            Write-Log -Level Warning -Message "Не удалось откатить изменение: $($change.changeId)" -Operation 'Rollback' -OutputPath $OutputPath
        }
    }
    catch {
        $failedCount++
        Write-Host "  ❌ Критическая ошибка: $_" -ForegroundColor Red
        Write-Log -Level Error -Message "Ошибка отката изменения: $_ (ID: $($change.changeId))" -Exception $_ -Operation 'Rollback' -OutputPath $OutputPath
    }
}

#endregion

#region Результаты

$duration = (Get-Date) - $script:StartTime

Write-Host "`n=== РЕЗУЛЬТАТЫ ОТКАТА ===" -ForegroundColor Green
Write-Host "✅ Откачено успешно: $rolledBackCount" -ForegroundColor Green
Write-Host "⚠️ Пропущено: $skippedCount" -ForegroundColor Yellow
Write-Host "❌ Ошибок: $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "Время выполнения: $($duration.TotalSeconds) сек" -ForegroundColor Cyan

Write-Log -Level Info -Message "Откат завершён: $rolledBackCount успешно, $skippedCount пропущено, $failedCount ошибок" -Operation 'Rollback' -OutputPath $OutputPath

# Сохранение обновлённого плана
try {
    $updatedPlanPath = Join-Path $OutputPath "alignment_plan_rolledback_$(Get-Timestamp).json"
    $plan | ConvertTo-Json -Depth 10 | Out-File -FilePath $updatedPlanPath -Encoding UTF8
    Write-Log -Level Info -Message "Обновлённый план сохранён: $updatedPlanPath" -Operation 'Rollback' -OutputPath $OutputPath
    Write-Host "Обновлённый план: $updatedPlanPath" -ForegroundColor Cyan
}
catch {
    Write-Log -Level Warning -Message "Ошибка сохранения обновлённого плана: $_" -Operation 'Rollback' -OutputPath $OutputPath
}

# Exit code
if ($failedCount -gt 0) {
    exit 6
}
elseif ($skippedCount -eq $changesToRollback.Count) {
    exit 0
}
else {
    exit 0
}

#endregion
