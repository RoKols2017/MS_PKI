# Phase 1: Audit (AS-IS)

## Описание

Phase 1 — это read-only аудит текущего состояния PKI-инфраструктуры. Скрипт собирает все данные о конфигурации, но не вносит никаких изменений.

## Скрипт

`src/pki-audit/Invoke-PkiAudit.ps1`

## Параметры

| Параметр | Обязательный | Описание |
|----------|---------------|----------|
| `-Role` | Нет | Роль для аудита: `CA0`, `CA1`, `IIS`, `Client`, `All` (по умолчанию: `All`) |
| `-OutputPath` | Да | Путь для сохранения результатов |
| `-ConfigPath` | Нет | Путь к конфигурационному файлу JSON |
| `-IncludeEventLogs` | Нет | Включить сбор Event Logs |
| `-IncludeIisExport` | Нет | Включить экспорт applicationHost.config |
| `-TestCertPath` | Нет | Выполнить certutil -verify -urlfetch |
| `-WhatIf` | Нет | Режим WhatIf (по умолчанию: `$true`) |

## Использование

### Базовый запуск

```powershell
.\src\pki-audit\Invoke-PkiAudit.ps1 -Role All -OutputPath .\output -ConfigPath .\config\env.json
```

### С полным сбором данных

```powershell
.\src\pki-audit\Invoke-PkiAudit.ps1 `
    -Role All `
    -OutputPath .\output `
    -ConfigPath .\config\env.json `
    -IncludeEventLogs `
    -IncludeIisExport `
    -TestCertPath
```

### Аудит только CA1

```powershell
.\src\pki-audit\Invoke-PkiAudit.ps1 -Role CA1 -OutputPath .\output -ConfigPath .\config\env.json
```

## Собираемые данные

### CA0 (Root CA)

1. **Сертификат CA0**
   - Subject, Issuer, Thumbprint
   - Not Before, Not After
   - Serial Number
   - Экспорт в evidence pack

2. **Конфигурация из реестра**
   - CRLPeriod, CRLPeriodUnits
   - CRLOverlapPeriod, CRLOverlapUnits
   - CRLFlags
   - CRLDeltaPeriod, CRLDeltaPeriodUnits
   - CRLPublicationURLs
   - CACertPublicationURLs

3. **CRL файлы**
   - Список всех CRL файлов в CertEnroll
   - Анализ каждого CRL (ThisUpdate, NextUpdate, DaysUntilExpiry)
   - Экспорт CRL в evidence pack

### CA1 (Issuing CA)

1. **Сертификат CA1**
   - Аналогично CA0

2. **Конфигурация из реестра**
   - Аналогично CA0

3. **Шаблоны сертификатов**
   - Список всех шаблонов
   - Версия шаблона (v1/v2/v3)
   - Display Name

4. **Информация о CA**
   - CA Name
   - Common Name
   - Certificate path

5. **Статус службы**
   - CertSvc service status
   - Start Type
   - Проверка доступности (certutil -getconfig -ping)

6. **CRL файлы**
   - Аналогично CA0

7. **Backup реестра**
   - Экспорт реестра CA в .reg файл

### IIS

1. **Информация о сайте**
   - Name, State, Physical Path
   - Bindings (protocol, port, hostname)
   - Virtual Directories

2. **MIME типы**
   - Список всех MIME типов
   - Проверка критичных MIME типов (.crl, .crt, .cer)

3. **ACL для PKI директорий**
   - Права доступа для PKI/AIA, PKI/CDP
   - Права для IIS_IUSRS

4. **HTTP endpoints health check**
   - Проверка доступности всех endpoints из конфигурации
   - Status Code
   - Content Type (если доступен)

5. **applicationHost.config** (опционально)
   - Экспорт полной конфигурации IIS

### Clients

1. **gpresult**
   - Экспорт групповых политик в HTML

2. **certutil -user -pulse**
   - Результаты pulse команды

3. **certutil -verify -urlfetch** (опционально)
   - Проверка цепочки доверия
   - Обнаружение CRYPT_E_REVOCATION_OFFLINE

4. **Event Logs** (опционально)
   - CertificateServicesClient-CertificateEnrollment
   - CertificateServicesClient-AutoEnrollment
   - За последние 24 часа (или из конфигурации)

## Выходные данные

### baseline.json

Машиночитаемый JSON файл со всеми собранными данными.

**Структура**:
```json
{
  "timestamp": "2026-01-22T20:00:00Z",
  "role": "All",
  "config": { ... },
  "ca0": {
    "certificate": { ... },
    "crl": { ... },
    "registry": { ... },
    "crlFiles": [ ... ]
  },
  "ca1": {
    "certificate": { ... },
    "registry": { ... },
    "templates": [ ... ],
    "service": { ... },
    "caInfo": { ... },
    "crlFiles": [ ... ]
  },
  "iis": {
    "sites": [ ... ],
    "mimeTypes": [ ... ],
    "virtualDirs": [ ... ],
    "acls": [ ... ],
    "httpEndpoints": [ ... ]
  },
  "clients": {
    "gpresult": "...",
    "certUtilPulse": [ ... ],
    "certUtilVerify": [ ... ],
    "eventLogs": [ ... ]
  },
  "evidence": {
    "path": "..."
  }
}
```

### AS-IS.md

Человекочитаемый отчёт на русском языке в формате Markdown.

**Содержание**:
- Дата и время аудита
- Роль (CA0, CA1, IIS, Client)
- Время выполнения
- Детальная информация по каждому компоненту
- Ссылка на evidence pack

### Evidence Pack

Директория со всеми собранными данными:

```
evidence_YYYYMMDD_HHMMSS/
├── ca0_certificate.cer
├── ca0_*.crl
├── ca1_certificate.cer
├── ca1_*.crl
├── registry_backup_*.reg
├── applicationHost.config (если -IncludeIisExport)
├── gpresult.html
└── events.json (если -IncludeEventLogs)
```

## Логирование

Все операции логируются в:
- Консоль (цветной вывод)
- Файл логов: `output/logs/pki-YYYYMMDD.log`

**Уровни логирования**:
- `Debug` — детальная информация
- `Info` — информационные сообщения
- `Warning` — предупреждения
- `Error` — ошибки

## Exit Codes

- `0` — успех
- `1` — общая ошибка
- `2` — ошибка конфигурации
- `3` — ошибка доступа (права)

## Примеры использования

### Полный аудит с экспортом всего

```powershell
$outputPath = ".\output\audit_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

.\src\pki-audit\Invoke-PkiAudit.ps1 `
    -Role All `
    -OutputPath $outputPath `
    -ConfigPath .\config\env.json `
    -IncludeEventLogs `
    -IncludeIisExport `
    -TestCertPath
```

### Быстрый аудит только CA и IIS

```powershell
.\src\pki-audit\Invoke-PkiAudit.ps1 `
    -Role CA1,IIS `
    -OutputPath .\output `
    -ConfigPath .\config\env.json
```

## Интерпретация результатов

### Что искать в baseline.json

1. **CRL Expiry**
   - `ca0.crlFiles[].DaysUntilExpiry` — должно быть > 0
   - `ca1.crlFiles[].DaysUntilExpiry` — должно быть > 0

2. **HTTP Availability**
   - `iis.httpEndpoints[].Available` — должно быть `true` для всех

3. **MIME Types**
   - Проверить наличие `.crl` → `application/pkix-crl`
   - Проверить наличие `.crt` → `application/x-x509-ca-cert`

4. **CA Service**
   - `ca1.service.Status` — должно быть `Running`
   - `ca1.caConfigTest` — должно быть `true`

5. **Templates**
   - Проверить отсутствие v1 templates
   - Проверить наличие требуемых шаблонов (User, Computer, WebServer, Service)

## Следующие шаги

После завершения Phase 1:

1. Просмотрите `AS-IS.md` для общего понимания состояния
2. Изучите `baseline.json` для детального анализа
3. Запустите `Invoke-PkiValidation.ps1` для проверки здоровья инфраструктуры
4. Используйте `baseline.json` как входные данные для `Invoke-PkiAlignment.ps1`
