# Быстрый старт

## Шаг 1: Подготовка

### 1.1. Клонирование/копирование проекта

Убедитесь, что все файлы проекта на месте.

**Важно**: Скрипты должны запускаться на **CA1 (Issuing CA)** сервере. См. [`docs/WHERE_TO_RUN_SCRIPTS.md`](docs/WHERE_TO_RUN_SCRIPTS.md) для деталей.

### 1.2. Создание конфигурации

**Вариант 1: Автоматическое заполнение (рекомендуется)**

```powershell
# Запустите скрипт автоматического заполнения
.\src\Initialize-PkiConfig.ps1
```

Скрипт автоматически определит:
- ✅ Домен (через AD или WMI)
- ✅ CA1 параметры (имя, hostname, DNS)
- ✅ IIS настройки (site name, web root)
- ✅ Стандартные пути
- ✅ Endpoints URLs

**Требования:**
- Права локального администратора (Administrators) — **ОБЯЗАТЕЛЬНО**
- Права Domain Admin — рекомендуется для получения информации о домене

После выполнения скрипта **заполните параметры CA0**:

**Вариант 1: Автоматический сбор на CA0 (рекомендуется)**

```powershell
# На CA0 сервере (включите сервер, если он offline)
.\src\Get-CA0Config.ps1

# Скопируйте выведенные параметры
# На CA1 вставьте их в секцию 'ca0' файла config\env.json
```

**Вариант 2: Ручное заполнение**

```powershell
# Скопируйте пример конфигурации
Copy-Item config\env.example.json config\env.json

# Отредактируйте config\env.json под вашу инфраструктуру
notepad config\env.json
```

Заполните вручную в `config\env.json`:
- `ca0.name` — имя Root CA
- `ca0.hostname` — hostname сервера CA0
- `ca0.dnsName` — FQDN сервера CA0
- `ca0.commonName` — Common Name Root CA

**Обязательно заполните**:
- `domain.name`, `domain.fqdn`
- `ca0.hostname`, `ca0.name`
- `ca1.hostname`, `ca1.name`
- `iis.siteName`
- `iis.webRootPath`
- `paths.*` (пути к директориям)

### 1.3. Проверка прав

Убедитесь, что вы запускаете PowerShell с правами администратора:

```powershell
# Проверка прав
[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent() | 
    ForEach-Object { $_.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
```

Должно вернуть `True`.

## Шаг 2: Первый запуск (Аудит)

### 1.4. Smoke-проверка перед использованием (рекомендуется)

Перед рабочим запуском выполните единый smoke-прогон в `-WhatIf` режиме (PowerShell **от имени администратора**, запуск из корня проекта):

```powershell
$ErrorActionPreference='Stop'; New-Item -ItemType Directory -Force -Path .\output\smoke | Out-Null; $baseline=(Get-ChildItem .\output\baseline_*.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1); if(-not $baseline){ & .\src\pki-audit\Invoke-PkiAudit.ps1 -Role All -OutputPath .\output\smoke -ConfigPath .\config\env.json -WhatIf; $baseline=(Get-ChildItem .\output\baseline_*.json,.\output\smoke\baseline_*.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1) }; & .\src\Initialize-PkiConfig.ps1 -WhatIf; & .\src\pki-audit\Invoke-PkiAudit.ps1 -Role All -OutputPath .\output\smoke -ConfigPath .\config\env.json -WhatIf; & .\src\pki-validate\Invoke-PkiValidation.ps1 -ConfigPath .\config\env.json -OutputPath .\output\smoke -BaselinePath $baseline.FullName; & .\src\pki-align\Invoke-PkiAlignment.ps1 -ConfigPath .\config\env.json -OutputPath .\output\smoke -BaselinePath $baseline.FullName -WhatIf; $plan=(Get-ChildItem .\output\smoke\alignment_plan_*.json,.\output\alignment_plan_*.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1); if($plan){ & .\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath $plan.FullName -OutputPath .\output\smoke -All -WhatIf } else { Write-Host 'Rollback smoke skipped: alignment plan not found.' -ForegroundColor Yellow }
```

Ожидаемый результат: все сценарии выполняются без критических ошибок, а отчёты/логи пишутся в `.\output\smoke`.

### 2.1. Создание директории для результатов

```powershell
New-Item -ItemType Directory -Path .\output -Force
```

### 2.2. Запуск аудита

```powershell
.\src\pki-audit\Invoke-PkiAudit.ps1 `
    -Role All `
    -OutputPath .\output `
    -ConfigPath .\config\env.json `
    -IncludeEventLogs `
    -IncludeIisExport
```

### 2.3. Просмотр результатов

```powershell
# Откройте AS-IS отчёт
notepad .\output\AS-IS_*.md

# Или baseline JSON
notepad .\output\baseline_*.json
```

## Шаг 3: Валидация

```powershell
# Найдите последний baseline
$baseline = Get-ChildItem .\output\baseline_*.json | Sort-Object LastWriteTime -Descending | Select-Object -First 1

# Запустите валидацию
.\src\pki-validate\Invoke-PkiValidation.ps1 `
    -ConfigPath .\config\env.json `
    -OutputPath .\output `
    -BaselinePath $baseline.FullName

# Опционально: явный сертификат для certutil -verify -urlfetch
# .\src\pki-validate\Invoke-PkiValidation.ps1 -ConfigPath .\config\env.json -OutputPath .\output -BaselinePath $baseline.FullName -CertificatePath "C:\certs\test.cer"
```

Просмотрите отчёт валидации:

Если `-CertificatePath` не указан, скрипт автоматически пытается найти сертификат в baseline или в `CertEnroll`.

```powershell
notepad .\output\validation_report_*.md
```

## Шаг 4: Планирование изменений (WhatIf)

```powershell
# Запуск в режиме WhatIf (безопасно, изменения не применяются)
.\src\pki-align\Invoke-PkiAlignment.ps1 `
    -ConfigPath .\config\env.json `
    -OutputPath .\output `
    -BaselinePath $baseline.FullName `
    -WhatIf
```

Просмотрите план изменений:

```powershell
notepad .\output\alignment_plan_*.json
```

Примечание: alignment определяет целевой CA по `config.ca1.name`; при множественных CA-конфигурациях это поле должно быть заполнено корректно.

## Шаг 5: Применение изменений (только после проверки!)

**⚠️ ВНИМАНИЕ**: Применяйте изменения только после тщательной проверки плана!

```powershell
# Этап 1: применение изменений с backup (без рестарта CertSvc)
.\src\pki-align\Invoke-PkiAlignment.ps1 `
    -ConfigPath .\config\env.json `
    -OutputPath .\output `
    -BaselinePath $baseline.FullName `
    -Apply `
    -Backup

# Этап 2 (опционально): рестарт CertSvc только в согласованное окно работ
.\src\pki-align\Invoke-PkiAlignment.ps1 `
    -ConfigPath .\config\env.json `
    -OutputPath .\output `
    -BaselinePath $baseline.FullName `
    -Apply `
    -Backup `
    -RestartCertSvc
```

## Шаг 6: Проверка после изменений

```powershell
# Повторный аудит
.\src\pki-audit\Invoke-PkiAudit.ps1 `
    -Role All `
    -OutputPath .\output\after_alignment `
    -ConfigPath .\config\env.json

# Повторная валидация
$newBaseline = Get-ChildItem .\output\after_alignment\baseline_*.json | Sort-Object LastWriteTime -Descending | Select-Object -First 1

.\src\pki-validate\Invoke-PkiValidation.ps1 `
    -ConfigPath .\config\env.json `
    -OutputPath .\output\after_alignment `
    -BaselinePath $newBaseline.FullName
```

## Типичные проблемы

### Ошибка: "Конфигурационный файл не найден"

**Решение**: Убедитесь, что файл `config\env.json` существует и путь указан правильно.

### Ошибка: "Скрипт должен быть запущен с правами администратора"

**Решение**: Запустите PowerShell от имени администратора.

### Ошибка: "Модуль не найден"

**Решение**: Убедитесь, что вы запускаете скрипты из корня проекта, и все модули в `src\lib\` на месте.

### Ошибка: "IIS модуль не найден"

**Решение**: Установите IIS и модуль WebAdministration:

```powershell
Install-WindowsFeature -Name Web-Server, Web-Mgmt-Console
Import-Module WebAdministration
```

## Следующие шаги

1. Изучите документацию в `docs\`
2. Прочитайте `rules\PKI_RULES.md` для понимания принципов безопасности
3. Изучите runbooks в `docs\Runbooks\`
4. Ознакомьтесь с `docs\AUDIT_REPORT.md` и `docs\AUDIT_FIXES_SUMMARY.md`
5. Настройте мониторинг и автоматизацию

## Откат изменений

Если после применения изменений обнаружены проблемы:

```powershell
# Найти план выравнивания
$plan = Get-ChildItem .\output\alignment_plan_*.json | Sort-Object LastWriteTime -Descending | Select-Object -First 1

# WhatIf режим для проверки
.\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath $plan.FullName -OutputPath .\output -All -WhatIf

# Выполнение отката
.\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath $plan.FullName -OutputPath .\output -All

# Если найдено несколько CA-конфигураций, укажите целевой CA
.\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath $plan.FullName -OutputPath .\output -All -CAName "<CA Common Name>"
```

Подробнее см. `docs\Runbooks\Rollback_Runbook.md`

## Получение помощи

- Документация: `docs\00_Overview.md`
- Правила безопасности: `rules\PKI_RULES.md`
- Runbooks: `docs\Runbooks\`

## Важные напоминания

- ✅ Всегда запускайте аудит перед изменениями
- ✅ Всегда проверяйте план изменений в режиме WhatIf
- ✅ Всегда создавайте backup перед применением изменений
- ✅ Legacy пути никогда не удаляются
- ✅ CA никогда не удаляется
- ✅ Re-root никогда не выполняется
