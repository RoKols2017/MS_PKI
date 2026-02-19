# Invoke-PkiAudit.ps1
# Phase 1: AS-IS Audit (Read-Only)
# Автоматизированный аудит PKI-инфраструктуры на базе Microsoft AD CS

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('CA0', 'CA1', 'IIS', 'Client', 'All')]
    [string]$Role = 'All',
    
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = '',
    
    [switch]$IncludeEventLogs,
    [switch]$IncludeIisExport,
    [switch]$TestCertPath
)

#region Инициализация

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:StartTime = Get-Date
$script:AuditData = @{
    timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    role      = $Role
    config    = $null
    ca0       = @{}
    ca1       = @{}
    iis       = @{}
    clients   = @{}
    evidence  = @{}
}

# Импорт модулей
$libPath = Join-Path $PSScriptRoot '..\lib'
Import-Module (Join-Path $libPath 'Logging.psm1') -Force
Import-Module (Join-Path $libPath 'PkiCommon.psm1') -Force
Import-Module (Join-Path $libPath 'Http.psm1') -Force
Import-Module (Join-Path $libPath 'CertUtil.psm1') -Force

# Инициализация логирования
Initialize-Logging -OutputPath $OutputPath -Level 'Info'
Write-Log -Level Info -Message "Начало аудита PKI. Роль: $Role" -Operation 'Audit' -Role $Role -OutputPath $OutputPath

# Проверка прав
try {
    Assert-Administrator
}
catch {
    Write-Log -Level Error -Message $_ -Operation 'Audit' -OutputPath $OutputPath
    exit 3
}

# Загрузка конфигурации
if ($ConfigPath -and (Test-Path $ConfigPath)) {
    try {
        $script:AuditData.config = Import-PkiConfig -ConfigPath $ConfigPath
        Write-Log -Level Info -Message "Конфигурация загружена: $ConfigPath" -Operation 'Audit' -OutputPath $OutputPath
    }
    catch {
        Write-Log -Level Warning -Message "Ошибка загрузки конфигурации: $_" -Operation 'Audit' -OutputPath $OutputPath
    }
}
elseif ($Role -in @('All', 'IIS', 'Client')) {
    Write-Log -Level Warning -Message "Конфигурация не загружена (ConfigPath пустой или файл не найден). Роли IIS/Client используют значения по умолчанию. Рекомендуется указать -ConfigPath." -Operation 'Audit' -OutputPath $OutputPath
}

# Создание директорий для evidence
$evidencePath = Join-Path $OutputPath "evidence_$(Get-Timestamp)"
Test-PathExists -Path $evidencePath -CreateIfNotExists | Out-Null
$script:AuditData.evidence.path = $evidencePath

#endregion

#region CA0 Audit (Root CA)

function Invoke-CA0Audit {
    Write-Log -Level Info -Message "Аудит CA0 (Root CA)" -Operation 'CA0Audit' -Role 'CA0' -OutputPath $OutputPath
    
    $ca0Data = @{
        certificate = $null
        crl         = @{}
        registry    = @{}
        crlFiles    = @()
    }
    
    # Сертификат CA0
    try {
        $ca0Data.certificate = Get-CACertificate
        if ($ca0Data.certificate) {
            Write-Log -Level Info -Message "Сертификат CA0 получен: $($ca0Data.certificate.Subject)" -Operation 'CA0Audit' -OutputPath $OutputPath
        }
    }
    catch {
        Write-Log -Level Warning -Message "Ошибка получения сертификата CA0: $_" -Operation 'CA0Audit' -OutputPath $OutputPath
    }
    
    # Конфигурация из реестра
    try {
        $ca0Data.registry = Get-CARegistryConfig -CAName '*'
        Write-Log -Level Info -Message "Конфигурация CA0 из реестра получена" -Operation 'CA0Audit' -OutputPath $OutputPath
    }
    catch {
        Write-Log -Level Warning -Message "Ошибка получения конфигурации CA0: $_" -Operation 'CA0Audit' -OutputPath $OutputPath
    }
    
    # CRL файлы
    $certEnrollPath = if ($script:AuditData.config -and $script:AuditData.config.iis -and $script:AuditData.config.iis.certEnrollPath) {
        $script:AuditData.config.iis.certEnrollPath
    }
    else {
        'C:\Windows\System32\CertSrv\CertEnroll'
    }
    
    if (Test-Path $certEnrollPath) {
        $crlFiles = Get-ChildItem -Path $certEnrollPath -Filter '*.crl' -ErrorAction SilentlyContinue
        foreach ($crlFile in $crlFiles) {
            $crlInfo = Get-CACRLInfo -CRLPath $crlFile.FullName
            if ($crlInfo) {
                $ca0Data.crlFiles += $crlInfo
            }
        }
        Write-Log -Level Info -Message "Найдено CRL файлов: $($ca0Data.crlFiles.Count)" -Operation 'CA0Audit' -OutputPath $OutputPath
    }
    
    # Экспорт сертификата и CRL в evidence
    if ($ca0Data.certificate.Path) {
        $evidenceCertPath = Join-Path $evidencePath "ca0_certificate.cer"
        Copy-Item -Path $ca0Data.certificate.Path -Destination $evidenceCertPath -ErrorAction SilentlyContinue
    }
    elseif ($ca0Data.certificate.RawDataBase64) {
        try {
            $evidenceCertPath = Join-Path $evidencePath "ca0_certificate.cer"
            [System.IO.File]::WriteAllBytes($evidenceCertPath, [System.Convert]::FromBase64String([string]$ca0Data.certificate.RawDataBase64))
        }
        catch {
            Write-Log -Level Warning -Message "Ошибка экспорта сертификата CA0 в evidence: $_" -Operation 'CA0Audit' -OutputPath $OutputPath
        }
    }
    
    foreach ($crlInfo in $ca0Data.crlFiles) {
        if ($crlInfo.Path) {
            $evidenceCrlPath = Join-Path $evidencePath "ca0_$(Split-Path $crlInfo.Path -Leaf)"
            Copy-Item -Path $crlInfo.Path -Destination $evidenceCrlPath -ErrorAction SilentlyContinue
        }
    }
    
    $script:AuditData.ca0 = $ca0Data
}

#endregion

#region CA1 Audit (Issuing CA)

function Invoke-CA1Audit {
    Write-Log -Level Info -Message "Аудит CA1 (Issuing CA)" -Operation 'CA1Audit' -Role 'CA1' -OutputPath $OutputPath
    
    $ca1Data = @{
        certificate  = $null
        crl          = @{}
        registry     = @{}
        crlFiles     = @()
        templates    = @()
        service      = $null
        caInfo       = @{}
        caConfigTest = $false
    }
    
    # Сертификат CA1
    try {
        $ca1Data.certificate = Get-CACertificate
        if ($ca1Data.certificate) {
            Write-Log -Level Info -Message "Сертификат CA1 получен: $($ca1Data.certificate.Subject)" -Operation 'CA1Audit' -OutputPath $OutputPath
        }
    }
    catch {
        Write-Log -Level Warning -Message "Ошибка получения сертификата CA1: $_" -Operation 'CA1Audit' -OutputPath $OutputPath
    }
    
    # Конфигурация из реестра
    try {
        $ca1Data.registry = Get-CARegistryConfig -CAName '*'
        Write-Log -Level Info -Message "Конфигурация CA1 из реестра получена" -Operation 'CA1Audit' -OutputPath $OutputPath
    }
    catch {
        Write-Log -Level Warning -Message "Ошибка получения конфигурации CA1: $_" -Operation 'CA1Audit' -OutputPath $OutputPath
    }
    
    # Шаблоны сертификатов
    try {
        $ca1Data.templates = Get-CATemplates
        Write-Log -Level Info -Message "Найдено шаблонов: $($ca1Data.templates.Count)" -Operation 'CA1Audit' -OutputPath $OutputPath
    }
    catch {
        Write-Log -Level Warning -Message "Ошибка получения шаблонов: $_" -Operation 'CA1Audit' -OutputPath $OutputPath
    }
    
    # Информация о CA
    try {
        $ca1Data.caInfo = Get-CAInfo
        Write-Log -Level Info -Message "Информация о CA получена" -Operation 'CA1Audit' -OutputPath $OutputPath
    }
    catch {
        Write-Log -Level Warning -Message "Ошибка получения информации о CA: $_" -Operation 'CA1Audit' -OutputPath $OutputPath
    }
    
    # Проверка доступности CA сервиса
    try {
        $ca1Data.caConfigTest = Test-CAService
        Write-Log -Level Info -Message "CA сервис доступен: $($ca1Data.caConfigTest)" -Operation 'CA1Audit' -OutputPath $OutputPath
    }
    catch {
        Write-Log -Level Warning -Message "Ошибка проверки CA сервиса: $_" -Operation 'CA1Audit' -OutputPath $OutputPath
    }
    
    # Статус службы CertSvc
    $serviceName = if ($script:AuditData.config -and $script:AuditData.config.ca1 -and $script:AuditData.config.ca1.serviceName) {
        $script:AuditData.config.ca1.serviceName
    }
    else {
        'CertSvc'
    }
    
    try {
        $ca1Data.service = Get-ServiceStatus -ServiceName $serviceName
        if ($ca1Data.service) {
            Write-Log -Level Info -Message "Служба ${serviceName}: $($ca1Data.service.Status)" -Operation 'CA1Audit' -OutputPath $OutputPath
        }
    }
    catch {
        Write-Log -Level Warning -Message "Ошибка получения статуса службы: $_" -Operation 'CA1Audit' -OutputPath $OutputPath
    }
    
    # CRL файлы
    $certEnrollPath = if ($script:AuditData.config -and $script:AuditData.config.iis -and $script:AuditData.config.iis.certEnrollPath) {
        $script:AuditData.config.iis.certEnrollPath
    }
    else {
        'C:\Windows\System32\CertSrv\CertEnroll'
    }
    
    if (Test-Path $certEnrollPath) {
        $crlFiles = Get-ChildItem -Path $certEnrollPath -Filter '*.crl' -ErrorAction SilentlyContinue
        foreach ($crlFile in $crlFiles) {
            $crlInfo = Get-CACRLInfo -CRLPath $crlFile.FullName
            if ($crlInfo) {
                $ca1Data.crlFiles += $crlInfo
            }
        }
        Write-Log -Level Info -Message "Найдено CRL файлов: $($ca1Data.crlFiles.Count)" -Operation 'CA1Audit' -OutputPath $OutputPath
    }
    
    # Экспорт сертификата и CRL в evidence
    if ($ca1Data.certificate.Path) {
        $evidenceCertPath = Join-Path $evidencePath "ca1_certificate.cer"
        Copy-Item -Path $ca1Data.certificate.Path -Destination $evidenceCertPath -ErrorAction SilentlyContinue
    }
    elseif ($ca1Data.certificate.RawDataBase64) {
        try {
            $evidenceCertPath = Join-Path $evidencePath "ca1_certificate.cer"
            [System.IO.File]::WriteAllBytes($evidenceCertPath, [System.Convert]::FromBase64String([string]$ca1Data.certificate.RawDataBase64))
        }
        catch {
            Write-Log -Level Warning -Message "Ошибка экспорта сертификата CA1 в evidence: $_" -Operation 'CA1Audit' -OutputPath $OutputPath
        }
    }
    
    foreach ($crlInfo in $ca1Data.crlFiles) {
        if ($crlInfo.Path) {
            $evidenceCrlPath = Join-Path $evidencePath "ca1_$(Split-Path $crlInfo.Path -Leaf)"
            Copy-Item -Path $crlInfo.Path -Destination $evidenceCrlPath -ErrorAction SilentlyContinue
        }
    }
    
    # Экспорт реестра CA
    $registryBackup = Export-RegistryBackup -OutputPath $evidencePath
    if ($registryBackup) {
        Write-Log -Level Info -Message "Backup реестра создан: $registryBackup" -Operation 'CA1Audit' -OutputPath $OutputPath
    }
    
    $script:AuditData.ca1 = $ca1Data
}

#endregion

#region IIS Audit

function Invoke-IisAudit {
    Write-Log -Level Info -Message "Аудит IIS" -Operation 'IisAudit' -Role 'IIS' -OutputPath $OutputPath
    
    $iisData = @{
        sites           = @()
        mimeTypes       = @()
        virtualDirs     = @()
        acls            = @()
        httpEndpoints   = @()
        applicationHost = $null
    }
    
    $siteName = if ($script:AuditData.config -and $script:AuditData.config.iis -and $script:AuditData.config.iis.siteName) {
        $script:AuditData.config.iis.siteName
    }
    else {
        'Default Web Site'
    }
    
    # Информация о сайте
    try {
        $site = Get-IisSite -SiteName $siteName
        if ($site) {
            $iisData.sites += $site
            Write-Log -Level Info -Message "Сайт IIS получен: $siteName" -Operation 'IisAudit' -OutputPath $OutputPath
        }
    }
    catch {
        Write-Log -Level Warning -Message "Ошибка получения информации о сайте IIS: $_" -Operation 'IisAudit' -OutputPath $OutputPath
    }
    
    # MIME типы
    try {
        $iisData.mimeTypes = Get-IisMimeTypes -SiteName $siteName
        Write-Log -Level Info -Message "Найдено MIME типов: $($iisData.mimeTypes.Count)" -Operation 'IisAudit' -OutputPath $OutputPath
    }
    catch {
        Write-Log -Level Warning -Message "Ошибка получения MIME типов: $_" -Operation 'IisAudit' -OutputPath $OutputPath
    }
    
    # Проверка критичных MIME типов
    $requiredMimeTypes = @(
        @{ Extension = '.crl'; MimeType = 'application/pkix-crl' }
        @{ Extension = '.crt'; MimeType = 'application/x-x509-ca-cert' }
        @{ Extension = '.cer'; MimeType = 'application/x-x509-ca-cert' }
    )
    
    foreach ($required in $requiredMimeTypes) {
        $exists = Test-IisMimeType -Extension $required.Extension -MimeType $required.MimeType -SiteName $siteName
        if (-not $exists) {
            Write-Log -Level Warning -Message "Отсутствует MIME тип: $($required.Extension) -> $($required.MimeType)" -Operation 'IisAudit' -OutputPath $OutputPath
        }
    }
    
    # ACL для PKI директорий
    $pkiPaths = @()
    if ($script:AuditData.config -and $script:AuditData.config.paths) {
        if ($script:AuditData.config.paths.pkiWebRoot) { $pkiPaths += $script:AuditData.config.paths.pkiWebRoot }
        if ($script:AuditData.config.paths.pkiAiaPath) { $pkiPaths += $script:AuditData.config.paths.pkiAiaPath }
        if ($script:AuditData.config.paths.pkiCdpPath) { $pkiPaths += $script:AuditData.config.paths.pkiCdpPath }
    }
    
    foreach ($path in $pkiPaths) {
        if (Test-Path $path) {
            $acl = Get-FileAcl -Path $path
            if ($acl) {
                $iisData.acls += $acl
            }
        }
    }
    
    # HTTP endpoints health check
    if ($script:AuditData.config -and $script:AuditData.config.endpoints -and $script:AuditData.config.endpoints.healthCheck) {
        foreach ($url in $script:AuditData.config.endpoints.healthCheck) {
            $healthCheck = Test-HttpEndpoint -Url $url -CheckContent
            $iisData.httpEndpoints += $healthCheck
            if ($healthCheck.Available) {
                Write-Log -Level Info -Message "Endpoint доступен: $url" -Operation 'IisAudit' -OutputPath $OutputPath
            }
            else {
                Write-Log -Level Warning -Message "Endpoint недоступен: $url" -Operation 'IisAudit' -OutputPath $OutputPath
            }
        }
    }
    
    # Экспорт applicationHost.config (опционально)
    if ($IncludeIisExport) {
        $appHostPath = "$env:SystemRoot\System32\inetsrv\config\applicationHost.config"
        if (Test-Path $appHostPath) {
            $evidenceAppHostPath = Join-Path $evidencePath "applicationHost.config"
            Copy-Item -Path $appHostPath -Destination $evidenceAppHostPath -ErrorAction SilentlyContinue
            Write-Log -Level Info -Message "applicationHost.config экспортирован" -Operation 'IisAudit' -OutputPath $OutputPath
        }
    }
    
    $script:AuditData.iis = $iisData
}

#endregion

#region Client Audit

function Invoke-ClientAudit {
    Write-Log -Level Info -Message "Аудит клиентов" -Operation 'ClientAudit' -Role 'Client' -OutputPath $OutputPath
    
    $clientData = @{
        gpresult      = $null
        certUtilPulse = $null
        certUtilVerify = $null
        eventLogs     = @()
    }
    
    # gpresult
    try {
        $gpresultPath = Join-Path $evidencePath "gpresult.html"
        & gpresult /H $gpresultPath /F | Out-Null
        if (Test-Path $gpresultPath) {
            $clientData.gpresult = $gpresultPath
            Write-Log -Level Info -Message "gpresult экспортирован" -Operation 'ClientAudit' -OutputPath $OutputPath
        }
    }
    catch {
        Write-Log -Level Warning -Message "Ошибка выполнения gpresult: $_" -Operation 'ClientAudit' -OutputPath $OutputPath
    }
    
    # certutil -user -pulse
    try {
        $pulseOutput = Get-CertUtilOutput -Arguments @('-user', '-pulse') -IgnoreErrors
        $clientData.certUtilPulse = $pulseOutput
        Write-Log -Level Info -Message "certutil -user -pulse выполнен" -Operation 'ClientAudit' -OutputPath $OutputPath
    }
    catch {
        Write-Log -Level Warning -Message "Ошибка выполнения certutil -user -pulse: $_" -Operation 'ClientAudit' -OutputPath $OutputPath
    }
    
    # certutil -verify -urlfetch
    if ($TestCertPath) {
        try {
            $verifyOutput = Get-CertUtilOutput -Arguments @('-verify', '-urlfetch') -IgnoreErrors
            $clientData.certUtilVerify = $verifyOutput
            Write-Log -Level Info -Message "certutil -verify -urlfetch выполнен" -Operation 'ClientAudit' -OutputPath $OutputPath
        }
        catch {
            Write-Log -Level Warning -Message "Ошибка выполнения certutil -verify: $_" -Operation 'ClientAudit' -OutputPath $OutputPath
        }
    }
    
    # Event Logs
    if ($IncludeEventLogs) {
        $eventSources = @(
            'Microsoft-Windows-CertificateServicesClient-CertificateEnrollment',
            'Microsoft-Windows-CertificateServicesClient-AutoEnrollment'
        )
        
        $lookbackHours = if ($script:AuditData.config -and $script:AuditData.config.monitoring -and $script:AuditData.config.monitoring.eventLogs -and $script:AuditData.config.monitoring.eventLogs.lookbackHours) {
            $script:AuditData.config.monitoring.eventLogs.lookbackHours
        }
        else {
            24
        }
        
        $startTime = (Get-Date).AddHours(-$lookbackHours)
        
        foreach ($source in $eventSources) {
            try {
                $events = Get-WinEvent -FilterHashtable @{
                    LogName = 'Application'
                    ProviderName = $source
                    StartTime = $startTime
                } -ErrorAction SilentlyContinue | Select-Object -First 100
                
                if ($events) {
                    $eventData = $events | ForEach-Object {
                        @{
                            TimeCreated = $_.TimeCreated
                            Id          = $_.Id
                            Level       = $_.LevelDisplayName
                            Message     = $_.Message
                        }
                    }
                    $clientData.eventLogs += $eventData
                    Write-Log -Level Info -Message "Найдено событий для $source : $($events.Count)" -Operation 'ClientAudit' -OutputPath $OutputPath
                }
            }
            catch {
                Write-Log -Level Warning -Message "Ошибка получения событий для $source : $_" -Operation 'ClientAudit' -OutputPath $OutputPath
            }
        }
        
        # Экспорт событий
        if ($clientData.eventLogs.Count -gt 0) {
            $eventsPath = Join-Path $evidencePath "events.json"
            $clientData.eventLogs | ConvertTo-Json -Depth 10 | Out-File -FilePath $eventsPath -Encoding UTF8
        }
    }
    
    $script:AuditData.clients = $clientData
}

#endregion

#region Генерация отчётов

function Export-BaselineJson {
    $baselinePath = Join-Path $OutputPath "baseline_$(Get-Timestamp).json"
    
    try {
        $json = ConvertTo-SafeJson -InputObject $script:AuditData
        $json | Out-File -FilePath $baselinePath -Encoding UTF8
        Write-Log -Level Info -Message "Baseline JSON экспортирован: $baselinePath" -Operation 'Export' -OutputPath $OutputPath
        return $baselinePath
    }
    catch {
        Write-Log -Level Error -Message "Ошибка экспорта baseline JSON: $_" -Operation 'Export' -OutputPath $OutputPath
        return $null
    }
}

function Export-AsIsMarkdown {
    $markdownPath = Join-Path $OutputPath "AS-IS_$(Get-Timestamp).md"
    
    $md = @"
# AS-IS Отчёт: Аудит PKI-инфраструктуры

**Дата аудита**: $($script:AuditData.timestamp)  
**Роль**: $($script:AuditData.role)  
**Время выполнения**: $((Get-Date) - $script:StartTime)

---

## 1. CA0 (Root CA)

### Сертификат
"@
    
    if ($script:AuditData.ca0.certificate) {
        $cert = $script:AuditData.ca0.certificate
        $md += @"

- **Subject**: $($cert.Subject)
- **Issuer**: $($cert.Issuer)
- **Thumbprint**: $($cert.Thumbprint)
- **Not Before**: $($cert.NotBefore)
- **Not After**: $($cert.NotAfter)
- **Serial Number**: $($cert.SerialNumber)
"@
    }
    else {
        $md += "`n- Сертификат CA0 не найден"
    }
    
    $md += @"

### CRL Конфигурация
"@
    
    if ($script:AuditData.ca0.registry.CRL) {
        $crl = $script:AuditData.ca0.registry.CRL
        $md += @"

- **Period**: $($crl.Period) $($crl.PeriodUnits)
- **Overlap**: $($crl.OverlapPeriod) $($crl.OverlapUnits)
- **Flags**: $($crl.Flags)
"@
    }
    
    $md += @"

### CRL Файлы
"@
    
    if ($script:AuditData.ca0.crlFiles.Count -gt 0) {
        foreach ($crl in $script:AuditData.ca0.crlFiles) {
            $md += @"

- **Файл**: $(Split-Path $crl.Path -Leaf)
- **This Update**: $($crl.ThisUpdate)
- **Next Update**: $($crl.NextUpdate)
- **Days Until Expiry**: $($crl.DaysUntilExpiry)
- **Is Expired**: $($crl.IsExpired)
"@
        }
    }
    else {
        $md += "`n- CRL файлы не найдены"
    }
    
    $md += @"

---

## 2. CA1 (Issuing CA)

### Сертификат
"@
    
    if ($script:AuditData.ca1.certificate) {
        $cert = $script:AuditData.ca1.certificate
        $md += @"

- **Subject**: $($cert.Subject)
- **Issuer**: $($cert.Issuer)
- **Thumbprint**: $($cert.Thumbprint)
- **Not Before**: $($cert.NotBefore)
- **Not After**: $($cert.NotAfter)
"@
    }
    
    $md += @"

### Служба
"@
    
    if ($script:AuditData.ca1.service) {
        $svc = $script:AuditData.ca1.service
        $md += @"

- **Status**: $($svc.Status)
- **Start Type**: $($svc.StartType)
"@
    }
    
    $md += @"

### Шаблоны сертификатов
"@
    
    if ($script:AuditData.ca1.templates.Count -gt 0) {
        foreach ($template in $script:AuditData.ca1.templates) {
            $md += @"

- **$($template.Name)** (v$($template.Version)): $($template.DisplayName)
"@
        }
    }
    
    $md += @"

---

## 3. IIS

### Сайт
"@
    
    if ($script:AuditData.iis.sites.Count -gt 0) {
        $site = $script:AuditData.iis.sites[0]
        $md += @"

- **Name**: $($site.Name)
- **State**: $($site.State)
- **Physical Path**: $($site.PhysicalPath)
"@
    }
    
    $md += @"

### HTTP Endpoints
"@
    
    foreach ($endpoint in $script:AuditData.iis.httpEndpoints) {
        $status = if ($endpoint.Available) { "✅ Доступен" } else { "❌ Недоступен" }
        $md += @"

- **$($endpoint.Url)**: $status (Status: $($endpoint.StatusCode))
"@
    }
    
    $md += @"

---

## 4. Evidence Pack

Все собранные данные сохранены в: `$($script:AuditData.evidence.path)`

---

## Заключение

Аудит завершён. См. baseline.json для детальной информации.
"@
    
    try {
        $md | Out-File -FilePath $markdownPath -Encoding UTF8
        Write-Log -Level Info -Message "AS-IS Markdown экспортирован: $markdownPath" -Operation 'Export' -OutputPath $OutputPath
        return $markdownPath
    }
    catch {
        Write-Log -Level Error -Message "Ошибка экспорта AS-IS Markdown: $_" -Operation 'Export' -OutputPath $OutputPath
        return $null
    }
}

#endregion

#region Main

try {
    # Выполнение аудита в зависимости от роли
    if ($Role -eq 'All' -or $Role -eq 'CA0') {
        Invoke-CA0Audit
    }
    
    if ($Role -eq 'All' -or $Role -eq 'CA1') {
        Invoke-CA1Audit
    }
    
    if ($Role -eq 'All' -or $Role -eq 'IIS') {
        Invoke-IisAudit
    }
    
    if ($Role -eq 'All' -or $Role -eq 'Client') {
        Invoke-ClientAudit
    }
    
    # Экспорт результатов
    $baselinePath = Export-BaselineJson
    $asIsPath = Export-AsIsMarkdown
    
    $duration = (Get-Date) - $script:StartTime
    Write-Log -Level Info -Message "Аудит завершён. Время выполнения: $($duration.TotalSeconds) сек" -Operation 'Audit' -OutputPath $OutputPath
    
    Write-Host "`n=== Результаты аудита ===" -ForegroundColor Green
    Write-Host "Baseline JSON: $baselinePath" -ForegroundColor Cyan
    Write-Host "AS-IS Markdown: $asIsPath" -ForegroundColor Cyan
    Write-Host "Evidence Pack: $($script:AuditData.evidence.path)" -ForegroundColor Cyan
    
    exit 0
}
catch {
    Write-Log -Level Error -Message "Критическая ошибка аудита: $_" -Exception $_ -Operation 'Audit' -OutputPath $OutputPath
    exit 1
}

#endregion
