# Changelog

Все значимые изменения в проекте документируются в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.0.0/).

## [1.3.0] - 2026-02-16

### Исправлено
- `Invoke-PkiAudit.ps1`: защита от null config — все обращения к `$script:AuditData.config.*` теперь с проверкой наличия config и вложенных свойств. Добавлено предупреждение при отсутствии ConfigPath для ролей All/IIS/Client.
- `Invoke-PkiAlignment.ps1`: формирование CRL URL использует `dnsName` (FQDN) вместо `hostname` для корректной работы с клиентами.
- `Invoke-PkiAlignment.ps1` и `Invoke-PkiRollback.ps1`: получение имени CA через `Get-ChildItem` вместо ненадёжного `Get-ItemProperty` с wildcard в пути реестра.
- `Invoke-PkiValidation.ps1`: null-проверки для config.endpoints, config.iis, config.ca1, config.monitoring, baseline.ca1.registry, config.crlPolicyTargets.

### Добавлено
- `PkiCommon.psm1`: функция `Test-PkiConfig` для валидации обязательных полей env.json. Параметр `-ForAlignment` для проверки полей, необходимых Alignment.
- Вызов `Test-PkiConfig` после загрузки конфигурации в `Invoke-PkiValidation.ps1` и `Invoke-PkiAlignment.ps1`.

## [1.2.0] - 2026-02-10

### Изменено
- Полностью актуализирован `Invoke-PkiAlignment.ps1`: исправлен синтаксис, сохранены режимы `WhatIf/Apply`, экспорт плана выравнивания и применение изменений по action type.
- `Invoke-PkiRollback.ps1` обновлён для работы с сериализуемым планом изменений (без scriptblock в JSON), добавлен fallback по `category` и поддержка `ShouldProcess`.
- `Invoke-PkiValidation.ps1`: добавлен параметр `-CertificatePath` для явного сертификата в `certutil -verify -urlfetch`, добавлен безопасный fallback автопоиска сертификата.
- `Initialize-PkiConfig.ps1` и `Get-CA0Config.ps1`: заменены deprecated вызовы DNS/WMI на актуальные API.

### Безопасность
- `PkiSecurity.psm1`: усилена защита от path traversal (проверка границ сегментов пути).
- `PkiSecurity.psm1`: `Test-WritePermissions` расширен режимом `-Provider Registry` для корректной проверки прав записи в реестр.

### Документация
- Актуализированы примеры запуска в `README.md`, `QUICKSTART.md`, `docs/00_Overview.md`, `docs/ADMIN_START_GUIDE.md`, `docs/WHERE_TO_RUN_SCRIPTS.md`, `docs/Runbooks/Rollback_Runbook.md`.
- Добавлены пояснения по использованию `-CertificatePath` в сценариях валидации.

## [1.1.1] - 2026-01-26

### Исправлено
- Исправлен `.gitignore`: добавлено исключение `!config/env.example.json` после общего правила `*.json` для корректной публикации примера конфигурации в репозиторий

## [1.1.0] - 2026-01-22

### Добавлено
- Модуль безопасности `PkiSecurity.psm1` с функциями:
  - `Test-PathTraversal` — защита от path traversal
  - `Test-SafeFilePath` — проверка безопасности путей
  - `Test-CAExists` — проверка существования CA
  - `Test-CRLIntegrity` — проверка целостности CRL
  - `Test-UrlFormat` — валидация URL
  - `Test-WritePermissions` — проверка прав на запись
- Скрипт отката изменений `Invoke-PkiRollback.ps1`
- Rollback функции для всех типов изменений:
  - MIME типы IIS
  - ACL директорий
  - CRLPublicationURLs
  - Копирование CRL файлов
- Документация:
  - `docs/AUDIT_REPORT.md` — полный отчёт об аудите
  - `docs/AUDIT_FIXES_SUMMARY.md` — резюме исправлений
  - `docs/Runbooks/Rollback_Runbook.md` — runbook по откату изменений

### Изменено
- `Invoke-PkiAlignment.ps1`:
  - Исправлены switch параметры (убраны значения по умолчанию)
  - Добавлена проверка существования CA перед изменением реестра
  - Добавлена валидация URL перед записью в реестр
  - Добавлена проверка целостности CRL перед копированием
  - Добавлена защита от path traversal при копировании файлов
  - Улучшена обработка ошибок
  - Добавлены rollback функции для всех операций
- `README.md`:
  - Добавлена информация о rollback
  - Обновлена структура проекта
  - Добавлены новые принципы безопасности
- `QUICKSTART.md`:
  - Добавлены примеры использования rollback

### Исправлено
- CRITICAL-1: Отсутствие rollback функций
- CRITICAL-2: Отсутствие валидации перед изменением реестра CA
- CRITICAL-3: Отсутствие защиты от path traversal
- CRITICAL-4: Небезопасное копирование файлов
- CRITICAL-5: Отсутствие проверки существования CA перед операциями
- CRITICAL-6: Отсутствие валидации значений реестра
- CRITICAL-7: Отсутствие проверки целостности CRL перед копированием
- CRITICAL-8: Неправильное использование switch параметров

### Безопасность
- Добавлена защита от path traversal атак
- Добавлена валидация всех входных данных
- Добавлена проверка прав доступа перед операциями
- Добавлена проверка целостности данных
- Улучшена безопасность копирования файлов

## [1.0.0] - 2026-01-22

### Добавлено
- Скрипт аудита `Invoke-PkiAudit.ps1`
- Скрипт валидации `Invoke-PkiValidation.ps1`
- Скрипт выравнивания `Invoke-PkiAlignment.ps1`
- Библиотечные модули:
  - `PkiCommon.psm1` — общие функции
  - `Logging.psm1` — структурированное логирование
  - `Http.psm1` — работа с HTTP и IIS
  - `CertUtil.psm1` — работа с certutil и сертификатами
- Документация:
  - `README.md` — основная документация
  - `QUICKSTART.md` — быстрый старт
  - `docs/00_Overview.md` — обзор проекта
  - `docs/01_Phase1_Audit_AS-IS.md` — документация по аудиту
  - `docs/Runbooks/RootCRL_Runbook.md` — runbook для Root CA CRL
  - `docs/Runbooks/IssuingCRL_Runbook.md` — runbook для Issuing CA CRL
- Правила безопасности `rules/PKI_RULES.md`
- Пример конфигурации `config/env.example.json`

---

## Типы изменений

- **Добавлено** — новые функции
- **Изменено** — изменения в существующей функциональности
- **Устарело** — функции, которые скоро будут удалены
- **Удалено** — удалённые функции
- **Исправлено** — исправления ошибок
- **Безопасность** — изменения, связанные с безопасностью
