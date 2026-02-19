# PKI Infrastructure Audit & Alignment Tool

## Описание проекта

Проект для автоматизированного аудита и безопасного выравнивания PKI-инфраструктуры на базе Microsoft Active Directory Certificate Services (AD CS). Реализует evidence-driven подход к модернизации PKI без нарушения работы существующей инфраструктуры.

## Архитектура

### Схема доверия
```
CA0 (Offline Root CA) → CA1 (Enterprise Issuing CA)
```

### Namespace
- **Legacy** (сохраняется для совместимости):
  - `/Certs`
  - `/CertsAIA`
  - `/IssCA/*`
  - `/ssCA/*`

- **Canonical** (новый стандарт):
  - `/PKI/AIA`
  - `/PKI/CDP`

## Фазы проекта

### Phase 1: Audit (AS-IS)
Read-only аудит текущего состояния PKI-инфраструктуры:
- Конфигурация CA (Root и Issuing)
- IIS конфигурация и публикация AIA/CDP
- Шаблоны сертификатов
- Autoenrollment настройки
- CRL статус и доступность
- Event Logs анализ

**Выход**: `baseline.json`, `AS-IS.md`, evidence pack

### Phase 2: Stabilization
Устранение критических рисков, минимальные безопасные изменения.

### Phase 3: Standardization
Определение правил, политик, канонической модели.

### Phase 4: Alignment
Контролируемые изменения конфигурации с backup и rollback.

### Phase 5: Validation & Documentation
Проверка изменений и генерация документации.

### Phase 6: Future Readiness
Подготовка к масштабированию (CA2, дополнительные Issuing CA).

## Структура репозитория

```
/
├── src/
│   ├── Initialize-PkiConfig.ps1
│   ├── Get-CA0Config.ps1
│   ├── pki-audit/
│   │   └── Invoke-PkiAudit.ps1
│   ├── pki-validate/
│   │   └── Invoke-PkiValidation.ps1
│   ├── pki-align/
│   │   └── Invoke-PkiAlignment.ps1
│   ├── pki-rollback/
│   │   └── Invoke-PkiRollback.ps1
│   └── lib/
│       ├── PkiCommon.psm1
│       ├── Logging.psm1
│       ├── Http.psm1
│       ├── CertUtil.psm1
│       └── PkiSecurity.psm1
├── docs/
│   ├── 00_Overview.md
│   ├── 01_Phase1_Audit_AS-IS.md
│   ├── AUDIT_REPORT.md
│   ├── AUDIT_FIXES_SUMMARY.md
│   ├── Get-CA0Config_Guide.md
│   ├── Initialize-PkiConfig_Guide.md
│   └── Runbooks/
│       ├── RootCRL_Runbook.md
│       ├── IssuingCRL_Runbook.md
│       └── Rollback_Runbook.md
├── config/
│   └── env.example.json
├── output/
│   └── (генерируется скриптами)
├── rules/
│   └── PKI_RULES.md
└── README.md
```

## Быстрый старт

### Предварительная smoke-проверка (рекомендуется)

Перед рабочим запуском выполните единый smoke-прогон в `-WhatIf` режиме (PowerShell от имени администратора, запуск из корня проекта):

```powershell
$ErrorActionPreference='Stop'; New-Item -ItemType Directory -Force -Path .\output\smoke | Out-Null; $baseline=(Get-ChildItem .\output\baseline_*.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1); if(-not $baseline){ & .\src\pki-audit\Invoke-PkiAudit.ps1 -Role All -OutputPath .\output\smoke -ConfigPath .\config\env.json -WhatIf; $baseline=(Get-ChildItem .\output\baseline_*.json,.\output\smoke\baseline_*.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1) }; & .\src\Initialize-PkiConfig.ps1 -WhatIf; & .\src\pki-audit\Invoke-PkiAudit.ps1 -Role All -OutputPath .\output\smoke -ConfigPath .\config\env.json -WhatIf; & .\src\pki-validate\Invoke-PkiValidation.ps1 -ConfigPath .\config\env.json -OutputPath .\output\smoke -BaselinePath $baseline.FullName; & .\src\pki-align\Invoke-PkiAlignment.ps1 -ConfigPath .\config\env.json -OutputPath .\output\smoke -BaselinePath $baseline.FullName -WhatIf; $plan=(Get-ChildItem .\output\smoke\alignment_plan_*.json,.\output\alignment_plan_*.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1); if($plan){ & .\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath $plan.FullName -OutputPath .\output\smoke -All -WhatIf } else { Write-Host 'Rollback smoke skipped: alignment plan not found.' -ForegroundColor Yellow }
```

### 1. Конфигурация

**Автоматическое заполнение (рекомендуется):**

```powershell
.\src\Initialize-PkiConfig.ps1
```

Скрипт автоматически определит большинство параметров на CA1 сервере.

**Требования для автоматического заполнения:**
- Права локального администратора (Administrators) — **ОБЯЗАТЕЛЬНО**
- Права Domain Admin — рекомендуется
- Запуск на CA1 (Issuing CA) сервере

**Заполнение CA0 параметров:**

Используйте скрипт `Get-CA0Config.ps1` на CA0 сервере для автоматического сбора параметров:

```powershell
# На CA0 сервере
.\src\Get-CA0Config.ps1

# Скопируйте выведенные параметры
# На CA1 вставьте их в секцию 'ca0' файла config\env.json
```

**Ручное заполнение:**

Скопируйте `config/env.example.json` в `config/env.json` и заполните параметры вашей инфраструктуры.

### 2. Аудит (Phase 1)

```powershell
.\src\pki-audit\Invoke-PkiAudit.ps1 -Role All -OutputPath .\output -ConfigPath .\config\env.json
```

### 3. Валидация

```powershell
.\src\pki-validate\Invoke-PkiValidation.ps1 -ConfigPath .\config\env.json -OutputPath .\output -BaselinePath .\output\baseline_*.json
# Опционально: явный сертификат для certutil -verify -urlfetch
# .\src\pki-validate\Invoke-PkiValidation.ps1 -ConfigPath .\config\env.json -OutputPath .\output -BaselinePath .\output\baseline_*.json -CertificatePath "C:\certs\test.cer"
```

Примечание: если `-CertificatePath` не указан, скрипт пытается автоматически выбрать сертификат из baseline или из `CertEnroll`.

### 4. Выравнивание (WhatIf режим)

```powershell
.\src\pki-align\Invoke-PkiAlignment.ps1 -ConfigPath .\config\env.json -OutputPath .\output -WhatIf
```

### 5. Применение изменений

```powershell
# Этап 1: применение без рестарта CertSvc (рекомендуется)
.\src\pki-align\Invoke-PkiAlignment.ps1 -ConfigPath .\config\env.json -OutputPath .\output -Apply -Backup

# Этап 2 (опционально, в согласованное окно): рестарт CertSvc
.\src\pki-align\Invoke-PkiAlignment.ps1 -ConfigPath .\config\env.json -OutputPath .\output -Apply -Backup -RestartCertSvc
```

### 6. Откат изменений (если требуется)

```powershell
# Откат всех изменений
.\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath .\output\alignment_plan_*.json -OutputPath .\output -All

# Если на сервере несколько CA-конфигураций, укажите целевой CA
.\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath .\output\alignment_plan_*.json -OutputPath .\output -All -CAName "<CA Common Name>"

# Откат выборочных изменений
.\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath .\output\alignment_plan_*.json -OutputPath .\output -ChangeIds @("change-id-1", "change-id-2")

# WhatIf режим для проверки плана отката
.\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath .\output\alignment_plan_*.json -OutputPath .\output -All -WhatIf
```

Примечания по безопасности применения:
- `Invoke-PkiAlignment.ps1` больше не рестартует CertSvc автоматически без `-RestartCertSvc`.
- При изменении CRL publication URLs выполняется merge существующих записей (без «слепого» перезаписывания), с дедупликацией и сохранением флагов записи.
- Для детерминированного таргетинга CA в alignment используется `config.ca1.name`.

## Принципы безопасности

1. **Read-only по умолчанию** — все скрипты работают в режиме чтения, если не указан `-Apply`
2. **Backup обязателен** — перед любыми изменениями создаётся backup
3. **Rollback обязателен** — каждая операция может быть отменена через отдельный скрипт
4. **Legacy сохраняется** — старые пути не удаляются
5. **Evidence-driven** — все изменения основаны на собранных данных
6. **Zero-downtime** — изменения не должны вызывать простои
7. **CRL-first** — приоритет доступности CRL
8. **Path traversal protection** — все пути валидируются на безопасность
9. **Integrity checks** — проверка целостности всех данных перед операциями
10. **Input validation** — валидация всех входных данных

**Категорически запрещено:**
- Удаление CA
- Re-root PKI
- Массовый перевыпуск сертификатов
- Удаление legacy путей
- Изменение trust chain

Подробнее см. `rules/PKI_RULES.md`

## Требования

- Windows Server 2016+ (для CA)
- PowerShell 5.1+
- AD CS установлен и настроен
- IIS установлен (для публикации AIA/CDP)
- Права: Domain Admin или Local Administrator на CA серверах

## Выходные данные

### Baseline JSON
Машиночитаемый снимок текущего состояния инфраструктуры.

### AS-IS Markdown
Человекочитаемый отчёт на русском языке с описанием текущего состояния.

### Evidence Pack
- Экспорт реестра CA
- IIS конфигурация
- Сертификаты и CRL
- Event Logs
- Результаты certutil команд

## Документация

Вся документация находится в директории `docs/` и генерируется автоматически на русском языке.

### Полный список документации

#### Основные документы
- [`README.md`](README.md) — главный файл проекта (этот файл)
- [`QUICKSTART.md`](QUICKSTART.md) — быстрый старт для новых пользователей
- [`CHANGELOG.md`](CHANGELOG.md) — история изменений проекта

#### Обзор и архитектура
- [`docs/00_Overview.md`](docs/00_Overview.md) — обзор проекта, архитектура, фазы
- [`rules/PKI_RULES.md`](rules/PKI_RULES.md) — правила безопасности и best practices

#### Руководства по настройке
- [`docs/Initialize-PkiConfig_Guide.md`](docs/Initialize-PkiConfig_Guide.md) — автоматическое заполнение конфигурации на CA1
- [`docs/Get-CA0Config_Guide.md`](docs/Get-CA0Config_Guide.md) — сбор параметров CA0 на CA0 сервере
- [`docs/ADMIN_START_GUIDE.md`](docs/ADMIN_START_GUIDE.md) — полное руководство для администратора
- [`docs/WHERE_TO_RUN_SCRIPTS.md`](docs/WHERE_TO_RUN_SCRIPTS.md) — на каком CA запускать скрипты

#### Документация по фазам
- [`docs/01_Phase1_Audit_AS-IS.md`](docs/01_Phase1_Audit_AS-IS.md) — Phase 1: Audit (AS-IS)

#### Отчёты и исправления
- [`docs/AUDIT_REPORT.md`](docs/AUDIT_REPORT.md) — отчёт об аудите проекта
- [`docs/AUDIT_FIXES_SUMMARY.md`](docs/AUDIT_FIXES_SUMMARY.md) — сводка исправлений после аудита

#### Runbooks (операционные процедуры)
- [`docs/Runbooks/RootCRL_Runbook.md`](docs/Runbooks/RootCRL_Runbook.md) — публикация Root CA CRL
- [`docs/Runbooks/IssuingCRL_Runbook.md`](docs/Runbooks/IssuingCRL_Runbook.md) — публикация Issuing CA CRL
- [`docs/Runbooks/Rollback_Runbook.md`](docs/Runbooks/Rollback_Runbook.md) — процедура отката изменений

## Лицензия

Внутренний корпоративный проект.

## Авторы

Senior PKI Engineer + DevOps Automation Engineer

---

## English Summary

Enterprise-grade PKI infrastructure audit and alignment tool for Microsoft AD CS. Implements evidence-driven modernization approach without breaking legacy infrastructure. Supports offline Root CA and Enterprise Issuing CA with mixed namespace (legacy + canonical). All operations are read-only by default, require explicit `-Apply` flag, and include backup/rollback capabilities.
