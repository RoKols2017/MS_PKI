# Initialize-PkiConfig.ps1
# Автоматическое заполнение конфигурации env.json на основе обнаруженных параметров системы

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "config\env.json",
    
    [Parameter(Mandatory = $false)]
    [string]$ExampleConfigPath = "config\env.example.json",
    
    [switch]$Force
)

#region Инициализация

$ErrorActionPreference = 'Stop'
$script:DetectedValues = @{}
$script:MissingValues = @()

# Импорт модулей
$libPath = Join-Path $PSScriptRoot 'lib'
if (Test-Path (Join-Path $libPath 'PkiCommon.psm1')) {
    Import-Module (Join-Path $libPath 'PkiCommon.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $libPath 'CertUtil.psm1') -Force -ErrorAction SilentlyContinue
}

#endregion

#region Проверка прав

function Test-RequiredGroups {
    <#
    .SYNOPSIS
    Проверяет, что пользователь входит в необходимые группы.
    
    Требуемые группы:
    - Administrators (локальная группа) - ОБЯЗАТЕЛЬНО
    - Domain Admins (доменная группа) - рекомендуется для получения информации о домене
    #>
    
    $results = @{
        IsAdministrator = $false
        IsDomainAdmin = $false
        Groups = @()
    }
    
    # Проверка локального администратора
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $results.IsAdministrator = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $results.IsAdministrator) {
        Write-Warning "⚠️ Требуются права локального администратора (Administrators)"
        return $results
    }
    
    # Получение групп пользователя
    try {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $groups = $currentUser.Groups | ForEach-Object {
            $_.Translate([System.Security.Principal.NTAccount]).Value
        }
        $results.Groups = $groups
        
        # Проверка Domain Admins
        $domainName = $env:USERDOMAIN
        $results.IsDomainAdmin = $groups -contains "$domainName\Domain Admins" -or 
                                  $groups -contains "BUILTIN\Administrators"
    }
    catch {
        Write-Warning "Не удалось определить группы пользователя: $_"
    }
    
    return $results
}

# Проверка прав
Write-Host "`n=== Проверка прав ===" -ForegroundColor Cyan
$rights = Test-RequiredGroups

if (-not $rights.IsAdministrator) {
    Write-Host "❌ ОШИБКА: Скрипт должен быть запущен с правами локального администратора!" -ForegroundColor Red
    Write-Host "`nТребуемые группы:" -ForegroundColor Yellow
    Write-Host "  - Administrators (локальная группа) - ОБЯЗАТЕЛЬНО" -ForegroundColor Yellow
    Write-Host "  - Domain Admins (доменная группа) - рекомендуется для получения информации о домене" -ForegroundColor Yellow
    exit 3
}

Write-Host "✅ Права локального администратора: OK" -ForegroundColor Green

if ($rights.IsDomainAdmin) {
    Write-Host "✅ Права Domain Admin: OK" -ForegroundColor Green
}
else {
    Write-Host "⚠️ Domain Admin не обнаружен (некоторые параметры могут быть не определены)" -ForegroundColor Yellow
}

#endregion

#region Определение домена

function Get-DomainInfo {
    Write-Host "`n=== Определение домена ===" -ForegroundColor Cyan
    
    try {
        # Попытка через Active Directory модуль
        if (Get-Module -ListAvailable -Name ActiveDirectory) {
            Import-Module ActiveDirectory -ErrorAction SilentlyContinue
            $domain = Get-ADDomain -ErrorAction Stop
            $script:DetectedValues.domain = @{
                name = $domain.DNSRoot
                fqdn = $domain.DNSRoot
                netbios = $domain.NetBIOSName
            }
            Write-Host "✅ Домен определён через AD: $($domain.DNSRoot)" -ForegroundColor Green
            return $true
        }
    }
    catch {
        Write-Warning "Active Directory модуль недоступен: $_"
    }
    
    try {
        # Попытка через System.DirectoryServices
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        $script:DetectedValues.domain = @{
            name = $domain.Name
            fqdn = $domain.Name
            netbios = $domain.GetDirectoryEntry().Properties['name'].Value
        }
        Write-Host "✅ Домен определён: $($domain.Name)" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "Не удалось определить домен через System.DirectoryServices: $_"
    }
    
    try {
        # Попытка через WMI
        $computerSystem = Get-WmiObject -Class Win32_ComputerSystem
        $domainName = $computerSystem.Domain
        if ($domainName) {
            $script:DetectedValues.domain = @{
                name = $domainName
                fqdn = $domainName
                netbios = $domainName.Split('.')[0].ToUpper()
            }
            Write-Host "✅ Домен определён через WMI: $domainName" -ForegroundColor Green
            return $true
        }
    }
    catch {
        Write-Warning "Не удалось определить домен через WMI: $_"
    }
    
    # Fallback через переменные окружения
    $domainName = $env:USERDNSDOMAIN
    if ($domainName) {
        $script:DetectedValues.domain = @{
            name = $domainName
            fqdn = $domainName
            netbios = $env:USERDOMAIN.ToUpper()
        }
        Write-Host "✅ Домен определён через переменные окружения: $domainName" -ForegroundColor Green
        return $true
    }
    
    Write-Host "⚠️ Не удалось автоматически определить домен" -ForegroundColor Yellow
    $script:MissingValues += "domain (name, fqdn, netbios)"
    return $false
}

#endregion

#region Определение CA1

function Get-CA1Info {
    Write-Host "`n=== Определение CA1 (Issuing CA) ===" -ForegroundColor Cyan
    
    # Проверка наличия CA
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration"
    if (-not (Test-Path $regPath)) {
        Write-Host "⚠️ CA не установлен на этом сервере" -ForegroundColor Yellow
        $script:MissingValues += "ca1 (все параметры)"
        return $false
    }
    
    # Получение имени CA из реестра
    $caConfigs = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
    if (-not $caConfigs -or $caConfigs.Count -eq 0) {
        Write-Host "⚠️ CA конфигурация не найдена в реестре" -ForegroundColor Yellow
        $script:MissingValues += "ca1 (все параметры)"
        return $false
    }
    
    $caConfig = $caConfigs | Select-Object -First 1
    $caName = $caConfig.PSChildName
    
    # Получение информации через certutil
    $caInfo = $null
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
                }
            }
        }
    }
    catch {
        Write-Warning "Не удалось получить информацию через certutil: $_"
    }
    
    # Hostname и DNS
    $hostname = $env:COMPUTERNAME
    $fqdn = [System.Net.Dns]::GetHostByName($hostname).HostName
    
    # Если есть домен, формируем полный FQDN
    if ($script:DetectedValues.domain -and $script:DetectedValues.domain.fqdn) {
        if (-not $fqdn.EndsWith($script:DetectedValues.domain.fqdn)) {
            $fqdn = "$hostname.$($script:DetectedValues.domain.fqdn)"
        }
    }
    
    # Определение типа CA
    $caType = "EnterpriseSubordinateCA"  # По умолчанию для Issuing CA
    try {
        $caEntry = Get-ItemProperty -Path $caConfig.PSPath -ErrorAction SilentlyContinue
        if ($caEntry) {
            # Проверка типа через реестр или certutil
            $output = & certutil -getreg CA\CAType 2>&1
            if ($output -match 'Standalone') {
                $caType = "StandaloneRootCA"
            }
        }
    }
    catch {
        # Оставляем значение по умолчанию
    }
    
    # Проверка службы
    $serviceName = "CertSvc"
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Warning "Служба $serviceName не найдена"
    }
    
    $script:DetectedValues.ca1 = @{
        name = if ($caInfo -and $caInfo.CAName) { $caInfo.CAName } else { $caName }
        hostname = $hostname
        dnsName = $fqdn
        commonName = if ($caInfo -and $caInfo.CommonName) { $caInfo.CommonName } else { $caName }
        type = $caType
        status = if ($service -and $service.Status -eq 'Running') { "online" } else { "offline" }
        serviceName = $serviceName
    }
    
    Write-Host "✅ CA1 определён:" -ForegroundColor Green
    Write-Host "   Name: $($script:DetectedValues.ca1.name)" -ForegroundColor Gray
    Write-Host "   Hostname: $hostname" -ForegroundColor Gray
    Write-Host "   DNS: $fqdn" -ForegroundColor Gray
    Write-Host "   Common Name: $($script:DetectedValues.ca1.commonName)" -ForegroundColor Gray
    
    return $true
}

#endregion

#region Определение IIS

function Get-IisInfo {
    Write-Host "`n=== Определение IIS ===" -ForegroundColor Cyan
    
    # Проверка установки IIS
    $iisFeature = Get-WindowsFeature -Name Web-Server -ErrorAction SilentlyContinue
    if (-not $iisFeature -or $iisFeature.InstallState -ne 'Installed') {
        Write-Host "⚠️ IIS не установлен" -ForegroundColor Yellow
        $script:MissingValues += "iis (все параметры)"
        return $false
    }
    
    try {
        Import-Module WebAdministration -ErrorAction Stop
        
        # Получение первого сайта (обычно Default Web Site)
        $sites = Get-WebSite -ErrorAction SilentlyContinue
        if (-not $sites -or $sites.Count -eq 0) {
            Write-Host "⚠️ IIS сайты не найдены" -ForegroundColor Yellow
            $script:MissingValues += "iis.siteName"
            return $false
        }
        
        $defaultSite = $sites | Select-Object -First 1
        $siteName = $defaultSite.Name
        $webRootPath = $defaultSite.PhysicalPath
        
        # Получение bindings
        $bindings = Get-WebBinding -Name $siteName -ErrorAction SilentlyContinue
        $bindingList = @()
        foreach ($binding in $bindings) {
            $bindingInfo = $binding.BindingInformation -split ':'
            $bindingList += @{
                protocol = $binding.Protocol
                port = if ($bindingInfo.Count -gt 1) { $bindingInfo[1] } else { "80" }
                hostname = if ($bindingInfo.Count -gt 2) { $bindingInfo[2] } else { "" }
            }
        }
        
        if ($bindingList.Count -eq 0) {
            $bindingList = @(@{
                protocol = "http"
                port = "80"
                hostname = ""
            })
        }
        
        # Стандартные пути
        $certEnrollPath = "C:\Windows\System32\CertSrv\CertEnroll"
        $pkiWebRoot = Join-Path $webRootPath "PKI"
        
        $script:DetectedValues.iis = @{
            siteName = $siteName
            webRootPath = $webRootPath
            pkiWebRoot = $pkiWebRoot
            certEnrollPath = $certEnrollPath
            bindings = $bindingList
        }
        
        Write-Host "✅ IIS определён:" -ForegroundColor Green
        Write-Host "   Site: $siteName" -ForegroundColor Gray
        Write-Host "   Web Root: $webRootPath" -ForegroundColor Gray
        Write-Host "   CertEnroll: $certEnrollPath" -ForegroundColor Gray
        
        return $true
    }
    catch {
        Write-Warning "Ошибка получения информации о IIS: $_"
        $script:MissingValues += "iis (все параметры)"
        return $false
    }
}

#endregion

#region Определение путей

function Get-PathsInfo {
    Write-Host "`n=== Определение путей ===" -ForegroundColor Cyan
    
    if (-not $script:DetectedValues.iis) {
        Write-Host "⚠️ IIS не определён, используются стандартные пути" -ForegroundColor Yellow
    }
    
    $webRoot = if ($script:DetectedValues.iis -and $script:DetectedValues.iis.webRootPath) {
        $script:DetectedValues.iis.webRootPath
    }
    else {
        "C:\inetpub\wwwroot"
    }
    
    $script:DetectedValues.paths = @{
        certEnrollPath = if ($script:DetectedValues.iis -and $script:DetectedValues.iis.certEnrollPath) {
            $script:DetectedValues.iis.certEnrollPath
        }
        else {
            "C:\Windows\System32\CertSrv\CertEnroll"
        }
        pkiWebRoot = Join-Path $webRoot "PKI"
        pkiAiaPath = Join-Path $webRoot "PKI\AIA"
        pkiCdpPath = Join-Path $webRoot "PKI\CDP"
        legacyCertsPath = Join-Path $webRoot "Certs"
        legacyCertsAiaPath = Join-Path $webRoot "CertsAIA"
    }
    
    Write-Host "✅ Пути определены:" -ForegroundColor Green
    Write-Host "   PKI Web Root: $($script:DetectedValues.paths.pkiWebRoot)" -ForegroundColor Gray
    Write-Host "   PKI AIA: $($script:DetectedValues.paths.pkiAiaPath)" -ForegroundColor Gray
    Write-Host "   PKI CDP: $($script:DetectedValues.paths.pkiCdpPath)" -ForegroundColor Gray
    
    return $true
}

#endregion

#region Формирование endpoints

function Get-EndpointsInfo {
    Write-Host "`n=== Формирование endpoints ===" -ForegroundColor Cyan
    
    if (-not $script:DetectedValues.ca1 -or -not $script:DetectedValues.ca1.dnsName) {
        Write-Host "⚠️ CA1 не определён, endpoints не могут быть сформированы" -ForegroundColor Yellow
        return $false
    }
    
    $hostname = $script:DetectedValues.ca1.dnsName
    
    $script:DetectedValues.endpoints = @{
        healthCheck = @(
            "http://$hostname/PKI/AIA",
            "http://$hostname/PKI/CDP",
            "http://$hostname/Certs",
            "http://$hostname/CertsAIA"
        )
        crlUrls = @(
            "http://$hostname/PKI/CDP/{CAName}{CRLNameSuffix}{DeltaCRLAllowed}.crl",
            "http://$hostname/Certs/{CAName}{CRLNameSuffix}{DeltaCRLAllowed}.crl"
        )
        aiaUrls = @(
            "http://$hostname/PKI/AIA/{CAName}_{CertificateName}.crt",
            "http://$hostname/CertsAIA/{CAName}_{CertificateName}.crt"
        )
    }
    
    Write-Host "✅ Endpoints сформированы на основе $hostname" -ForegroundColor Green
    
    return $true
}

#endregion

#region Создание конфигурации

function New-PkiConfig {
    Write-Host "`n=== Создание конфигурации ===" -ForegroundColor Cyan
    
    # Проверка существования файла
    if (Test-Path $ConfigPath) {
        if (-not $Force) {
            Write-Host "⚠️ Файл конфигурации уже существует: $ConfigPath" -ForegroundColor Yellow
            $response = Read-Host "Перезаписать? (y/N)"
            if ($response -ne 'y' -and $response -ne 'Y') {
                Write-Host "Операция отменена" -ForegroundColor Yellow
                return $false
            }
        }
        Write-Host "Файл будет перезаписан" -ForegroundColor Yellow
    }
    
    # Загрузка примера
    if (-not (Test-Path $ExampleConfigPath)) {
        Write-Host "❌ Файл примера не найден: $ExampleConfigPath" -ForegroundColor Red
        return $false
    }
    
    try {
        $config = Get-Content -Path $ExampleConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Host "❌ Ошибка загрузки примера конфигурации: $_" -ForegroundColor Red
        return $false
    }
    
    # Заполнение обнаруженных значений
    if ($script:DetectedValues.domain) {
        $config.domain = $script:DetectedValues.domain
    }
    
    if ($script:DetectedValues.ca1) {
        $config.ca1.name = $script:DetectedValues.ca1.name
        $config.ca1.hostname = $script:DetectedValues.ca1.hostname
        $config.ca1.dnsName = $script:DetectedValues.ca1.dnsName
        $config.ca1.commonName = $script:DetectedValues.ca1.commonName
        $config.ca1.type = $script:DetectedValues.ca1.type
        $config.ca1.status = $script:DetectedValues.ca1.status
        $config.ca1.serviceName = $script:DetectedValues.ca1.serviceName
    }
    
    if ($script:DetectedValues.iis) {
        $config.iis.siteName = $script:DetectedValues.iis.siteName
        $config.iis.webRootPath = $script:DetectedValues.iis.webRootPath
        $config.iis.pkiWebRoot = $script:DetectedValues.iis.pkiWebRoot
        $config.iis.certEnrollPath = $script:DetectedValues.iis.certEnrollPath
        if ($script:DetectedValues.iis.bindings) {
            $config.iis.bindings = $script:DetectedValues.iis.bindings
        }
    }
    
    if ($script:DetectedValues.paths) {
        $config.paths = $script:DetectedValues.paths
    }
    
    if ($script:DetectedValues.endpoints) {
        $config.endpoints = $script:DetectedValues.endpoints
    }
    
    # Сохранение конфигурации
    try {
        $configDir = Split-Path -Path $ConfigPath -Parent
        if (-not (Test-Path $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }
        
        $config | ConvertTo-Json -Depth 10 | Out-File -FilePath $ConfigPath -Encoding UTF8 -Force
        Write-Host "✅ Конфигурация сохранена: $ConfigPath" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "❌ Ошибка сохранения конфигурации: $_" -ForegroundColor Red
        return $false
    }
}

#endregion

#region Main

Write-Host @"
╔══════════════════════════════════════════════════════════════╗
║  PKI Configuration Initialization Script                    ║
║  Автоматическое заполнение конфигурации env.json            ║
╚══════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

# Выполнение обнаружения
Get-DomainInfo | Out-Null
Get-CA1Info | Out-Null
Get-IisInfo | Out-Null
Get-PathsInfo | Out-Null
Get-EndpointsInfo | Out-Null

# Создание конфигурации
$created = New-PkiConfig

if ($created) {
    Write-Host "`n=== РЕЗУЛЬТАТЫ ===" -ForegroundColor Green
    Write-Host "✅ Конфигурация создана: $ConfigPath" -ForegroundColor Green
    
    if ($script:MissingValues.Count -gt 0) {
        Write-Host "`n⚠️ Требуется ручное заполнение следующих параметров:" -ForegroundColor Yellow
        foreach ($missing in $script:MissingValues) {
            Write-Host "   - $missing" -ForegroundColor Yellow
        }
        Write-Host "`nОткройте файл и заполните недостающие параметры:" -ForegroundColor Cyan
        Write-Host "   notepad $ConfigPath" -ForegroundColor White
    }
    else {
        Write-Host "`n✅ Все основные параметры заполнены автоматически!" -ForegroundColor Green
    }
    
    # Специальное напоминание о CA0
    Write-Host "`n📝 ВАЖНО: Заполните параметры CA0 (Root CA) вручную:" -ForegroundColor Cyan
    Write-Host "   - ca0.name" -ForegroundColor Gray
    Write-Host "   - ca0.hostname" -ForegroundColor Gray
    Write-Host "   - ca0.dnsName" -ForegroundColor Gray
    Write-Host "   - ca0.commonName" -ForegroundColor Gray
    Write-Host "`nCA0 обычно находится на отдельном сервере (offline)" -ForegroundColor Gray
    
    Write-Host "`n✅ Готово! Проверьте конфигурацию перед использованием." -ForegroundColor Green
    exit 0
}
else {
    Write-Host "`n❌ Не удалось создать конфигурацию" -ForegroundColor Red
    exit 1
}

#endregion
