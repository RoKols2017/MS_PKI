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
        $output = Get-CertUtilOutput -Arguments @('-ca.cert', '-f') -IgnoreErrors
        if ($output) {
            $certPath = $output | Where-Object { $_ -match '\.(cer|crt)$' } | Select-Object -First 1
            if ($certPath -and (Test-Path $certPath)) {
                $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certPath)
                return @{
                    Subject      = $cert.Subject
                    Issuer       = $cert.Issuer
                    Thumbprint   = $cert.Thumbprint
                    NotBefore    = $cert.NotBefore
                    NotAfter     = $cert.NotAfter
                    SerialNumber = $cert.SerialNumber
                    Path         = $certPath
                }
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
    Получает информацию о CRL.
    #>
    [CmdletBinding()]
    param(
        [string]$CRLPath
    )
    
    if (-not $CRLPath -or -not (Test-Path $CRLPath)) {
        return $null
    }
    
    try {
        $output = Get-CertUtilOutput -Arguments @('-dump', $CRLPath)
        
        $crlInfo = @{
            Path = $CRLPath
        }
        
        foreach ($line in $output) {
            if ($line -match 'ThisUpdate:\s*(.+)') {
                $crlInfo.ThisUpdate = $matches[1].Trim()
            }
            if ($line -match 'NextUpdate:\s*(.+)') {
                $crlInfo.NextUpdate = $matches[1].Trim()
            }
            if ($line -match 'CRL Number:\s*(.+)') {
                $crlInfo.CRLNumber = $matches[1].Trim()
            }
            if ($line -match 'Base CRL Number:\s*(.+)') {
                $crlInfo.BaseCRLNumber = $matches[1].Trim()
            }
        }
        
        # Парсинг дат
        if ($crlInfo.NextUpdate) {
            try {
                $nextUpdateDate = [DateTime]::Parse($crlInfo.NextUpdate)
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
        Write-Warning "Ошибка анализа CRL: $_"
        return $null
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
    Получает список шаблонов сертификатов.
    #>
    [CmdletBinding()]
    param()
    
    try {
        $output = Get-CertUtilOutput -Arguments @('-catemplates')
        
        $templates = @()
        $currentTemplate = $null
        
        foreach ($line in $output) {
            if ($line -match 'Template:\s*(.+)') {
                if ($currentTemplate) {
                    $templates += $currentTemplate
                }
                $currentTemplate = @{
                    Name = $matches[1].Trim()
                }
            }
            elseif ($currentTemplate) {
                if ($line -match 'Display Name:\s*(.+)') {
                    $currentTemplate.DisplayName = $matches[1].Trim()
                }
                if ($line -match 'Version:\s*(\d+)') {
                    $currentTemplate.Version = [int]$matches[1]
                }
            }
        }
        
        if ($currentTemplate) {
            $templates += $currentTemplate
        }
        
        return $templates
    }
    catch {
        Write-Warning "Ошибка получения шаблонов: $_"
        return @()
    }
}

function Get-CAInfo {
    <#
    .SYNOPSIS
    Получает общую информацию о CA.
    #>
    [CmdletBinding()]
    param()
    
    try {
        $output = Get-CertUtilOutput -Arguments @('-cainfo')
        
        $info = @{}
        
        foreach ($line in $output) {
            if ($line -match 'CA Name:\s*(.+)') {
                $info.CAName = $matches[1].Trim()
            }
            if ($line -match 'Common Name:\s*(.+)') {
                $info.CommonName = $matches[1].Trim()
            }
            if ($line -match 'Certificate:\s*(.+)') {
                $info.Certificate = $matches[1].Trim()
            }
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
