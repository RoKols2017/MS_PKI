# Руководство для администратора: Начало работы

## Описание

Это руководство предназначено для администраторов, которые впервые работают с проектом PKI Infrastructure Audit & Alignment Tool.

## Шаг 1: Подготовка проекта

### 1.1. Копирование проекта на CA1

Скопируйте весь проект на CA1 (Issuing CA) сервер в удобную директорию, например:
```
C:\PKI_Automation\
```

### 1.2. Проверка структуры

Убедитесь, что все файлы на месте:
```powershell
Get-ChildItem -Recurse | Select-Object FullName
```

Должны присутствовать:
- `src/` — скрипты и модули
- `docs/` — документация
- `config/` — конфигурация
- `rules/` — правила безопасности

## Шаг 2: Создание конфигурации

### 2.1. Автоматическое заполнение (рекомендуется)

**На CA1 сервере:**

```powershell
# Запустите PowerShell от имени администратора
# Перейдите в директорию проекта
cd C:\PKI_Automation

# Запустите скрипт автоматического заполнения
.\src\Initialize-PkiConfig.ps1
```

**Требования:**
- Права локального администратора (Administrators) — **ОБЯЗАТЕЛЬНО**
- Права Domain Admin — рекомендуется для получения информации о домене

**Что заполняется автоматически:**
- ✅ Домен (через AD или WMI)
- ✅ CA1 параметры (имя, hostname, DNS, Common Name)
- ✅ IIS настройки (site name, web root, certEnroll path)
- ✅ Стандартные пути (PKI web root, AIA, CDP)
- ✅ Endpoints URLs (health check, CRL, AIA)

### 2.2. Заполнение параметров CA0

**Вариант 1: Автоматический сбор на CA0 (рекомендуется)**

```powershell
# На CA0 сервере (включите сервер, если он offline)
# Войдите с правами локального администратора
# Скопируйте проект на CA0 (или только src/Get-CA0Config.ps1)

# Запустите скрипт
.\src\Get-CA0Config.ps1

# Скопируйте выведенные параметры
```

**На CA1 сервере:**

```powershell
# Откройте config\env.json
notepad config\env.json

# Найдите секцию "ca0" и вставьте скопированные параметры
# Сохраните файл
```

**Вариант 2: Ручное заполнение**

Заполните вручную в `config\env.json`:
- `ca0.name` — имя Root CA
- `ca0.hostname` — hostname сервера CA0
- `ca0.dnsName` — FQDN сервера CA0
- `ca0.commonName` — Common Name Root CA
- `ca0.type` — обычно "StandaloneRootCA"
- `ca0.status` — обычно "offline"
- `ca0.crlPolicy` — политика CRL для Root CA

### 2.3. Проверка конфигурации

```powershell
# Проверка синтаксиса JSON
$config = Get-Content config\env.json -Raw -Encoding UTF8 | ConvertFrom-Json

# Проверка параметров
$config.domain | Format-List
$config.ca0 | Format-List
$config.ca1 | Format-List
$config.iis | Format-List
```

Если ошибок нет, конфигурация готова к использованию.

## Шаг 3: Первый запуск (Аудит)

### 3.1. Создание директории для результатов

```powershell
New-Item -ItemType Directory -Path .\output -Force
```

### 3.2. Запуск аудита

```powershell
.\src\pki-audit\Invoke-PkiAudit.ps1 `
    -Role All `
    -OutputPath .\output `
    -ConfigPath .\config\env.json `
    -IncludeEventLogs `
    -IncludeIisExport
```

**Что собирается:**
- Конфигурация CA0 и CA1
- IIS конфигурация
- CRL файлы и информация
- Шаблоны сертификатов
- Event Logs (если указан `-IncludeEventLogs`)
- IIS конфигурация (если указан `-IncludeIisExport`)

### 3.3. Просмотр результатов

```powershell
# Откройте AS-IS отчёт
notepad .\output\AS-IS_*.md

# Или baseline JSON
notepad .\output\baseline_*.json
```

## Шаг 4: Валидация

```powershell
# Найдите последний baseline
$baseline = Get-ChildItem .\output\baseline_*.json | Sort-Object LastWriteTime -Descending | Select-Object -First 1

# Запустите валидацию
.\src\pki-validate\Invoke-PkiValidation.ps1 `
    -ConfigPath .\config\env.json `
    -OutputPath .\output `
    -BaselinePath $baseline.FullName
```

Просмотрите отчёт валидации:
```powershell
notepad .\output\validation_report_*.md
```

## Шаг 5: Планирование изменений (WhatIf)

**⚠️ ВАЖНО:** Всегда сначала проверяйте план изменений в режиме WhatIf!

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

**Проверьте:**
- Какие изменения планируются
- Какие backup будут созданы
- Какие rollback действия доступны

## Шаг 6: Применение изменений (только после проверки!)

**⚠️ ВНИМАНИЕ:** Применяйте изменения только после тщательной проверки плана!

```powershell
# Применение изменений с backup
.\src\pki-align\Invoke-PkiAlignment.ps1 `
    -ConfigPath .\config\env.json `
    -OutputPath .\output `
    -BaselinePath $baseline.FullName `
    -Apply `
    -Backup
```

**Что происходит:**
- Создаются backup всех изменяемых файлов и настроек
- Применяются изменения согласно плану
- Создается файл `alignment_plan_*.json` с информацией о всех изменениях

## Шаг 7: Проверка после изменений

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

## Откат изменений (если требуется)

Если после применения изменений обнаружены проблемы:

```powershell
# Найти план выравнивания
$plan = Get-ChildItem .\output\alignment_plan_*.json | Sort-Object LastWriteTime -Descending | Select-Object -First 1

# WhatIf режим для проверки
.\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath $plan.FullName -OutputPath .\output -All -WhatIf

# Выполнение отката
.\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath $plan.FullName -OutputPath .\output -All
```

Подробнее см. [`docs/Runbooks/Rollback_Runbook.md`](Runbooks/Rollback_Runbook.md)

## Требования к правам

### Обязательные права

- **Administrators** (локальная группа) — **ОБЯЗАТЕЛЬНО** для всех скриптов

### Рекомендуемые права

- **Domain Admins** — рекомендуется для автоматического определения домена и полной информации AD

### Не требуются

- **Enterprise Administrator** — не требуется, так как проект не изменяет схему AD или forest-level настройки

## Типичные проблемы

### Ошибка: "Конфигурационный файл не найден"

**Решение:** Убедитесь, что файл `config\env.json` существует и путь указан правильно.

### Ошибка: "Скрипт должен быть запущен с правами администратора"

**Решение:** Запустите PowerShell от имени администратора.

### Ошибка: "CA не установлен на этом сервере"

**Решение:** Убедитесь, что скрипт запущен на CA1 (Issuing CA) сервере.

### Ошибка: "Модуль не найден"

**Решение:** Убедитесь, что вы запускаете скрипты из корня проекта, и все модули в `src\lib\` на месте.

### Ошибка: "IIS модуль не найден"

**Решение:** Установите IIS и модуль WebAdministration:
```powershell
Install-WindowsFeature -Name Web-Server, Web-Mgmt-Console
Import-Module WebAdministration
```

## Следующие шаги

1. Изучите документацию в [`docs/`](.)
2. Прочитайте [`rules/PKI_RULES.md`](../rules/PKI_RULES.md) для понимания принципов безопасности
3. Изучите runbooks в [`docs/Runbooks/`](Runbooks/)
4. Ознакомьтесь с [`docs/AUDIT_REPORT.md`](AUDIT_REPORT.md) и [`docs/AUDIT_FIXES_SUMMARY.md`](AUDIT_FIXES_SUMMARY.md)
5. Настройте мониторинг и автоматизацию

## Важные напоминания

- ✅ Всегда запускайте аудит перед изменениями
- ✅ Всегда проверяйте план изменений в режиме WhatIf
- ✅ Всегда создавайте backup перед применением изменений
- ✅ Legacy пути никогда не удаляются
- ✅ CA никогда не удаляется
- ✅ Re-root никогда не выполняется
- ✅ Скрипты запускаются на **CA1**, кроме `Get-CA0Config.ps1` (запускается на CA0)

## Связанные документы

- [`README.md`](../README.md) — главный файл проекта
- [`QUICKSTART.md`](../QUICKSTART.md) — быстрый старт
- [`docs/WHERE_TO_RUN_SCRIPTS.md`](WHERE_TO_RUN_SCRIPTS.md) — на каком CA запускать скрипты
- [`docs/Initialize-PkiConfig_Guide.md`](Initialize-PkiConfig_Guide.md) — детальное руководство по настройке конфигурации
- [`docs/Get-CA0Config_Guide.md`](Get-CA0Config_Guide.md) — сбор параметров CA0
- [`docs/00_Overview.md`](00_Overview.md) — обзор проекта и архитектура
- [`rules/PKI_RULES.md`](../rules/PKI_RULES.md) — правила безопасности
