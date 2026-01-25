# Runbook: Откат изменений PKI выравнивания

## Описание

Процедура отката применённых изменений PKI выравнивания с использованием скрипта `Invoke-PkiRollback.ps1`.

## Предварительные требования

- План выравнивания (alignment_plan_*.json)
- Права: Local Administrator на CA сервере
- Backup файлы (если требуется восстановление из backup)

## Когда использовать rollback

- Обнаружены проблемы после применения изменений
- Изменения вызвали неожиданное поведение
- Требуется вернуться к предыдущему состоянию
- Тестирование процедуры отката

## Процедура

### Шаг 1: Определение плана выравнивания

```powershell
# Найти последний план выравнивания
$planPath = Get-ChildItem .\output\alignment_plan_*.json | 
    Sort-Object LastWriteTime -Descending | 
    Select-Object -First 1 -ExpandProperty FullName

Write-Host "План выравнивания: $planPath"
```

### Шаг 2: Просмотр плана (опционально)

```powershell
# Просмотр содержимого плана
$plan = Get-Content $planPath -Raw -Encoding UTF8 | ConvertFrom-Json

# Просмотр применённых изменений
$appliedChanges = $plan.changes | Where-Object { $_.applied -eq $true }
Write-Host "Применённых изменений: $($appliedChanges.Count)"

foreach ($change in $appliedChanges) {
    Write-Host "  - [$($change.category)] $($change.description) (ID: $($change.changeId))"
}
```

### Шаг 3: WhatIf режим (рекомендуется)

```powershell
# Проверка плана отката без выполнения
.\src\pki-rollback\Invoke-PkiRollback.ps1 `
    -AlignmentPlanPath $planPath `
    -OutputPath .\output `
    -All `
    -WhatIf
```

**Проверьте**:
- Список изменений для отката
- Наличие rollback функций для всех изменений
- Порядок отката (должен быть обратным порядку применения)

### Шаг 4: Откат всех изменений

```powershell
# Откат всех применённых изменений
.\src\pki-rollback\Invoke-PkiRollback.ps1 `
    -AlignmentPlanPath $planPath `
    -OutputPath .\output `
    -All
```

### Шаг 5: Откат выборочных изменений (альтернатива)

```powershell
# Определение ID изменений для отката
$changeIds = @(
    "change-id-1",
    "change-id-2"
)

# Откат выборочных изменений
.\src\pki-rollback\Invoke-PkiRollback.ps1 `
    -AlignmentPlanPath $planPath `
    -OutputPath .\output `
    -ChangeIds $changeIds
```

### Шаг 6: Проверка результатов

```powershell
# Проверка статуса после отката
.\src\pki-validate\Invoke-PkiValidation.ps1 `
    -ConfigPath .\config\env.json `
    -OutputPath .\output

# Повторный аудит для сравнения
.\src\pki-audit\Invoke-PkiAudit.ps1 `
    -Role All `
    -OutputPath .\output\after_rollback `
    -ConfigPath .\config\env.json
```

## Типы изменений и их откат

### MIME типы IIS

**Откат**: Удаление добавленных MIME типов через `Remove-WebConfigurationProperty`

**Проверка**:
```powershell
Import-Module WebAdministration
Get-WebConfigurationProperty -Filter "system.webServer/staticContent" -Name "." -PSPath "IIS:\Sites\Default Web Site"
```

### ACL директорий

**Откат**: Восстановление предыдущих ACL из backup

**Проверка**:
```powershell
$path = "C:\inetpub\wwwroot\PKI\CDP"
$acl = Get-Acl -Path $path
$acl.Access | Format-Table
```

### CRLPublicationURLs

**Откат**: Восстановление старых URLs из backup

**Проверка**:
```powershell
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\*"
$caConfig = Get-ItemProperty -Path $regPath | Select-Object -First 1
$caName = $caConfig.PSChildName
$fullRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\$caName"
(Get-ItemProperty -Path $fullRegPath -Name 'CRLPublicationURLs').CRLPublicationURLs
```

### Копирование CRL

**Откат**: Восстановление из backup файлов или удаление (если файл был создан скриптом)

**Проверка**:
```powershell
# Проверка наличия backup файлов
Get-ChildItem C:\inetpub\wwwroot\PKI\CDP\*.backup_* -ErrorAction SilentlyContinue

# Проверка целостности CRL
certutil -dump C:\inetpub\wwwroot\PKI\CDP\*.crl
```

## Troubleshooting

### Проблема: Rollback не выполняется

**Причины**:
- Rollback функция не определена для изменения
- Нет прав на выполнение rollback операций
- Ресурсы были изменены вручную после применения

**Решение**:
1. Проверить наличие rollback функций в плане
2. Проверить права администратора
3. Выполнить ручной откат на основе backup файлов

### Проблема: Частичный откат

**Причины**:
- Ошибки при откате некоторых изменений
- Ресурсы недоступны

**Решение**:
1. Проверить логи: `output\logs\pki-*.log`
2. Выполнить откат оставшихся изменений вручную
3. Использовать backup файлы для восстановления

### Проблема: Backup файлы не найдены

**Причины**:
- Backup не был создан
- Backup файлы были удалены
- Неправильный путь к backup

**Решение**:
1. Проверить наличие backup в плане выравнивания
2. Использовать системные backup (если есть)
3. Восстановить вручную на основе baseline

## Автоматизация

### Запланированный откат (для тестирования)

```powershell
# Создание задачи для автоматического отката через N минут (для тестирования)
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-File C:\Scripts\Invoke-PkiRollback.ps1 -AlignmentPlanPath $planPath -OutputPath C:\output -All"

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(30)

Register-ScheduledTask -TaskName "PKI-Rollback-Test" `
    -Action $action `
    -Trigger $trigger `
    -Description "Тестовый откат изменений PKI" `
    -User "SYSTEM" `
    -RunLevel Highest
```

## Проверка успешности

### Критерии успеха

1. ✅ Все изменения откачены (или указанные изменения)
2. ✅ Конфигурация восстановлена к предыдущему состоянию
3. ✅ CRL доступны по старым путям
4. ✅ CA сервис работает корректно
5. ✅ Валидация проходит без критичных ошибок

### Проверочный список

- [ ] Rollback выполнен для всех изменений
- [ ] CRLPublicationURLs восстановлены
- [ ] MIME типы удалены (если были добавлены)
- [ ] ACL восстановлены
- [ ] CRL файлы восстановлены из backup
- [ ] CA сервис работает
- [ ] Валидация пройдена
- [ ] Логи проверены
- [ ] Обновлённый план сохранён

## Частота использования

- **Плановый откат**: Не требуется (изменения должны быть постоянными)
- **Экстренный откат**: При обнаружении критичных проблем
- **Тестовый откат**: Для проверки процедуры (рекомендуется регулярно)

## Связанные документы

- [`docs/01_Phase1_Audit_AS-IS.md`](../01_Phase1_Audit_AS-IS.md) — процедура аудита
- [`docs/AUDIT_REPORT.md`](../AUDIT_REPORT.md) — отчёт об аудите
- [`docs/AUDIT_FIXES_SUMMARY.md`](../AUDIT_FIXES_SUMMARY.md) — резюме исправлений
- [`rules/PKI_RULES.md`](../../rules/PKI_RULES.md) — правила безопасности
- [`QUICKSTART.md`](../../QUICKSTART.md) — быстрый старт

## Важные напоминания

- ⚠️ Rollback должен выполняться как можно быстрее после обнаружения проблем
- ⚠️ Всегда используйте WhatIf режим перед выполнением отката
- ⚠️ Сохраняйте backup файлы до подтверждения успешности отката
- ⚠️ Проверяйте результаты отката через валидацию и аудит
- ⚠️ Документируйте причины отката для анализа
