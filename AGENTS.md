# AGENTS.md

## Назначение
Инструкция для агентных код-ассистентов в репозитории `MS_PKI`.
Проект: PowerShell-автоматизация аудита, валидации и безопасного выравнивания PKI (Microsoft AD CS).
Базовый приоритет: безопасность и обратная совместимость выше скорости изменений.

## Контекст репозитория
- Основные сценарии: `src/pki-audit`, `src/pki-validate`, `src/pki-align`, `src/pki-rollback`
- Подготовка конфигурации: `src/Initialize-PkiConfig.ps1`, `src/Get-CA0Config.ps1`
- Общие модули: `src/lib/*.psm1`
- Правила безопасности: `rules/PKI_RULES.md`
- Операционные инструкции: `README.md`, `QUICKSTART.md`, `docs/Runbooks`

## Cursor/Copilot rules
Проверено:
- `.cursorrules` отсутствует
- `.cursor/rules/` отсутствует
- `.github/copilot-instructions.md` отсутствует

Следовательно, обязательные правила берём из:
1. `rules/PKI_RULES.md`
2. Сложившихся конвенций в `src/**/*.ps1` и `src/lib/**/*.psm1`

## Требования окружения
- Windows Server (скрипты ориентированы на CA-серверы)
- PowerShell 5.1+
- AD CS и IIS для полных сценариев
- Права администратора (многие скрипты завершаются с `exit 3` без них)

## Build / Lint / Test
Важно: в репозитории нет отдельного build-процесса и нет выделенных `*.Tests.ps1`/`tests/`.

### Build
- Классического build нет.
- Эквивалент проверки готовности: smoke-прогон сценариев в `-WhatIf`.

### Lint
Установка анализатора (если отсутствует):

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
```

Проверить весь `src`:

```powershell
Invoke-ScriptAnalyzer -Path .\src -Recurse -Severity Warning,Error
```

Проверить один файл (single-file):

```powershell
Invoke-ScriptAnalyzer -Path .\src\pki-align\Invoke-PkiAlignment.ps1 -Severity Warning,Error
```

Синтаксическая проверка одного файла:

```powershell
$tokens = $null; $errors = $null; [System.Management.Automation.Language.Parser]::ParseFile('.\src\lib\PkiSecurity.psm1',[ref]$tokens,[ref]$errors) | Out-Null; $errors
```

### Test
Автотестов Pester пока нет; «тесты» в этом проекте — целевые безопасные прогоны сценариев.

Полезные команды:

```powershell
# Audit
.\src\pki-audit\Invoke-PkiAudit.ps1 -Role All -OutputPath .\output -ConfigPath .\config\env.json -WhatIf

# Validate
.\src\pki-validate\Invoke-PkiValidation.ps1 -ConfigPath .\config\env.json -OutputPath .\output -BaselinePath .\output\baseline_*.json

# Alignment dry-run
.\src\pki-align\Invoke-PkiAlignment.ps1 -ConfigPath .\config\env.json -OutputPath .\output -BaselinePath .\output\baseline_*.json -WhatIf

# Rollback dry-run
.\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath .\output\alignment_plan_*.json -OutputPath .\output -All -WhatIf
```

Single test (наиболее близкий эквивалент одного тест-кейса):

```powershell
# Узкий сценарий: аудит только CA1
.\src\pki-audit\Invoke-PkiAudit.ps1 -Role CA1 -OutputPath .\output\single -ConfigPath .\config\env.json -WhatIf
```

Если позже добавятся Pester-тесты, для одного тест-файла:

```powershell
Invoke-Pester -Path .\tests\SomeFeature.Tests.ps1 -Output Detailed
```

## Ключевые правила безопасности
- Изменения инфраструктуры только при явном `-Apply`
- Перед изменениями обязателен backup
- Для изменяющих операций обязателен rollback
- Legacy namespace не удалять и не ломать
- Запрещены: удаление CA, re-root, массовый перевыпуск сертификатов
- Приоритет доступности CRL (CRL-first)

## Код-стиль: обязательные конвенции

### PowerShell каркас
- Использовать `[CmdletBinding()]`; для изменения состояния — `SupportsShouldProcess = $true`
- В начале top-level скриптов задавать `$ErrorActionPreference = 'Stop'`
- Явно типизировать параметры (`[string]`, `[switch]`, `[string[]]`, `[object]`)
- Для ограниченных значений применять `[ValidateSet(...)]`
- Отступы 4 пробела; придерживаться существующего brace-стиля

### Импорты и модули
- Строить пути через `Join-Path`, не через строковую конкатенацию
- Типовой шаблон: `$libPath = Join-Path $PSScriptRoot '..\lib'`
- Импортировать только нужные модули (`Logging`, `PkiCommon`, `Http`, `CertUtil`, `PkiSecurity`)
- В `.psm1` экспортировать публичные функции через `Export-ModuleMember`

### Именование
- Функции: `Verb-Noun` (например, `Test-CRLIntegrity`, `Import-PkiConfig`)
- Переменные: `camelCase`
- Разделяемое состояние: `$script:*`
- Ключи JSON/hashtable обычно `lowerCamelCase`

### Форматирование и данные
- JSON: `ConvertFrom-Json` / `ConvertTo-Json` с адекватной `-Depth`
- Логи и JSON писать в UTF-8
- Для `.ps1`/`.psm1` в этом репо предпочтителен UTF-8 with BOM (`ENCODING_FIX.md`)

### Ошибки и логирование
- Критичные блоки оборачивать в `try/catch`
- Логировать через `Write-Log` с уровнем `Info/Warning/Error`
- Не скрывать ошибки без fallback-логики
- Соблюдать проектные exit codes (см. `rules/PKI_RULES.md`)

### Изменяющие операции
- Использовать `ShouldProcess` и поддерживать `WhatIf`
- Перед записью в реестр/ФС делать валидации безопасности
- Для путей и URL использовать проверки (`Test-PathTraversal`, `Test-SafeFilePath`, `Test-UrlFormat`)

## Практика для агентов
1. Перед правками прочитать `rules/PKI_RULES.md` и затронутые скрипты.
2. Сначала предлагать/выполнять безопасный `-WhatIf` путь.
3. Не менять поведение без синхронизации документации.
4. При добавлении изменений в alignment сразу продумывать rollback.
5. После правок минимум: lint + узкий функциональный прогон.
6. Не вносить изменения, конфликтующие с legacy совместимостью.

## Запрещённые паттерны
- «Магические» значения без конфигурации
- Операции с путями без проверок безопасности
- Неявные изменения инфраструктуры без `-Apply`
- Удаление legacy endpoints/virtual directories
- Непроверенные зависимости, несовместимые с PowerShell 5.1+

## Минимальный чеклист перед завершением
- Правка соответствует `rules/PKI_RULES.md`
- Пройден `Invoke-ScriptAnalyzer` для изменённых файлов
- Есть подтверждение поведения через `-WhatIf` или узкий функциональный прогон
- Документация обновлена, если изменился контракт/CLI/поток
- Не нарушены запреты (CA deletion, re-root, массовый reissue)
