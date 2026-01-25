# Руководство: Get-CA0Config.ps1

## Описание

Скрипт `Get-CA0Config.ps1` собирает параметры CA0 (Root CA) на сервере CA0 и выводит их в удобном формате для копирования в `env.json` на CA1 сервере.

## Назначение

CA0 обычно находится на отдельном сервере (offline), поэтому автоматическое определение параметров CA0 на CA1 невозможно. Этот скрипт решает проблему, собирая информацию на самом CA0 сервере.

## Требования

### Группы пользователя

**Обязательные:**
- **Administrators** (локальная группа) — для доступа к реестру, службам, certutil

### Где запускать

**На CA0 (Root CA) сервере** — скрипт должен запускаться на том же сервере, где установлен Root CA.

## Использование

### Базовый запуск

```powershell
.\src\Get-CA0Config.ps1
```

Скрипт выведет параметры в двух форматах:
- Текстовый формат (для визуального просмотра)
- JSON формат (для копирования)

### Только JSON

```powershell
.\src\Get-CA0Config.ps1 -OutputFormat JSON
```

### Только текстовый формат

```powershell
.\src\Get-CA0Config.ps1 -OutputFormat Text
```

## Что собирается автоматически

### ✅ CA0 параметры

**Методы определения:**
1. Реестр: `HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\*`
2. certutil: `certutil -cainfo`
3. Системные параметры: `$env:COMPUTERNAME`, DNS
4. Реестр: CRL политика (CRLPeriod, CRLPeriodUnits, CRLOverlapPeriod, CRLOverlapUnits)

**Определяемые параметры:**
- `ca0.name` — имя CA из реестра или certutil
- `ca0.hostname` — имя компьютера
- `ca0.dnsName` — FQDN сервера
- `ca0.commonName` — Common Name из certutil
- `ca0.type` — тип CA (StandaloneRootCA или EnterpriseRootCA)
- `ca0.status` — online/offline (на основе статуса службы CertSvc)
- `ca0.crlPolicy.validityPeriod` — период действия CRL (value, units)
- `ca0.crlPolicy.overlapPeriod` — период overlap CRL (value, units)
- `ca0.crlPolicy.deltaCRL` — использование Delta CRL (обычно false для Root CA)

## Пример вывода

### Текстовый формат

```
=== ПАРАМЕТРЫ CA0 ДЛЯ КОПИРОВАНИЯ ===

Скопируйте следующие параметры в секцию 'ca0' файла env.json на CA1:

"ca0": {
  "name": "CONTOSO-Root-CA",
  "hostname": "CA0-ROOT",
  "dnsName": "ca0-root.contoso.local",
  "commonName": "CONTOSO Root CA",
  "type": "StandaloneRootCA",
  "status": "offline",
  "crlPolicy": {
    "validityPeriod": {
      "value": 12,
      "units": "Months"
    },
    "overlapPeriod": {
      "value": 2,
      "units": "Weeks"
    },
    "deltaCRL": false
  }
}
```

### JSON формат

```json
{
  "name": "CONTOSO-Root-CA",
  "hostname": "CA0-ROOT",
  "dnsName": "ca0-root.contoso.local",
  "commonName": "CONTOSO Root CA",
  "type": "StandaloneRootCA",
  "status": "offline",
  "crlPolicy": {
    "validityPeriod": {
      "value": 12,
      "units": "Months"
    },
    "overlapPeriod": {
      "value": 2,
      "units": "Weeks"
    },
    "deltaCRL": false
  }
}
```

## Процедура использования

### Шаг 1: Запуск на CA0

**На CA0 сервере:**

```powershell
# Включите CA0 сервер (если он offline)
# Войдите с правами локального администратора
# Откройте PowerShell от имени администратора

# Перейдите в директорию проекта (если проект скопирован на CA0)
cd "C:\path\to\MS_PKI"

# Запустите скрипт
.\src\Get-CA0Config.ps1
```

### Шаг 2: Копирование параметров

1. Скопируйте выведенные параметры (JSON или текстовый формат)
2. Сохраните в текстовый файл или буфер обмена

### Шаг 3: Вставка в env.json на CA1

**На CA1 сервере:**

```powershell
# Откройте env.json
notepad config\env.json

# Найдите секцию "ca0" и замените её скопированными параметрами
# Или вставьте, если секция пустая
```

### Шаг 4: Проверка

```powershell
# Проверка синтаксиса JSON
$config = Get-Content config\env.json -Raw -Encoding UTF8 | ConvertFrom-Json

# Проверка параметров CA0
$config.ca0 | Format-List

# Должно вывести все параметры CA0
```

## Troubleshooting

### Проблема: "CA не установлен на этом сервере"

**Причины:**
- Скрипт запущен не на CA0 сервере
- AD CS не установлен
- CA не настроен

**Решение:**
1. Убедитесь, что скрипт запущен на CA0 (Root CA) сервере
2. Проверьте установку AD CS: `Get-WindowsFeature | Where-Object { $_.Name -like "*ADCS*" }`
3. Проверьте наличие CA в реестре: `Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration"`

### Проблема: "Требуются права локального администратора"

**Решение:**
- Запустите PowerShell от имени администратора
- Убедитесь, что вы в группе Administrators

### Проблема: "Не удалось определить FQDN"

**Решение:**
- Проверьте настройки DNS на сервере
- Проверьте, что сервер в домене
- FQDN можно указать вручную в env.json

### Проблема: "Не удалось получить CRL политику"

**Решение:**
- Скрипт использует значения по умолчанию (12 месяцев, 2 недели overlap)
- Можно скорректировать вручную в env.json после копирования

## Альтернативный способ (ручное заполнение)

Если скрипт недоступен или не работает, можно заполнить параметры вручную:

1. **ca0.name** — получить через `certutil -cainfo` или реестр
2. **ca0.hostname** — `$env:COMPUTERNAME` на CA0
3. **ca0.dnsName** — FQDN сервера CA0
4. **ca0.commonName** — из сертификата Root CA или `certutil -cainfo`
5. **ca0.type** — обычно "StandaloneRootCA" для offline Root CA
6. **ca0.status** — обычно "offline"
7. **ca0.crlPolicy** — получить через `certutil -getreg CA\CRLPeriod` и `certutil -getreg CA\CRLPeriodUnits`

## Связанные документы

- [`docs/Initialize-PkiConfig_Guide.md`](Initialize-PkiConfig_Guide.md) — автоматическое заполнение на CA1
- [`docs/WHERE_TO_RUN_SCRIPTS.md`](WHERE_TO_RUN_SCRIPTS.md) — на каком CA запускать скрипты
- [`QUICKSTART.md`](../QUICKSTART.md) — быстрый старт

## Важные напоминания

- ⚠️ Скрипт запускается на **CA0**, а не на CA1
- ⚠️ Результаты копируются вручную в env.json на **CA1**
- ⚠️ Проверьте синтаксис JSON после вставки
- ⚠️ Убедитесь, что все параметры заполнены корректно
