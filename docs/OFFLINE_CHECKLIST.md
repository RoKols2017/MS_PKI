# OFFLINE CHECKLIST

Пошаговый офлайн-чеклист для контура CA0/CA1 без доступа в Интернет.

## 1) Подготовка на CA1

Откройте PowerShell 5.1 от имени администратора и перейдите в корень проекта:

```powershell
Set-Location C:\MS_PKI
$ErrorActionPreference = 'Stop'
```

Создайте рабочие каталоги:

```powershell
New-Item -ItemType Directory -Force -Path .\output,.\output\smoke,.\backup | Out-Null
```

## 2) Сбор параметров CA0

На сервере CA0:

```powershell
.\src\Get-CA0Config.ps1
```

## 3) Подготовка конфига на CA1

Создайте рабочий конфиг:

```powershell
Copy-Item .\config\env.example.json .\config\env.json -Force
```

Заполните `config\env.json` значениями CA0/CA1 и проверьте инициализацию без изменений:

```powershell
.\src\Initialize-PkiConfig.ps1 -WhatIf
```

## 4) Безопасный цикл проверки

Аудит (read-only):

```powershell
.\src\pki-audit\Invoke-PkiAudit.ps1 -Role All -OutputPath .\output\smoke -ConfigPath .\config\env.json -WhatIf
```

Определите свежий baseline:

```powershell
$baseline = Get-ChildItem .\output\smoke\baseline_*.json,.\output\baseline_*.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$baseline.FullName
```

Валидация:

```powershell
.\src\pki-validate\Invoke-PkiValidation.ps1 -ConfigPath .\config\env.json -OutputPath .\output\smoke -BaselinePath $baseline.FullName
```

Alignment только в `-WhatIf`:

```powershell
.\src\pki-align\Invoke-PkiAlignment.ps1 -ConfigPath .\config\env.json -OutputPath .\output\smoke -BaselinePath $baseline.FullName -WhatIf
```

Найдите план alignment:

```powershell
$plan = Get-ChildItem .\output\smoke\alignment_plan_*.json,.\output\alignment_plan_*.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$plan.FullName
```

Проверка rollback в `-WhatIf`:

```powershell
.\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath $plan.FullName -OutputPath .\output\smoke -All -WhatIf
```

## 5) Применение изменений (только в согласованное окно)

Применение с backup:

```powershell
.\src\pki-align\Invoke-PkiAlignment.ps1 -ConfigPath .\config\env.json -OutputPath .\output -Apply -Backup
```

Опционально отдельным этапом: рестарт CertSvc

```powershell
.\src\pki-align\Invoke-PkiAlignment.ps1 -ConfigPath .\config\env.json -OutputPath .\output -Apply -Backup -RestartCertSvc
```

## 6) Откат (при необходимости)

```powershell
.\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath .\output\alignment_plan_*.json -OutputPath .\output -All
```

## Правило безопасности

Всегда: сначала `-WhatIf`, затем `-Apply`. Храните `alignment_plan_*.json` и backup до полного подтверждения результата.
