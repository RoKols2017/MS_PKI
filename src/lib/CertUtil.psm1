# CertUtil.psm1
# Функции для работы с certutil и сертификатами

function Get-CACertificate {
    <#
    .SYNOPSIS
    Получает сертификат CA.
    #>
    [CmdletBinding()]
    param(
        [string]$CAName = '*'
    )
    
    try {
        # Используем временный файл вместо парсинга вывода
        $tempFile = [System.IO.Path]::GetTempFileName()
        $output = Get-CertUtilOutput -Arguments @('-ca.cert', $tempFile) -IgnoreErrors
        
        # CertUtil может создать файл с расширением .crt, даже если мы просили .tmp
        # Проверяем возможные варианты
        $certPath = $null
        if (Test-Path $tempFile) {
            $certPath = $tempFile
        }
        elseif (Test-Path "$tempFile.crt") {
            $certPath = "$tempFile.crt"
        }
        
        if ($certPath -and (Get-Item $certPath).Length -gt 0) {
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certPath)
            
            # Удаляем временные файлы
            Remove-Item $tempFile -ErrorAction SilentlyContinue
            if (Test-Path "$tempFile.crt") { Remove-Item "$tempFile.crt" -ErrorAction SilentlyContinue }
            
            return @{
                Subject      = $cert.Subject
                Issuer       = $cert.Issuer
                Thumbprint   = $cert.Thumbprint
                NotBefore    = $cert.NotBefore
                NotAfter     = $cert.NotAfter
                SerialNumber = $cert.SerialNumber
                Path         = $null # Мы не сохраняем путь к временному файлу
                RawDataBase64 = [System.Convert]::ToBase64String($cert.RawData)
            }
        }
        return $null
    }
    catch {
        Write-Warning "Ошибка получения сертификата CA: $_"
        return $null
    }
}

function Get-CACRLInfo {
    <#
    .SYNOPSIS
    Получает информацию о CRL через COM объект X509Enrollment.
    #>
    [CmdletBinding()]
    param(
        [string]$CRLPath
    )
    
    if (-not $CRLPath -or -not (Test-Path $CRLPath)) {
        return $null
    }
    
    try {
        # Читаем CRL как Base64 строку для COM объекта
        $bytes = [System.IO.File]::ReadAllBytes($CRLPath)
        $base64 = [Convert]::ToBase64String($bytes)
        
        # Используем CX509CRL COM объект (доступен на Server 2008+)
        $crlObject = New-Object -ComObject X509Enrollment.CX509CRL
        $crlObject.InitializeDecode($base64, 1) # 1 = XCN_CRYPT_STRING_BASE64
        
        $crlInfo = @{
            Path = $CRLPath
            ThisUpdate = $crlObject.ThisUpdate
            NextUpdate = $crlObject.NextUpdate
            Issuer = $crlObject.Issuer.Name
        }
        
        # Получаем CRL Number (OID 2.5.29.20)
        try {
            # Проходим по расширениям
            foreach ($ext in $crlObject.X509Extensions) {
                if ($ext.ObjectId.Value -eq "2.5.29.20") {
                    # Это CRL Number, нужно декодировать значение
                    # Упрощенно: значение в hex часто доступно через display или raw data
                    # Для надежности можно использовать доп. парсинг, но пока оставим базовое
                }
            }
        }
        catch {}
        
        # Парсинг дат
        if ($crlInfo.NextUpdate) {
            try {
                $nextUpdateDate = $crlInfo.NextUpdate
                $crlInfo.NextUpdateDate = $nextUpdateDate
                $crlInfo.DaysUntilExpiry = ($nextUpdateDate - (Get-Date)).Days
                $crlInfo.IsExpired = ($nextUpdateDate -lt (Get-Date))
            }
            catch {
                # Игнорируем ошибки парсинга даты
            }
        }
        
        return $crlInfo
    }
    catch {
        Write-Warning "Ошибка анализа CRL через COM объект: $($_.Exception.Message)"
        Write-Warning "Попытка отката к certutil..."
        
        # Fallback к certutil, если COM недоступен
        try {
            $output = Get-CertUtilOutput -Arguments @('-dump', $CRLPath)
            
            $crlInfo = @{
                Path = $CRLPath
            }
            
            # Попытка найти стандартные английские поля, но это не гарантировано на RU системе
            foreach ($line in $output) {
                if ($line -match 'ThisUpdate:\s*(.+)') { $crlInfo.ThisUpdate = $matches[1].Trim() }
                if ($line -match 'NextUpdate:\s*(.+)') { $crlInfo.NextUpdate = $matches[1].Trim() }
            }
            
            return $crlInfo
        }
        catch {
             Write-Warning "Ошибка анализа CRL (fallback): $_"
             return $null
        }
    }
}

function Get-CARegistryConfig {
    <#
    .SYNOPSIS
    Получает конфигурацию CA из реестра.
    #>
    [CmdletBinding()]
    param(
        [string]$CAName = '*'
    )
    
    $config = @{}
    
    # Получаем список CA
    $caList = Get-CertUtilOutput -Arguments @('-catemplates') -IgnoreErrors
    if ($caList) {
        $config.CANames = $caList | Where-Object { $_ -match '^\s+\w+' } | ForEach-Object { $_.Trim() }
    }
    
    # CRL настройки
    $crlPeriod = Get-RegistryValue -Key $CAName -ValueName 'CRLPeriod'
    $crlPeriodUnits = Get-RegistryValue -Key $CAName -ValueName 'CRLPeriodUnits'
    $crlOverlap = Get-RegistryValue -Key $CAName -ValueName 'CRLOverlapPeriod'
    $crlOverlapUnits = Get-RegistryValue -Key $CAName -ValueName 'CRLOverlapUnits'
    $crlFlags = Get-RegistryValue -Key $CAName -ValueName 'CRLFlags'
    $crlDeltaPeriod = Get-RegistryValue -Key $CAName -ValueName 'CRLDeltaPeriod'
    $crlDeltaPeriodUnits = Get-RegistryValue -Key $CAName -ValueName 'CRLDeltaPeriodUnits'
    
    $config.CRL = @{
        Period         = $crlPeriod
        PeriodUnits    = $crlPeriodUnits
        OverlapPeriod  = $crlOverlap
        OverlapUnits   = $crlOverlapUnits
        Flags          = $crlFlags
        DeltaPeriod    = $crlDeltaPeriod
        DeltaPeriodUnits = $crlDeltaPeriodUnits
    }
    
    # URLs публикации
    $crlUrls = Get-RegistryValue -Key $CAName -ValueName 'CRLPublicationURLs'
    $aiaUrls = Get-RegistryValue -Key $CAName -ValueName 'CACertPublicationURLs'
    
    $config.PublicationURLs = @{
        CRL = $crlUrls
        AIA = $aiaUrls
    }
    
    return $config
}

function Get-CATemplates {
    <#
    .SYNOPSIS
    Получает список шаблонов сертификатов через ADSI (LDAP), не завися от языка.
    #>
    [CmdletBinding()]
    param()
    
    try {
        # Получаем Configuration Naming Context
        $rootDSE = [adsi]"LDAP://RootDSE"
        $configContext = $rootDSE.configurationNamingContext
        
        # Ищем шаблоны в CN=Certificate Templates,CN=Public Key Services,CN=Services,...
        $searcher = [adsisearcher]""
        $searcher.SearchRoot = "LDAP://CN=Certificate Templates,CN=Public Key Services,CN=Services,$configContext"
        $searcher.Filter = "(objectClass=pKICertificateTemplate)"
        $searcher.PropertiesToLoad.Add("cn") | Out-Null
        $searcher.PropertiesToLoad.Add("displayName") | Out-Null
        $searcher.PropertiesToLoad.Add("msPKI-Template-Schema-Version") | Out-Null
        
        $results = $searcher.FindAll()
        
        $templates = @()
        foreach ($res in $results) {
            $props = $res.Properties
            $templates += @{
                Name = if ($props["cn"]) { $props["cn"][0] } else { "" }
                DisplayName = if ($props["displayName"]) { $props["displayName"][0] } else { "" }
                Version = if ($props["msPKI-Template-Schema-Version"]) { $props["msPKI-Template-Schema-Version"][0] } else { 1 }
            }
        }
        
        return $templates
    }
    catch {
        Write-Warning "Ошибка получения шаблонов через LDAP: $_"
        
        # Fallback к certutil (ненадежно на RU)
        try {
            $output = Get-CertUtilOutput -Arguments @('-catemplates')
            $templates = @()
            $currentTemplate = $null
            
            foreach ($line in $output) {
                if ($line -match 'Template:\s*(.+)') {
                     if ($currentTemplate) { $templates += $currentTemplate }
                     $currentTemplate = @{ Name = $matches[1].Trim() }
                }
                # Добавить парсинг Display Name, если он на английском
            }
             if ($currentTemplate) { $templates += $currentTemplate }
            return $templates
        }
        catch {
             return @()
        }
    }
}

function Get-CAInfo {
    <#
    .SYNOPSIS
    Получает общую информацию о CA через реестр.
    #>
    [CmdletBinding()]
    param()
    
    try {
        # Пытаемся получить имя активного CA из реестра
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration"
         if (-not (Test-Path $regPath)) { return @{} }
         
        $caConfigs = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $caConfigs) { return @{} }
        
        $caName = $caConfigs.PSChildName
        $commonName = (Get-ItemProperty -Path $caConfigs.PSPath -Name "CommonName" -ErrorAction SilentlyContinue).CommonName
        $certHash = (Get-ItemProperty -Path $caConfigs.PSPath -Name "CACertHash" -ErrorAction SilentlyContinue).CACertHash
        
        # Если hash - это массив байт, конвертируем в строку
        if ($certHash -is [byte[]]) {
            $certHash = ($certHash | ForEach-Object { $_.ToString("X2") }) -join ""
        }
        
        $info = @{
            CAName = $caName
            CommonName = if ($commonName) { $commonName } else { $caName }
            Certificate = $certHash
        }
        
        return $info
    }
    catch {
        Write-Warning "Ошибка получения информации о CA: $_"
        return @{}
    }
}

function Test-CAService {
    <#
    .SYNOPSIS
    Проверяет доступность CA сервиса.
    #>
    [CmdletBinding()]
    param()
    
    try {
        $output = Get-CertUtilOutput -Arguments @('-getconfig', '-', '-ping')
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

Export-ModuleMember -Function Get-CACertificate, Get-CACRLInfo, Get-CARegistryConfig, Get-CATemplates, Get-CAInfo, Test-CAService
