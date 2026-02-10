# Get-CA0Config.ps1
# Сбор параметров CA0 (Root CA) для заполнения env.json
# Запускать на CA0 сервере под администратором

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('JSON', 'Text', 'Both')]
    [string]$OutputFormat = 'Both'
)

#region Инициализация

$ErrorActionPreference = 'Stop'
$script:CA0Config = @{}

# Импорт модулей (опционально, если доступны)
$libPath = Join-Path $PSScriptRoot 'lib'
if (Test-Path (Join-Path $libPath 'PkiCommon.psm1')) {
    Import-Module (Join-Path $libPath 'PkiCommon.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $libPath 'CertUtil.psm1') -Force -ErrorAction SilentlyContinue
}

#endregion

#region Проверка прав

function Test-Administrator {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host @"
╔══════════════════════════════════════════════════════════════╗
║  CA0 Configuration Collector                                 ║
║  Сбор параметров Root CA для env.json                        ║
╚══════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

Write-Host "`n=== Проверка прав ===" -ForegroundColor Cyan

if (-not (Test-Administrator)) {
    Write-Host "❌ ОШИБКА: Скрипт должен быть запущен с правами локального администратора!" -ForegroundColor Red
    Write-Host "`nТребуемые группы:" -ForegroundColor Yellow
    Write-Host "  - Administrators (локальная группа) - ОБЯЗАТЕЛЬНО" -ForegroundColor Yellow
    exit 3
}

Write-Host "✅ Права локального администратора: OK" -ForegroundColor Green

#endregion

#region Определение CA0

function Get-CA0Info {
    Write-Host "`n=== Определение CA0 (Root CA) ===" -ForegroundColor Cyan
    
    # Проверка наличия CA
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration"
    if (-not (Test-Path $regPath)) {
        Write-Host "❌ CA не установлен на этом сервере" -ForegroundColor Red
        Write-Host "Убедитесь, что скрипт запущен на CA0 (Root CA) сервере" -ForegroundColor Yellow
        return $false
    }
    
    # Получение имени CA из реестра
    $caConfigs = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
    if (-not $caConfigs -or $caConfigs.Count -eq 0) {
        Write-Host "❌ CA конфигурация не найдена в реестре" -ForegroundColor Red
        return $false
    }
    
    $caConfig = $caConfigs | Select-Object -First 1
    $caName = $caConfig.PSChildName
    
    Write-Host "Найдена CA конфигурация: $caName" -ForegroundColor Gray
    
    # Получение информации через certutil
    $caInfo = $null
    $commonName = $null
    
    try {
        $output = & certutil -cainfo 2>&1
        foreach ($line in $output) {
            if ($line -match 'CA Name:\s*(.+)') {
                $caInfo = @{
                    CAName = $matches[1].Trim()
                }
            }
            if ($line -match 'Common Name:\s*(.+)') {
                if ($caInfo) {
                    $caInfo.CommonName = $matches[1].Trim()
                    $commonName = $matches[1].Trim()
                }
            }
        }
    }
    catch {
        Write-Warning "Не удалось получить информацию через certutil: $_"
    }
    
    # Hostname и DNS
    $hostname = $env:COMPUTERNAME
    
    # Попытка получить FQDN
    $fqdn = $null
    try {
        $fqdn = [System.Net.Dns]::GetHostEntry($hostname).HostName
    }
    catch {
        Write-Warning "Не удалось определить FQDN через DNS: $_"
    }
    
    # Если FQDN не определён, попробуем через домен
    if (-not $fqdn -or $fqdn -eq $hostname) {
        $domainName = $env:USERDNSDOMAIN
        if ($domainName) {
            $fqdn = "$hostname.$domainName"
        }
        else {
            $fqdn = $hostname
        }
    }
    
    # Определение типа CA
    $caType = "StandaloneRootCA"  # По умолчанию для Root CA
    try {
        $caEntry = Get-ItemProperty -Path $caConfig.PSPath -ErrorAction SilentlyContinue
        if ($caEntry) {
            # Проверка типа через certutil
            $output = & certutil -getreg CA\CAType 2>&1
            if ($output -match 'Enterprise') {
                $caType = "EnterpriseRootCA"
            }
        }
    }
    catch {
        # Оставляем значение по умолчанию
    }
    
    # Проверка статуса службы
    $serviceName = "CertSvc"
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    $status = if ($service -and $service.Status -eq 'Running') {
        "online"
    }
    else {
        "offline"
    }
    
    # Получение CRL политики из реестра
    $crlPeriod = $null
    $crlPeriodUnits = $null
    $crlOverlap = $null
    $crlOverlapUnits = $null
    
    try {
        $fullRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\$caName"
        $crlPeriod = (Get-ItemProperty -Path $fullRegPath -Name 'CRLPeriod' -ErrorAction SilentlyContinue).CRLPeriod
        $crlPeriodUnits = (Get-ItemProperty -Path $fullRegPath -Name 'CRLPeriodUnits' -ErrorAction SilentlyContinue).CRLPeriodUnits
        $crlOverlap = (Get-ItemProperty -Path $fullRegPath -Name 'CRLOverlapPeriod' -ErrorAction SilentlyContinue).CRLOverlapPeriod
        $crlOverlapUnits = (Get-ItemProperty -Path $fullRegPath -Name 'CRLOverlapUnits' -ErrorAction SilentlyContinue).CRLOverlapUnits
    }
    catch {
        Write-Warning "Не удалось получить CRL политику из реестра: $_"
    }
    
    # Конвертация единиц времени в читаемый формат
    $validityValue = $crlPeriod
    $validityUnits = switch ($crlPeriodUnits) {
        0 { "Hours" }
        1 { "Days" }
        2 { "Weeks" }
        3 { "Months" }
        4 { "Years" }
        default { "Days" }
    }
    
    $overlapValue = $crlOverlap
    $overlapUnits = switch ($crlOverlapUnits) {
        0 { "Hours" }
        1 { "Days" }
        2 { "Weeks" }
        3 { "Months" }
        4 { "Years" }
        default { "Days" }
    }
    
    # Если значения не получены, используем значения по умолчанию для Root CA
    if (-not $validityValue) {
        $validityValue = 12
        $validityUnits = "Months"
    }
    if (-not $overlapValue) {
        $overlapValue = 2
        $overlapUnits = "Weeks"
    }
    
    $script:CA0Config = @{
        name = if ($caInfo -and $caInfo.CAName) { $caInfo.CAName } else { $caName }
        hostname = $hostname
        dnsName = $fqdn
        commonName = if ($commonName) { $commonName } else { $caName }
        type = $caType
        status = $status
        crlPolicy = @{
            validityPeriod = @{
                value = $validityValue
                units = $validityUnits
            }
            overlapPeriod = @{
                value = $overlapValue
                units = $overlapUnits
            }
            deltaCRL = $false
        }
    }
    
    Write-Host "✅ CA0 определён:" -ForegroundColor Green
    Write-Host "   Name: $($script:CA0Config.name)" -ForegroundColor Gray
    Write-Host "   Hostname: $hostname" -ForegroundColor Gray
    Write-Host "   DNS: $fqdn" -ForegroundColor Gray
    Write-Host "   Common Name: $($script:CA0Config.commonName)" -ForegroundColor Gray
    Write-Host "   Type: $caType" -ForegroundColor Gray
    Write-Host "   Status: $status" -ForegroundColor Gray
    Write-Host "   CRL Validity: $validityValue $validityUnits" -ForegroundColor Gray
    Write-Host "   CRL Overlap: $overlapValue $overlapUnits" -ForegroundColor Gray
    
    return $true
}

#endregion

#region Вывод результатов

function Show-TextOutput {
    Write-Host "`n=== ПАРАМЕТРЫ CA0 ДЛЯ КОПИРОВАНИЯ ===" -ForegroundColor Green
    Write-Host "`nСкопируйте следующие параметры в секцию 'ca0' файла env.json на CA1:" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host '"ca0": {' -ForegroundColor White
    Write-Host "  `"name`": `"$($script:CA0Config.name)`"," -ForegroundColor Yellow
    Write-Host "  `"hostname`": `"$($script:CA0Config.hostname)`"," -ForegroundColor Yellow
    Write-Host "  `"dnsName`": `"$($script:CA0Config.dnsName)`"," -ForegroundColor Yellow
    Write-Host "  `"commonName`": `"$($script:CA0Config.commonName)`"," -ForegroundColor Yellow
    Write-Host "  `"type`": `"$($script:CA0Config.type)`"," -ForegroundColor Yellow
    Write-Host "  `"status`": `"$($script:CA0Config.status)`"," -ForegroundColor Yellow
    Write-Host "  `"crlPolicy`": {" -ForegroundColor White
    Write-Host "    `"validityPeriod`": {" -ForegroundColor White
    Write-Host "      `"value`": $($script:CA0Config.crlPolicy.validityPeriod.value)," -ForegroundColor Yellow
    Write-Host "      `"units`": `"$($script:CA0Config.crlPolicy.validityPeriod.units)`"" -ForegroundColor Yellow
    Write-Host "    }," -ForegroundColor White
    Write-Host "    `"overlapPeriod`": {" -ForegroundColor White
    Write-Host "      `"value`": $($script:CA0Config.crlPolicy.overlapPeriod.value)," -ForegroundColor Yellow
    Write-Host "      `"units`": `"$($script:CA0Config.crlPolicy.overlapPeriod.units)`"" -ForegroundColor Yellow
    Write-Host "    }," -ForegroundColor White
    Write-Host "    `"deltaCRL`": $($script:CA0Config.crlPolicy.deltaCRL.ToString().ToLower())" -ForegroundColor Yellow
    Write-Host "  }" -ForegroundColor White
    Write-Host "}" -ForegroundColor White
}

function Show-JsonOutput {
    Write-Host "`n=== JSON ДЛЯ КОПИРОВАНИЯ ===" -ForegroundColor Green
    Write-Host "`nСкопируйте следующий JSON в секцию 'ca0' файла env.json на CA1:" -ForegroundColor Cyan
    Write-Host ""
    
    # Выводим только содержимое (без обертки ca0), так как это для вставки в секцию ca0
    $json = $script:CA0Config | ConvertTo-Json -Depth 10
    
    Write-Host $json -ForegroundColor Yellow
}

function Show-CompleteJson {
    Write-Host "`n=== ПОЛНЫЙ JSON (только секция ca0) ===" -ForegroundColor Green
    Write-Host "`nГотовый JSON для вставки в env.json:" -ForegroundColor Cyan
    Write-Host ""
    
    $json = $script:CA0Config | ConvertTo-Json -Depth 10
    Write-Host $json -ForegroundColor Yellow
}

#endregion

#region Main

# Выполнение сбора информации
$success = Get-CA0Info

if (-not $success) {
    Write-Host "`n❌ Не удалось собрать информацию о CA0" -ForegroundColor Red
    Write-Host "Убедитесь, что:" -ForegroundColor Yellow
    Write-Host "  - Скрипт запущен на CA0 (Root CA) сервере" -ForegroundColor Yellow
    Write-Host "  - AD CS установлен и настроен" -ForegroundColor Yellow
    Write-Host "  - У вас есть права локального администратора" -ForegroundColor Yellow
    exit 1
}

# Вывод результатов
switch ($OutputFormat) {
    'JSON' {
        Show-CompleteJson
    }
    'Text' {
        Show-TextOutput
    }
    'Both' {
        Show-TextOutput
        Write-Host "`n" + ("=" * 60) -ForegroundColor Gray
        Show-CompleteJson
    }
}

Write-Host "`n=== ИНСТРУКЦИИ ===" -ForegroundColor Cyan
Write-Host "1. Скопируйте параметры выше" -ForegroundColor White
Write-Host "2. На CA1 сервере откройте config\env.json" -ForegroundColor White
Write-Host "3. Вставьте скопированные параметры в секцию 'ca0'" -ForegroundColor White
Write-Host "4. Сохраните файл" -ForegroundColor White
Write-Host "5. Проверьте синтаксис JSON: Get-Content config\env.json | ConvertFrom-Json" -ForegroundColor White

Write-Host "`n✅ Готово!" -ForegroundColor Green
exit 0

#endregion
