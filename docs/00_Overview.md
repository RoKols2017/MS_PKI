# Обзор проекта: PKI Infrastructure Audit & Alignment Tool

## Назначение

Проект предназначен для автоматизированного аудита и безопасного выравнивания PKI-инфраструктуры на базе Microsoft Active Directory Certificate Services (AD CS) без нарушения работы существующих систем.

## Архитектура инфраструктуры

### Схема доверия

```
CA0 (Offline Root CA)
    ↓
CA1 (Enterprise Issuing CA)
    ↓
    Сертификаты (User, Computer, WebServer, Service)
```

### Компоненты

- **CA0** — Offline Root CA (Standalone Root CA)
  - Работает в автономном режиме
  - Windows Server 2016
  - CRL публикуется через IIS на CA1
  - Долгий срок действия CRL (6-12 месяцев)

- **CA1** — Enterprise Issuing CA (Enterprise Subordinate CA)
  - Онлайн сервер
  - Windows Server 2022
  - AD CS + IIS
  - IIS используется для публикации AIA/CDP (HTTP)
  - Короткий срок действия CRL (7-14 дней)

### Namespace

#### Legacy (сохраняется для совместимости)

- `/Certs` — старые CRL
- `/CertsAIA` — старые AIA сертификаты
- `/IssCA/*` — legacy пути
- `/ssCA/*` — legacy пути

**Важно**: Legacy пути никогда не удаляются, они остаются как compatibility layer для старых сертификатов.

#### Canonical (новый стандарт)

- `/PKI/AIA` — Authority Information Access
- `/PKI/CDP` — CRL Distribution Points

**Принцип**: Новые пути добавляются параллельно со старыми, не заменяя их.

## Фазы проекта

### Phase 1: Audit (AS-IS)

**Режим**: Read-only

**Цель**: Собрать полную картину текущего состояния PKI-инфраструктуры.

**Сбор данных**:
- Конфигурация CA (Root и Issuing)
- IIS конфигурация и публикация AIA/CDP
- Шаблоны сертификатов
- Autoenrollment настройки
- CRL статус и доступность
- Event Logs анализ

**Выход**:
- `baseline.json` — машиночитаемый снимок состояния
- `AS-IS.md` — человекочитаемый отчёт на русском языке
- Evidence pack — все собранные данные

### Phase 2: Stabilization

**Цель**: Устранение критических рисков, минимальные безопасные изменения.

**Действия**:
- Исправление критичных проблем с CRL
- Восстановление доступности endpoints
- Исправление конфигурационных ошибок

### Phase 3: Standardization

**Цель**: Определение правил, политик, канонической модели.

**Результат**:
- Документированные best practices
- Правила конфигурации
- Политики CRL
- Стандарты шаблонов

### Phase 4: Alignment

**Режим**: WhatIf (по умолчанию) или Apply

**Цель**: Контролируемые изменения конфигурации с backup и rollback.

**Изменения**:
- Добавление canonical путей (без удаления legacy)
- Настройка MIME типов IIS
- Выравнивание ACL
- Копирование CRL в IIS директории
- Обновление CRLPublicationURLs (добавление, не замена)

**Безопасность**:
- Backup обязателен
- Rollback point создаётся автоматически
- Изменения только при `-Apply`
- Legacy не удаляется

### Phase 5: Validation & Documentation

**Цель**: Проверка изменений и генерация документации.

**Проверки**:
- HTTP health check AIA/CDP
- CRL NextUpdate анализ
- certutil -verify -urlfetch
- CRYPT_E_REVOCATION_OFFLINE detection

**Документация**:
- AS-IS состояние
- TO-BE состояние
- Описание изменений
- Rollback инструкции
- Runbooks

### Phase 6: Future Readiness

**Цель**: Подготовка к масштабированию (CA2, дополнительные Issuing CA).

## Принципы безопасности

1. **Read-only по умолчанию** — все скрипты работают в режиме чтения
2. **Backup обязателен** — перед любыми изменениями создаётся backup
3. **Rollback обязателен** — каждая операция может быть отменена
4. **Legacy сохраняется** — старые пути не удаляются
5. **Evidence-driven** — все изменения основаны на собранных данных
6. **Zero-downtime** — изменения не должны вызывать простои
7. **CRL-first** — приоритет доступности CRL

**Категорически запрещено**:
- Удаление CA
- Re-root PKI
- Массовый перевыпуск сертификатов
- Удаление legacy путей
- Изменение trust chain

## Best Practices

### Root CA (CA0)

- **CRL Validity**: 6-12 месяцев (целевое 12 месяцев)
- **CRL Overlap**: 1-2 недели
- **Delta CRL**: обычно не используется
- **Status**: Offline
- **CRL Publication**: через IIS на CA1

### Issuing CA (CA1)

- **CRL Validity**: 7-14 дней
- **CRL Overlap**: 1 день
- **Delta CRL**: рекомендуется
- **Status**: Online
- **CRL Publication**: HTTP-first, множественные пути

### Templates

- **v1 templates**: deprecated, не использовать
- **v2+ templates**: обязательно
- **Subject Name**: from AD
- **Autoenrollment**: через GPO
- **EKU**: по назначению (User, Computer, WebServer, Service)

### Autoenrollment

- **Control-plane**: GPO
- **Модель**: централизованная
- **OU + Security Filtering**: для управления scope
- **Monitoring**: через Event Logs

### HTTP (IIS)

- **Основной транспорт**: AIA/CDP
- **MIME types**:
  - `.crl` → `application/pkix-crl`
  - `.crt/.cer` → `application/x-x509-ca-cert`
- **Access**: Read-only
- **Namespace**: Legacy + Canonical параллельно

## Использование

### 1. Конфигурация

Скопируйте `config/env.example.json` в `config/env.json` и заполните параметры вашей инфраструктуры.

### 2. Аудит (Phase 1)

```powershell
.\src\pki-audit\Invoke-PkiAudit.ps1 -Role All -OutputPath .\output -ConfigPath .\config\env.json
```

### 3. Валидация

```powershell
.\src\pki-validate\Invoke-PkiValidation.ps1 -ConfigPath .\config\env.json -OutputPath .\output -BaselinePath .\output\baseline_*.json
# Опционально: -CertificatePath "C:\certs\test.cer"
```

### 4. Выравнивание (WhatIf режим)

```powershell
.\src\pki-align\Invoke-PkiAlignment.ps1 -ConfigPath .\config\env.json -OutputPath .\output -BaselinePath .\output\baseline_*.json -WhatIf
```

### 5. Применение изменений

```powershell
.\src\pki-align\Invoke-PkiAlignment.ps1 -ConfigPath .\config\env.json -OutputPath .\output -BaselinePath .\output\baseline_*.json -Apply -Backup
```

## Структура проекта

```
/
├── src/
│   ├── pki-audit/      # Phase 1: Аудит
│   ├── pki-validate/   # Валидация
│   ├── pki-align/      # Phase 4: Выравнивание
│   └── lib/            # Библиотечные модули
├── docs/               # Документация (RU)
├── config/             # Конфигурация
├── output/             # Результаты работы скриптов
└── rules/              # Правила безопасности
```

## Требования

- Windows Server 2016+ (для CA)
- PowerShell 5.1+
- AD CS установлен и настроен
- IIS установлен (для публикации AIA/CDP)
- Права: Domain Admin или Local Administrator на CA серверах

## Выходные данные

### Baseline JSON

Машиночитаемый снимок текущего состояния инфраструктуры. Используется для:
- Сравнения состояний до/после изменений
- Планирования изменений
- Валидации конфигурации

### AS-IS Markdown

Человекочитаемый отчёт на русском языке с описанием:
- Текущего состояния CA
- Конфигурации IIS
- Статуса CRL
- Шаблонов сертификатов
- Обнаруженных проблем

### Evidence Pack

Собранные данные для анализа:
- Экспорт реестра CA
- IIS конфигурация
- Сертификаты и CRL
- Event Logs
- Результаты certutil команд

## Мониторинг

### Критичные метрики

- **CRL Expiry**: CRL не должны истекать
- **HTTP Availability**: Все endpoints должны быть доступны
- **CA Service**: Служба CertSvc должна работать
- **MIME Types**: Критичные MIME типы должны быть настроены

### Пороги

- **CRL Expiry Threshold**: 3 дня (по умолчанию)
- **Health Check Timeout**: 10 секунд

## Поддержка

Внутренний корпоративный проект. Для вопросов обращайтесь к команде PKI Engineering.

## Связанные документы

- [`README.md`](../README.md) — главный файл проекта
- [`QUICKSTART.md`](../QUICKSTART.md) — быстрый старт
- [`docs/01_Phase1_Audit_AS-IS.md`](01_Phase1_Audit_AS-IS.md) — Phase 1: Audit
- [`docs/ADMIN_START_GUIDE.md`](ADMIN_START_GUIDE.md) — руководство для администратора
- [`docs/WHERE_TO_RUN_SCRIPTS.md`](WHERE_TO_RUN_SCRIPTS.md) — на каком CA запускать скрипты
- [`rules/PKI_RULES.md`](../rules/PKI_RULES.md) — правила безопасности
