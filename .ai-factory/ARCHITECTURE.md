# Architecture: Modular Monolith

## Overview
The project follows a modular monolith architecture: one repository and one operational deployment contour, with strict boundaries between scenario modules and shared libraries. This pattern preserves operational simplicity, which is critical for PKI environments where change windows are controlled and rollback must remain predictable.

For MS_PKI, modules are aligned with operational phases (`audit`, `validate`, `align`, `rollback`) and orchestrated through top-level scripts. Shared domain and infrastructure concerns are centralized in `src/lib`, while state-changing operations remain explicitly gated by safe execution semantics (`WhatIf`/`Apply`, backup, rollback).

## Decision Rationale
- **Project type:** Security-first PowerShell automation for PKI audit and safe alignment
- **Tech stack:** PowerShell 5.1+, native script/module architecture on Windows Server
- **Key factor:** Need for strict module boundaries with low operational complexity and high rollback reliability

## Folder Structure
```text
src/
├── pki-audit/
│   └── Invoke-PkiAudit.ps1            # Read-only evidence collection
├── pki-validate/
│   └── Invoke-PkiValidation.ps1       # Baseline/consistency checks
├── pki-align/
│   └── Invoke-PkiAlignment.ps1        # Controlled alignment + plan generation
├── pki-rollback/
│   └── Invoke-PkiRollback.ps1         # Rollback execution from alignment plan
├── lib/
│   ├── Logging.psm1                   # Cross-cutting logging
│   ├── PkiCommon.psm1                 # Shared helpers and data handling
│   ├── PkiSecurity.psm1               # Security/path/url validation helpers
│   ├── Http.psm1                      # HTTP checks and fetch helpers
│   └── CertUtil.psm1                  # certutil integration wrappers
├── Initialize-PkiConfig.ps1           # Config bootstrap
└── Get-CA0Config.ps1                  # Offline root config collection

rules/
└── PKI_RULES.md                       # Non-negotiable security and change rules

docs/
└── Runbooks/                          # Operational runbooks and rollout guidance
```

## Dependency Rules
- ✅ Scenario scripts in `src/pki-*` can depend on `src/lib/*`
- ✅ Shared modules can depend only on stable PowerShell/.NET APIs and project rules
- ✅ `pki-rollback` can consume artifacts produced by `pki-align`
- ❌ Modules must not call internal, non-exported functions from another scenario module
- ❌ `pki-audit` and `pki-validate` must not perform infrastructure mutations
- ❌ State-changing actions without explicit `-Apply` support are forbidden

## Layer/Module Communication
- Entry script (`Invoke-*`) acts as module boundary and orchestration point
- Cross-module reuse happens through exported functions in `src/lib/*.psm1`
- Alignment/rollback communicate via explicit JSON artifacts (`alignment_plan_*.json`, backups)
- Side effects are guarded by `ShouldProcess` and should be safe in `-WhatIf`

## Key Principles
1. Security and backward compatibility override implementation speed.
2. Read-only by default; mutations are explicit, auditable, and reversible.
3. Keep module contracts stable (CLI parameters, output artifacts, legacy namespace behavior).

## Code Examples

### Scenario module using shared library
```powershell
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

$libPath = Join-Path $PSScriptRoot '..\lib'
Import-Module (Join-Path $libPath 'Logging.psm1') -Force
Import-Module (Join-Path $libPath 'PkiSecurity.psm1') -Force

Write-Log -Level Info -Message 'Alignment module started.'

if ($Apply -and $PSCmdlet.ShouldProcess('PKI configuration', 'Apply alignment changes')) {
    Write-Log -Level Info -Message 'Applying changes in controlled mode.'
}
```

### Public function boundary in shared module
```powershell
function Test-SafeAlignmentInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    if (-not (Test-SafeFilePath -Path $Path)) {
        throw "Unsafe path: $Path"
    }

    if (-not (Test-UrlFormat -Url $Url)) {
        throw "Invalid URL format: $Url"
    }

    return $true
}

Export-ModuleMember -Function Test-SafeAlignmentInput
```

## Anti-Patterns
- ❌ Embedding state-changing logic directly into validation/audit code paths
- ❌ Bypassing `src/lib` and duplicating security checks in each scenario script
- ❌ Breaking artifact compatibility between alignment and rollback flows
- ❌ Silent error swallowing without `Write-Log` context and deterministic failure behavior
