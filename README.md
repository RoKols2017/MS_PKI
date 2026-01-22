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
│   ├── 02_Phase2_Stabilization.md
│   ├── 03_Phase3_Standardization.md
│   ├── 04_Phase4_Alignment.md
│   ├── 05_Phase5_Validation.md
│   └── Runbooks/
│       ├── RootCRL_Runbook.md
│       ├── IssuingCRL_Runbook.md
│       ├── Autoenrollment_Runbook.md
│       └── CA_Decommission_Runbook.md
├── config/
│   └── env.example.json
├── output/
│   └── (генерируется скриптами)
├── rules/
│   └── PKI_RULES.md
└── README.md
```

## Быстрый старт

### 1. Конфигурация

Скопируйте `config/env.example.json` в `config/env.json` и заполните параметры вашей инфраструктуры.

### 2. Аудит (Phase 1)

```powershell
.\src\pki-audit\Invoke-PkiAudit.ps1 -Role All -OutputPath .\output -ConfigPath .\config\env.json
```

### 3. Валидация

```powershell
.\src\pki-validate\Invoke-PkiValidation.ps1 -ConfigPath .\config\env.json -OutputPath .\output
```

### 4. Выравнивание (WhatIf режим)

```powershell
.\src\pki-align\Invoke-PkiAlignment.ps1 -ConfigPath .\config\env.json -OutputPath .\output -WhatIf
```

### 5. Применение изменений

```powershell
.\src\pki-align\Invoke-PkiAlignment.ps1 -ConfigPath .\config\env.json -OutputPath .\output -Apply -Backup
```

### 6. Откат изменений (если требуется)

```powershell
# Откат всех изменений
.\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath .\output\alignment_plan_*.json -OutputPath .\output -All

# Откат выборочных изменений
.\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath .\output\alignment_plan_*.json -OutputPath .\output -ChangeIds @("change-id-1", "change-id-2")

# WhatIf режим для проверки плана отката
.\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath .\output\alignment_plan_*.json -OutputPath .\output -All -WhatIf
```

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

## Лицензия

Внутренний корпоративный проект.

## Авторы

Senior PKI Engineer + DevOps Automation Engineer

---

## English Summary

Enterprise-grade PKI infrastructure audit and alignment tool for Microsoft AD CS. Implements evidence-driven modernization approach without breaking legacy infrastructure. Supports offline Root CA and Enterprise Issuing CA with mixed namespace (legacy + canonical). All operations are read-only by default, require explicit `-Apply` flag, and include backup/rollback capabilities.
