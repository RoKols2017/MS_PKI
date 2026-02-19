# PreProd Test Runbook

## Цель

Пошагово протестировать все основные PowerShell-сценарии перед production-окном и снизить риск сюрпризов.

Контур:
- CA0 (Offline Root CA): Windows Server 2016
- CA1 (Issuing CA): Windows Server 2022

## Принципы

- Только PowerShell, без GUI-операций в процессе проверки.
- Сначала полный `-WhatIf`/dry-run, затем apply-репетиция, затем rollback-репетиция.
- Любой `Fail` в validate = stop и разбор до продолжения.
- Изменения с влиянием на CRL/AIA/CertSvc считать `Change-impact: High`.

## Этап 0: Подготовка

```powershell
$ErrorActionPreference = 'Stop'
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$out = ".\output\preprod_$ts"
New-Item -ItemType Directory -Path $out -Force | Out-Null
```

Проверить, что конфиг существует:

```powershell
Test-Path .\config\env.json
```

## Этап 1: Линт и синтаксис

```powershell
Invoke-ScriptAnalyzer -Path .\src -Recurse -Severity Warning,Error
```

Опционально точечный parse-check:

```powershell
$files = @(
  '.\src\lib\PkiCommon.psm1',
  '.\src\lib\PkiSecurity.psm1',
  '.\src\lib\CertUtil.psm1',
  '.\src\pki-align\Invoke-PkiAlignment.ps1'
)
foreach ($f in $files) {
  $tokens = $null; $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count -gt 0) { throw "Parse error in $f" }
}
```

## Этап 2: Последовательный dry-run всех скриптов

```powershell
# 1) Initialize
.\src\Initialize-PkiConfig.ps1 -WhatIf

# 2) CA0 config collector
.\src\Get-CA0Config.ps1 -WhatIf

# 3) Audit
.\src\pki-audit\Invoke-PkiAudit.ps1 -Role All -OutputPath $out -ConfigPath .\config\env.json -WhatIf

# 4) Baseline для validate/alignment
$baseline = Get-ChildItem "$out\baseline_*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $baseline) { throw 'Baseline не создан после audit.' }

# 5) Validate
.\src\pki-validate\Invoke-PkiValidation.ps1 -ConfigPath .\config\env.json -OutputPath $out -BaselinePath $baseline.FullName

# 6) Alignment plan only
.\src\pki-align\Invoke-PkiAlignment.ps1 -ConfigPath .\config\env.json -OutputPath $out -BaselinePath $baseline.FullName -WhatIf

# 7) Rollback plan only
$plan = Get-ChildItem "$out\alignment_plan_*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($plan) {
  .\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath $plan.FullName -OutputPath $out -All -WhatIf
}
```

## Этап 3: Идемпотентность

Повторить этап 2 второй раз на новом каталоге `output`.

Критерии:
- Не появляется неожиданных новых типов изменений в alignment plan.
- Нет дублирования CRL publication entries.
- Validate не ухудшается (нет новых `Fail`).

## Этап 4: Репетиция apply (pre-prod)

```powershell
$outApply = ".\output\preprod_apply_$ts"
New-Item -ItemType Directory -Path $outApply -Force | Out-Null

$baselineApply = Get-ChildItem "$out\baseline_*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1

# Apply без рестарта CertSvc
.\src\pki-align\Invoke-PkiAlignment.ps1 -ConfigPath .\config\env.json -OutputPath $outApply -BaselinePath $baselineApply.FullName -Apply -Backup

# Немедленная проверка
.\src\pki-validate\Invoke-PkiValidation.ps1 -ConfigPath .\config\env.json -OutputPath $outApply -BaselinePath $baselineApply.FullName
```

Если нужен controlled restart (только в согласованное окно):

```powershell
.\src\pki-align\Invoke-PkiAlignment.ps1 -ConfigPath .\config\env.json -OutputPath $outApply -BaselinePath $baselineApply.FullName -Apply -Backup -RestartCertSvc
```

## Этап 5: Репетиция rollback

```powershell
$planApply = Get-ChildItem "$outApply\alignment_plan_*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $planApply) { throw 'Не найден alignment plan после apply.' }

# If host has multiple CA configs, set -CAName explicitly
.\src\pki-rollback\Invoke-PkiRollback.ps1 -AlignmentPlanPath $planApply.FullName -OutputPath $outApply -All

# Post-rollback validate
.\src\pki-validate\Invoke-PkiValidation.ps1 -ConfigPath .\config\env.json -OutputPath $outApply -BaselinePath $baselineApply.FullName
```

## Этап 6: Критерии готовности к production

- Нет новых `Fail` в validation.
- Alignment/rollback воспроизводимы и предсказуемы.
- Для `CRL_Publication` нет потери существующих entries.
- Все артефакты сохранены: baseline, validation report/json, alignment plan, rollback log.

## План на завтра

- Дата целевого прогона: **2026-02-20**.
- Рекомендуемый порядок: Этапы 0 -> 1 -> 2 -> 3 -> 4 -> 5 -> 6.
- Если на любом шаге есть `Fail`, переход к следующему этапу запрещён до устранения причины.
