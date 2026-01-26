# Invoke-PkiValidation.ps1
# Валидация PKI-инфраструктуры: проверка здоровья и соответствия best practices

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,
    
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    
    [string]$BaselinePath = ''
)

#region Инициализация

$ErrorActionPreference = 'Stop'
$script:ValidationResults = @{
    timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    checks    = @()
    summary   = @{
        total = 0
        passed = 0
        warning = 0
        failed = 0
    }
}

# Импорт модулей
$libPath = Join-Path $PSScriptRoot '..\lib'
Import-Module (Join-Path $libPath 'Logging.psm1') -Force
Import-Module (Join-Path $libPath 'PkiCommon.psm1') -Force
Import-Module (Join-Path $libPath 'Http.psm1') -Force
Import-Module (Join-Path $libPath 'CertUtil.psm1') -Force

# Инициализация логирования
Initialize-Logging -OutputPath $OutputPath -Level 'Info'
Write-Log -Level Info -Message "Начало валидации PKI" -Operation 'Validation' -OutputPath $OutputPath

# Загрузка конфигурации
$config = Import-PkiConfig -ConfigPath $ConfigPath

# Загрузка baseline (если указан)
$baseline = $null
if ($BaselinePath -and (Test-Path $BaselinePath)) {
    try {
        $baseline = Get-Content -Path $BaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Log -Level Info -Message "Baseline загружен: $BaselinePath" -Operation 'Validation' -OutputPath $OutputPath
    }
    catch {
        Write-Log -Level Warning -Message "Ошибка загрузки baseline: $_" -Operation 'Validation' -OutputPath $OutputPath
    }
}

#endregion

#region Проверки

function Add-ValidationCheck {
    param(
        [string]$Name,
        [string]$Category,
        [ValidateSet('Pass', 'Warning', 'Fail')]
        [string]$Status,
        [string]$Message,
        [object]$Details = $null
    )
    
    $check = @{
        name     = $Name
        category = $Category
        status   = $Status
        message  = $Message
        details  = $Details
        timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    }
    
    $script:ValidationResults.checks += $check
    $script:ValidationResults.summary.total++
    
    switch ($Status) {
        'Pass' {
            $script:ValidationResults.summary.passed++
            Write-Log -Level Info -Message "[PASS] $Name : $Message" -Operation 'Validation' -OutputPath $OutputPath
        }
        'Warning' {
            $script:ValidationResults.summary.warning++
            Write-Log -Level Warning -Message "[WARN] $Name : $Message" -Operation 'Validation' -OutputPath $OutputPath
        }
        'Fail' {
            $script:ValidationResults.summary.failed++
            Write-Log -Level Error -Message "[FAIL] $Name : $Message" -Operation 'Validation' -OutputPath $OutputPath
        }
    }
}

function Test-CRLHttpAvailability {
    Write-Log -Level Info -Message "Проверка доступности CRL по HTTP" -Operation 'Validation' -OutputPath $OutputPath
    
    if (-not $config.endpoints.crlUrls) {
        Add-ValidationCheck -Name 'CRL_HTTP_Availability' -Category 'CRL' -Status 'Warning' -Message 'CRL URLs не настроены в конфигурации'
        return
    }
    
    $allAvailable = $true
    $failedUrls = @()
    
    foreach ($urlTemplate in $config.endpoints.crlUrls) {
        # Замена переменных в шаблоне (упрощённая версия)
        $url = $urlTemplate -replace '\{.*?\}', '*'
        
        # Проверка базового пути
        $baseUrl = $url -replace '/\*\.crl$', ''
        $healthCheck = Test-HttpEndpoint -Url $baseUrl
        
        if (-not $healthCheck.Available) {
            $allAvailable = $false
            $failedUrls += $baseUrl
        }
    }
    
    if ($allAvailable) {
        Add-ValidationCheck -Name 'CRL_HTTP_Availability' -Category 'CRL' -Status 'Pass' -Message 'Все CRL endpoints доступны по HTTP'
    }
    else {
        Add-ValidationCheck -Name 'CRL_HTTP_Availability' -Category 'CRL' -Status 'Fail' -Message "Некоторые CRL endpoints недоступны: $($failedUrls -join ', ')" -Details @{ failedUrls = $failedUrls }
    }
}

function Test-CRLExpiry {
    Write-Log -Level Info -Message "Проверка срока действия CRL" -Operation 'Validation' -OutputPath $OutputPath
    
    $certEnrollPath = $config.iis.certEnrollPath
    if (-not (Test-Path $certEnrollPath)) {
        Add-ValidationCheck -Name 'CRL_Expiry' -Category 'CRL' -Status 'Warning' -Message "CertEnroll путь не найден: $certEnrollPath"
        return
    }
    
    $crlFiles = Get-ChildItem -Path $certEnrollPath -Filter '*.crl' -ErrorAction SilentlyContinue
    if ($crlFiles.Count -eq 0) {
        Add-ValidationCheck -Name 'CRL_Expiry' -Category 'CRL' -Status 'Fail' -Message 'CRL файлы не найдены'
        return
    }
    
    $thresholdDays = if ($config.monitoring.crlExpiryThresholdDays) {
        $config.monitoring.crlExpiryThresholdDays
    }
    else {
        3
    }
    
    $expiredCrls = @()
    $expiringSoonCrls = @()
    
    foreach ($crlFile in $crlFiles) {
        $crlInfo = Get-CACRLInfo -CRLPath $crlFile.FullName
        if ($crlInfo) {
            if ($crlInfo.IsExpired) {
                $expiredCrls += @{
                    file = $crlFile.Name
                    nextUpdate = $crlInfo.NextUpdate
                }
            }
            elseif ($crlInfo.DaysUntilExpiry -lt $thresholdDays) {
                $expiringSoonCrls += @{
                    file = $crlFile.Name
                    daysUntilExpiry = $crlInfo.DaysUntilExpiry
                    nextUpdate = $crlInfo.NextUpdate
                }
            }
        }
    }
    
    if ($expiredCrls.Count -gt 0) {
        Add-ValidationCheck -Name 'CRL_Expiry' -Category 'CRL' -Status 'Fail' -Message "Найдено истёкших CRL: $($expiredCrls.Count)" -Details @{ expiredCrls = $expiredCrls }
    }
    elseif ($expiringSoonCrls.Count -gt 0) {
        Add-ValidationCheck -Name 'CRL_Expiry' -Category 'CRL' -Status 'Warning' -Message "CRL истекают в ближайшие $thresholdDays дней: $($expiringSoonCrls.Count)" -Details @{ expiringSoonCrls = $expiringSoonCrls }
    }
    else {
        Add-ValidationCheck -Name 'CRL_Expiry' -Category 'CRL' -Status 'Pass' -Message "Все CRL актуальны"
    }
}

function Test-CAServiceHealth {
    Write-Log -Level Info -Message "Проверка здоровья CA сервиса" -Operation 'Validation' -OutputPath $OutputPath
    
    $serviceName = $config.ca1.serviceName
    if (-not $serviceName) {
        $serviceName = 'CertSvc'
    }
    
    $service = Get-ServiceStatus -ServiceName $serviceName
    if (-not $service) {
        Add-ValidationCheck -Name 'CA_Service_Health' -Category 'CA' -Status 'Fail' -Message "Служба $serviceName не найдена"
        return
    }
    
    if ($service.Status -ne 'Running') {
        Add-ValidationCheck -Name 'CA_Service_Health' -Category 'CA' -Status 'Fail' -Message "Служба $serviceName не запущена. Статус: $($service.Status)"
    }
    else {
        $caConfigTest = Test-CAService
        if ($caConfigTest) {
            Add-ValidationCheck -Name 'CA_Service_Health' -Category 'CA' -Status 'Pass' -Message "Служба $serviceName работает и доступна"
        }
        else {
            Add-ValidationCheck -Name 'CA_Service_Health' -Category 'CA' -Status 'Warning' -Message "Служба $serviceName запущена, но certutil -getconfig -ping не прошёл"
        }
    }
}

function Test-IisMimeTypes {
    Write-Log -Level Info -Message "Проверка MIME типов IIS" -Operation 'Validation' -OutputPath $OutputPath
    
    $siteName = $config.iis.siteName
    $requiredMimeTypes = @(
        @{ Extension = '.crl'; MimeType = 'application/pkix-crl' }
        @{ Extension = '.crt'; MimeType = 'application/x-x509-ca-cert' }
        @{ Extension = '.cer'; MimeType = 'application/x-x509-ca-cert' }
    )
    
    $missingMimeTypes = @()
    
    foreach ($required in $requiredMimeTypes) {
        $exists = Test-IisMimeType -Extension $required.Extension -MimeType $required.MimeType -SiteName $siteName
        if (-not $exists) {
            $missingMimeTypes += $required
        }
    }
    
    if ($missingMimeTypes.Count -gt 0) {
        Add-ValidationCheck -Name 'IIS_MIME_Types' -Category 'IIS' -Status 'Fail' -Message "Отсутствуют критичные MIME типы: $($missingMimeTypes.Count)" -Details @{ missingMimeTypes = $missingMimeTypes }
    }
    else {
        Add-ValidationCheck -Name 'IIS_MIME_Types' -Category 'IIS' -Status 'Pass' -Message "Все критичные MIME типы настроены"
    }
}

function Test-CertUtilVerify {
    Write-Log -Level Info -Message "Проверка certutil -verify -urlfetch" -Operation 'Validation' -OutputPath $OutputPath
    
    try {
        $output = Get-CertUtilOutput -Arguments @('-verify', '-urlfetch') -IgnoreErrors
        
        $offlineErrors = $output | Where-Object { $_ -match 'CRYPT_E_REVOCATION_OFFLINE' -or $_ -match 'revocation.*offline' }
        
        if ($offlineErrors) {
            Add-ValidationCheck -Name 'CertUtil_Verify' -Category 'Client' -Status 'Warning' -Message "Обнаружены проблемы с проверкой отзыва: CRYPT_E_REVOCATION_OFFLINE" -Details @{ errors = $offlineErrors }
        }
        else {
            Add-ValidationCheck -Name 'CertUtil_Verify' -Category 'Client' -Status 'Pass' -Message "certutil -verify -urlfetch выполнен без критичных ошибок"
        }
    }
    catch {
        Add-ValidationCheck -Name 'CertUtil_Verify' -Category 'Client' -Status 'Warning' -Message "Ошибка выполнения certutil -verify: $_"
    }
}

function Test-CRLPolicyCompliance {
    Write-Log -Level Info -Message "Проверка соответствия CRL политике" -Operation 'Validation' -OutputPath $OutputPath
    
    if (-not $baseline) {
        Add-ValidationCheck -Name 'CRL_Policy_Compliance' -Category 'CRL' -Status 'Warning' -Message 'Baseline не загружен, проверка пропущена'
        return
    }
    
    # Проверка для Issuing CA
    if ($baseline.ca1.registry.CRL) {
        $crl = $baseline.ca1.registry.CRL
        $target = $config.crlPolicyTargets.issuing
        
        $issues = @()
        
        # Проверка validity period
        $currentDays = switch ($crl.PeriodUnits) {
            'Days' { $crl.Period }
            'Weeks' { $crl.Period * 7 }
            'Months' { $crl.Period * 30 }
            default { 0 }
        }
        
        $targetDays = switch ($target.validity.units) {
            'Days' { $target.validity.value }
            'Weeks' { $target.validity.value * 7 }
            'Months' { $target.validity.value * 30 }
            default { 0 }
        }
        
        if ($currentDays -lt $target.validity.min -or $currentDays -gt $target.validity.max) {
            $issues += "CRL validity period ($currentDays дней) вне диапазона best practice ($($target.validity.min)-$($target.validity.max) дней)"
        }
        
        if ($issues.Count -gt 0) {
            Add-ValidationCheck -Name 'CRL_Policy_Compliance' -Category 'CRL' -Status 'Warning' -Message "Обнаружены отклонения от best practices" -Details @{ issues = $issues }
        }
        else {
            Add-ValidationCheck -Name 'CRL_Policy_Compliance' -Category 'CRL' -Status 'Pass' -Message "CRL политика соответствует best practices"
        }
    }
}

#endregion

#region Генерация отчёта

function Export-ValidationReport {
    $reportPath = Join-Path $OutputPath "validation_report_$(Get-Timestamp).md"
    
    $md = @"
# Отчёт валидации PKI-инфраструктуры

**Дата**: $($script:ValidationResults.timestamp)

## Сводка

- **Всего проверок**: $($script:ValidationResults.summary.total)
- **✅ Пройдено**: $($script:ValidationResults.summary.passed)
- **⚠️ Предупреждения**: $($script:ValidationResults.summary.warning)
- **❌ Ошибки**: $($script:ValidationResults.summary.failed)

---

## Детали проверок

"@
    
    foreach ($check in $script:ValidationResults.checks) {
        $icon = switch ($check.status) {
            'Pass' { '✅' }
            'Warning' { '⚠️' }
            'Fail' { '❌' }
        }
        
        $md += @"

### $icon $($check.name) ($($check.category))

**Статус**: $($check.status)  
**Сообщение**: $($check.message)  
**Время**: $($check.timestamp)

"@
        
        if ($check.details) {
            $md += "**Детали**:`n```json`n$($check.details | ConvertTo-Json -Depth 10)`n```\n"
        }
    }
    
    $md += @"

---

## Рекомендации

"@
    
    $failedChecks = $script:ValidationResults.checks | Where-Object { $_.status -eq 'Fail' }
    if ($failedChecks.Count -gt 0) {
        $md += "### Критичные проблемы (требуют немедленного внимания):`n`n"
        foreach ($check in $failedChecks) {
            $md += "- **$($check.name)**: $($check.message)`n"
        }
    }
    
    $warningChecks = $script:ValidationResults.checks | Where-Object { $_.status -eq 'Warning' }
    if ($warningChecks.Count -gt 0) {
        $md += "`n### Предупреждения (рекомендуется исправить):`n`n"
        foreach ($check in $warningChecks) {
            $md += "- **$($check.name)**: $($check.message)`n"
        }
    }
    
    try {
        $md | Out-File -FilePath $reportPath -Encoding UTF8
        Write-Log -Level Info -Message "Отчёт валидации экспортирован: $reportPath" -Operation 'Validation' -OutputPath $OutputPath
        return $reportPath
    }
    catch {
        Write-Log -Level Error -Message "Ошибка экспорта отчёта: $_" -Operation 'Validation' -OutputPath $OutputPath
        return $null
    }
}

#endregion

#region Main

try {
    # Выполнение всех проверок
    Test-CRLHttpAvailability
    Test-CRLExpiry
    Test-CAServiceHealth
    Test-IisMimeTypes
    Test-CertUtilVerify
    Test-CRLPolicyCompliance
    
    # Экспорт отчёта
    $reportPath = Export-ValidationReport
    
    # JSON export
    $jsonPath = Join-Path $OutputPath "validation_results_$(Get-Timestamp).json"
    $script:ValidationResults | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
    
    Write-Host "`n=== Результаты валидации ===" -ForegroundColor Green
    Write-Host "✅ Пройдено: $($script:ValidationResults.summary.passed)" -ForegroundColor Green
    Write-Host "⚠️ Предупреждения: $($script:ValidationResults.summary.warning)" -ForegroundColor Yellow
    Write-Host "❌ Ошибки: $($script:ValidationResults.summary.failed)" -ForegroundColor Red
    Write-Host "`nОтчёт: $reportPath" -ForegroundColor Cyan
    Write-Host "JSON: $jsonPath" -ForegroundColor Cyan
    
    # Exit code
    if ($script:ValidationResults.summary.failed -gt 0) {
        exit 4
    }
    elseif ($script:ValidationResults.summary.warning -gt 0) {
        exit 0
    }
    else {
        exit 0
    }
}
catch {
    Write-Log -Level Error -Message "Критическая ошибка валидации: $_" -Exception $_ -Operation 'Validation' -OutputPath $OutputPath
    exit 1
}

#endregion
