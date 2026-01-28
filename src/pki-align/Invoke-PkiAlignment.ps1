# Invoke-PkiAlignment.ps1
# Phase 4: Alignment - безопасное выравнивание конфигурации PKI

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,
    
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    
    [string]$BaselinePath = '',
    
    [switch]$Apply,
    [switch]$Backup,
    [string]$RollbackPointName = ''
)

#region Инициализация

$ErrorActionPreference = 'Stop'
$script:StartTime = Get-Date
$script:AlignmentPlan = @{
    timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    changes   = @()
    backups   = @()
    rollbackPoints = @()
}

# Импорт модулей
$libPath = Join-Path $PSScriptRoot '..\lib'
Import-Module (Join-Path $libPath 'Logging.psm1') -Force
Import-Module (Join-Path $libPath 'PkiCommon.psm1') -Force
Import-Module (Join-Path $libPath 'Http.psm1') -Force
Import-Module (Join-Path $libPath 'CertUtil.psm1') -Force
Import-Module (Join-Path $libPath 'PkiSecurity.psm1') -Force

# Установка значений по умолчанию для switch параметров
if (-not $PSBoundParameters.ContainsKey('Apply')) {
    $Apply = $false
}
if (-not $PSBoundParameters.ContainsKey('Backup')) {
    $Backup = $true
}
# WhatIf автоматически доступен через $WhatIfPreference при SupportsShouldProcess

# Инициализация логирования
Initialize-Logging -OutputPath $OutputPath -Level 'Info'

if (-not $Apply) {
    Write-Log -Level Info -Message "Режим WhatIf. Изменения не будут применены. Используйте -Apply для применения." -Operation 'Alignment' -OutputPath $OutputPath
}

# Проверка прав
try {
    Assert-Administrator
}
catch {
    Write-Log -Level Error -Message $_ -Operation 'Alignment' -OutputPath $OutputPath
    exit 3
}

# Загрузка конфигурации
$config = Import-PkiConfig -ConfigPath $ConfigPath

# Загрузка baseline
$baseline = $null
if ($BaselinePath -and (Test-Path $BaselinePath)) {
    try {
        $baseline = Get-Content -Path $BaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Log -Level Info -Message "Baseline загружен: $BaselinePath" -Operation 'Alignment' -OutputPath $OutputPath
    }
    catch {
        Write-Log -Level Warning -Message "Ошибка загрузки baseline: $_" -Operation 'Alignment' -OutputPath $OutputPath
    }
}

# Создание rollback point
$rollbackPointName = if ($RollbackPointName) {
    $RollbackPointName
}
else {
    "alignment_$(Get-Timestamp)"
}

$rollbackPath = Join-Path $OutputPath "backups\$rollbackPointName"
Test-PathExists -Path $rollbackPath -CreateIfNotExists | Out-Null

#endregion

#region Backup функции

function New-Backup {
    param(
        [string]$BackupType,
        [string]$Description
    )
    
    if (-not $Backup) {
        Write-Log -Level Info -Message "Backup отключен, пропуск: $BackupType" -Operation 'Backup' -OutputPath $OutputPath
        return $null
    }
    
    $backupInfo = @{
        type        = $BackupType
        description = $Description
        timestamp   = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
        path        = $null
    }
    
    try {
        switch ($BackupType) {
            'Registry' {
                $backupPath = Export-RegistryBackup -OutputPath $rollbackPath
                $backupInfo.path = $backupPath
                Write-Log -Level Info -Message "Backup реестра создан: $backupPath" -Operation 'Backup' -OutputPath $OutputPath
            }
            'IIS' {
                # IIS backup через appcmd
                try {
                    Import-Module WebAdministration -ErrorAction Stop
                    $backupName = "pki_alignment_$(Get-Timestamp)"
                    & "$env:SystemRoot\System32\inetsrv\appcmd.exe" backup $backupName
                    $backupInfo.path = "$env:SystemRoot\System32\inetsrv\backup\$backupName"
                    Write-Log -Level Info -Message "Backup IIS создан: $($backupInfo.path)" -Operation 'Backup' -OutputPath $OutputPath
                }
                catch {
                    Write-Log -Level Warning -Message "Ошибка создания backup IIS: $_" -Operation 'Backup' -OutputPath $OutputPath
                }
            }
            'Certificates' {
                # Копирование сертификатов и CRL
                $certBackupPath = Join-Path $rollbackPath "certificates"
                Test-PathExists -Path $certBackupPath -CreateIfNotExists | Out-Null
                
                $certEnrollPath = $config.iis.certEnrollPath
                if (Test-Path $certEnrollPath) {
                    Copy-Item -Path "$certEnrollPath\*" -Destination $certBackupPath -Recurse -ErrorAction SilentlyContinue
                    $backupInfo.path = $certBackupPath
                    Write-Log -Level Info -Message "Backup сертификатов создан: $certBackupPath" -Operation 'Backup' -OutputPath $OutputPath
                }
            }
        }
        
        $script:AlignmentPlan.backups += $backupInfo
        return $backupInfo
    }
    catch {
        Write-Log -Level Error -Message "Ошибка создания backup $BackupType : $_" -Operation 'Backup' -OutputPath $OutputPath
        return $null
    }
}

#endregion

#region Функции выравнивания

function Add-ChangePlan {
    param(
        [string]$Category,
        [string]$Description,
        [object]$OldValue,
        [object]$NewValue,
        [scriptblock]$ApplyAction,
        [scriptblock]$RollbackAction = $null
    )
    
    $change = @{
        category      = $Category
        description   = $Description
        oldValue      = $OldValue
        newValue      = $NewValue
        applyAction   = $ApplyAction
        rollbackAction = $RollbackAction
        applied       = $false
        rolledBack    = $false
        timestamp     = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
        changeId      = [System.Guid]::NewGuid().ToString()
    }
    
    $script:AlignmentPlan.changes += $change
    
    if ($WhatIfPreference -or -not $Apply) {
        Write-Log -Level Info -Message "[PLAN] $Category : $Description" -Operation 'Alignment' -OutputPath $OutputPath
        Write-Log -Level Info -Message "  Change ID: $($change.changeId)" -Operation 'Alignment' -OutputPath $OutputPath
        # Безопасная сериализация значений, чтобы избежать ошибок ConvertTo-Json
        $oldJson = ConvertTo-SafeJson -InputObject $OldValue -Depth 10
        $newJson = ConvertTo-SafeJson -InputObject $NewValue -Depth 10
        Write-Log -Level Info -Message "  Старое значение: $oldJson" -Operation 'Alignment' -OutputPath $OutputPath
        Write-Log -Level Info -Message "  Новое значение: $newJson" -Operation 'Alignment' -OutputPath $OutputPath
        if ($RollbackAction) {
            Write-Log -Level Info -Message "  Rollback доступен" -Operation 'Alignment' -OutputPath $OutputPath
        }
    }
}

function Invoke-AlignIisMimeTypes {
    Write-Log -Level Info -Message "Выравнивание MIME типов IIS" -Operation 'Alignment' -OutputPath $OutputPath
    
    $siteName = $config.iis.siteName
    $requiredMimeTypes = @(
        @{ Extension = '.crl'; MimeType = 'application/pkix-crl' }
        @{ Extension = '.crt'; MimeType = 'application/x-x509-ca-cert' }
        @{ Extension = '.cer'; MimeType = 'application/x-x509-ca-cert' }
    )
    
    foreach ($mime in $requiredMimeTypes) {
        $exists = Test-IisMimeType -Extension $mime.Extension -MimeType $mime.MimeType -SiteName $siteName
        
        if (-not $exists) {
            Add-ChangePlan -Category 'IIS_MIME' -Description "Добавление MIME типа: $($mime.Extension) -> $($mime.MimeType)" `
                -OldValue @{ exists = $false } -NewValue $mime `
                -ApplyAction {
                    param($changeData)
                    try {
                        Import-Module WebAdministration -ErrorAction Stop
                        $mimeData = $changeData.newValue
                        Add-WebConfigurationProperty -Filter "system.webServer/staticContent" -Name "." -PSPath "IIS:\Sites\$siteName" `
                            -Value @{ fileExtension = $mimeData.Extension; mimeType = $mimeData.MimeType } -ErrorAction Stop
                        Write-Log -Level Info -Message "MIME тип добавлен: $($mimeData.Extension)" -Operation 'Alignment' -OutputPath $OutputPath
                        return $true
                    }
                    catch {
                        Write-Log -Level Error -Message "Ошибка добавления MIME типа: $_" -Operation 'Alignment' -OutputPath $OutputPath
                        return $false
                    }
                } `
                -RollbackAction {
                    param($changeData)
                    try {
                        Import-Module WebAdministration -ErrorAction Stop
                        $mimeData = $changeData.newValue
                        Remove-WebConfigurationProperty -Filter "system.webServer/staticContent" -Name "." -PSPath "IIS:\Sites\$siteName" `
                            -AtElement @{ fileExtension = $mimeData.Extension; mimeType = $mimeData.MimeType } -ErrorAction Stop
                        Write-Log -Level Info -Message "MIME тип удалён (rollback): $($mimeData.Extension)" -Operation 'Rollback' -OutputPath $OutputPath
                        return $true
                    }
                    catch {
                        Write-Log -Level Error -Message "Ошибка rollback MIME типа: $_" -Operation 'Rollback' -OutputPath $OutputPath
                        return $false
                    }
                }
        }
    }
}

function Invoke-AlignIisAcls {
    Write-Log -Level Info -Message "Выравнивание ACL для PKI директорий" -Operation 'Alignment' -OutputPath $OutputPath
    
    $pkiPaths = @(
        $config.paths.pkiWebRoot,
        $config.paths.pkiAiaPath,
        $config.paths.pkiCdpPath
    )
    
    foreach ($path in $pkiPaths) {
        if (-not (Test-Path $path)) {
            Write-Log -Level Warning -Message "Путь не существует, создание: $path" -Operation 'Alignment' -OutputPath $OutputPath
            
            if ($Apply) {
                Test-PathExists -Path $path -CreateIfNotExists | Out-Null
            }
        }
        
        # Проверка ACL (read-only для IIS_IUSRS)
        $acl = Get-Acl -Path $path -ErrorAction SilentlyContinue
        if ($acl) {
            $hasReadAccess = $acl.Access | Where-Object {
                $_.IdentityReference -like '*IIS_IUSRS*' -and
                $_.FileSystemRights -match 'Read' -and
                $_.AccessControlType -eq 'Allow'
            }
            
            if (-not $hasReadAccess) {
                # Сохранение текущего ACL для rollback
                $currentAclForBackup = Get-Acl -Path $path
                
                Add-ChangePlan -Category 'IIS_ACL' -Description "Настройка ACL для $path" `
                    -OldValue @{ hasReadAccess = $false; path = $path; acl = $currentAclForBackup } -NewValue @{ hasReadAccess = $true; path = $path } `
                    -ApplyAction {
                        param($changeData)
                        try {
                            $targetPath = $changeData.newValue.path
                            
                            # Получение текущего ACL
                            $currentAcl = Get-Acl -Path $targetPath
                            
                            $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                                "IIS_IUSRS",
                                "ReadAndExecute",
                                "ContainerInherit,ObjectInherit",
                                "None",
                                "Allow"
                            )
                            $currentAcl.SetAccessRule($accessRule)
                            Set-Acl -Path $targetPath -AclObject $currentAcl
                            Write-Log -Level Info -Message "ACL обновлён для: $targetPath" -Operation 'Alignment' -OutputPath $OutputPath
                            return $true
                        }
                        catch {
                            Write-Log -Level Error -Message "Ошибка обновления ACL: $_" -Operation 'Alignment' -OutputPath $OutputPath
                            return $false
                        }
                    } `
                    -RollbackAction {
                        param($changeData)
                        try {
                            $targetPath = $changeData.newValue.path
                            $oldAcl = $changeData.oldValue.acl
                            
                            if ($oldAcl) {
                                Set-Acl -Path $targetPath -AclObject $oldAcl
                                Write-Log -Level Info -Message "ACL откачен для: $targetPath" -Operation 'Rollback' -OutputPath $OutputPath
                            }
                            return $true
                        }
                        catch {
                            Write-Log -Level Error -Message "Ошибка rollback ACL: $_" -Operation 'Rollback' -OutputPath $OutputPath
                            return $false
                        }
                    }
            }
        }
    }
}

function Invoke-AlignCRLPublication {
    Write-Log -Level Info -Message "Выравнивание публикации CRL" -Operation 'Alignment' -OutputPath $OutputPath
    
    if (-not $baseline) {
        Write-Log -Level Warning -Message "Baseline не загружен, пропуск выравнивания CRL publication" -Operation 'Alignment' -OutputPath $OutputPath
        return
    }
    
    # КРИТИЧЕСКАЯ ПРОВЕРКА: Существование CA
    $caStatus = Test-CAExists
    if (-not $caStatus.Exists) {
        Write-Log -Level Error -Message "CA не найден. Невозможно изменить CRLPublicationURLs." -Operation 'Alignment' -OutputPath $OutputPath
        return
    }
    if (-not $caStatus.Available) {
        Write-Log -Level Warning -Message "CA существует, но недоступен. Продолжение с осторожностью." -Operation 'Alignment' -OutputPath $OutputPath
    }
    
    # Проверка наличия canonical путей в CRLPublicationURLs
    $currentUrls = $baseline.ca1.registry.PublicationURLs.CRL
    $canonicalCdp = $config.namespaces.canonical.cdp
    
    $hasCanonical = $false
    if ($currentUrls) {
        $urlArray = $currentUrls -split "`n" | Where-Object { $_.Trim() }
        foreach ($url in $urlArray) {
            if ($url -match [regex]::Escape($canonicalCdp)) {
                $hasCanonical = $true
                break
            }
        }
    }
    
    if (-not $hasCanonical) {
        Write-Log -Level Info -Message "Canonical путь отсутствует в CRLPublicationURLs, добавление" -Operation 'Alignment' -OutputPath $OutputPath
        
        # Формирование нового URL (добавляем к существующим, не заменяем)
        $newUrl = "http://$($config.ca1.hostname)$canonicalCdp/{CAName}{CRLNameSuffix}{DeltaCRLAllowed}.crl"
        
        # КРИТИЧЕСКАЯ ПРОВЕРКА: Валидация URL
        $urlValidation = Test-UrlFormat -Url $newUrl
        if (-not $urlValidation.Valid) {
            Write-Log -Level Error -Message "Некорректный формат URL: $($urlValidation.Reason)" -Operation 'Alignment' -OutputPath $OutputPath
            return
        }
        
        # Проверка доступности endpoint (опционально, но рекомендуется)
        $endpointCheck = Test-HttpEndpoint -Url "http://$($config.ca1.hostname)$canonicalCdp" -TimeoutSeconds 5
        if (-not $endpointCheck.Available) {
            Write-Log -Level Warning -Message "Endpoint может быть недоступен: http://$($config.ca1.hostname)$canonicalCdp" -Operation 'Alignment' -OutputPath $OutputPath
        }
        
        Add-ChangePlan -Category 'CRL_Publication' -Description "Добавление canonical пути в CRLPublicationURLs" `
            -OldValue @{ urls = $currentUrls } -NewValue @{ urls = "$currentUrls`n$newUrl"; newUrl = $newUrl } `
            -ApplyAction {
                param($changeData)
                try {
                    $newUrl = $changeData.newValue.newUrl
                    
                    # Повторная проверка CA перед изменением
                    $caCheck = Test-CAExists
                    if (-not $caCheck.Exists) {
                        Write-Log -Level Error -Message "CA не найден при попытке изменения реестра" -Operation 'Alignment' -OutputPath $OutputPath
                        return $false
                    }
                    
                    # Получаем текущие URLs
                    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\*"
                    $caConfigs = Get-ItemProperty -Path $regPath -ErrorAction Stop
                    if (-not $caConfigs -or $caConfigs.Count -eq 0) {
                        Write-Log -Level Error -Message "CA конфигурация не найдена в реестре" -Operation 'Alignment' -OutputPath $OutputPath
                        return $false
                    }
                    
                    $caConfig = $caConfigs | Select-Object -First 1
                    if (-not $caConfig -or -not $caConfig.PSChildName) {
                        Write-Log -Level Error -Message "Не удалось определить имя CA" -Operation 'Alignment' -OutputPath $OutputPath
                        return $false
                    }
                    
                    $caName = $caConfig.PSChildName
                    $fullRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\$caName"
                    
                    # Проверка прав на запись в реестр
                    $permCheck = Test-WritePermissions -Path (Split-Path $fullRegPath -Parent)
                    if (-not $permCheck.HasPermission) {
                        Write-Log -Level Error -Message "Нет прав на запись в реестр: $($permCheck.Reason)" -Operation 'Alignment' -OutputPath $OutputPath
                        return $false
                    }
                    
                    $currentValue = (Get-ItemProperty -Path $fullRegPath -Name 'CRLPublicationURLs' -ErrorAction SilentlyContinue).CRLPublicationURLs
                    
                    # Добавляем новый URL
                    $newValue = if ($currentValue) {
                        "$currentValue`n$newUrl"
                    }
                    else {
                        $newUrl
                    }
                    
                    # Повторная валидация перед записью
                    $finalUrlValidation = Test-UrlFormat -Url $newUrl
                    if (-not $finalUrlValidation.Valid) {
                        Write-Log -Level Error -Message "Валидация URL не прошла перед записью: $($finalUrlValidation.Reason)" -Operation 'Alignment' -OutputPath $OutputPath
                        return $false
                    }
                    
                    Set-ItemProperty -Path $fullRegPath -Name 'CRLPublicationURLs' -Value $newValue -ErrorAction Stop
                    
                    Write-Log -Level Info -Message "CRLPublicationURLs обновлён" -Operation 'Alignment' -OutputPath $OutputPath
                    return $true
                }
                catch {
                    Write-Log -Level Error -Message "Ошибка обновления CRLPublicationURLs: $_" -Operation 'Alignment' -OutputPath $OutputPath
                    return $false
                }
            } `
            -RollbackAction {
                param($changeData)
                try {
                    $oldUrls = $changeData.oldValue.urls
                    
                    # Rollback: восстановление старых URLs
                    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\*"
                    $caConfigs = Get-ItemProperty -Path $regPath -ErrorAction Stop
                    if (-not $caConfigs) {
                        Write-Log -Level Error -Message "CA конфигурация не найдена при rollback" -Operation 'Rollback' -OutputPath $OutputPath
                        return $false
                    }
                    
                    $caConfig = $caConfigs | Select-Object -First 1
                    if (-not $caConfig -or -not $caConfig.PSChildName) {
                        Write-Log -Level Error -Message "Не удалось определить имя CA при rollback" -Operation 'Rollback' -OutputPath $OutputPath
                        return $false
                    }
                    
                    $caName = $caConfig.PSChildName
                    $fullRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\$caName"
                    
                    Set-ItemProperty -Path $fullRegPath -Name 'CRLPublicationURLs' -Value $oldUrls -ErrorAction Stop
                    Write-Log -Level Info -Message "CRLPublicationURLs откачен к предыдущему значению" -Operation 'Rollback' -OutputPath $OutputPath
                    return $true
                }
                catch {
                    Write-Log -Level Error -Message "Ошибка rollback CRLPublicationURLs: $_" -Operation 'Rollback' -OutputPath $OutputPath
                    return $false
                }
            }
    }
}

function Invoke-CopyCRLToIis {
    Write-Log -Level Info -Message "Копирование CRL в IIS директории" -Operation 'Alignment' -OutputPath $OutputPath
    
    if (-not $config.copyRules.enabled) {
        Write-Log -Level Info -Message "Copy rules отключены" -Operation 'Alignment' -OutputPath $OutputPath
        return
    }
    
    $certEnrollPath = $config.iis.certEnrollPath
    if (-not (Test-Path $certEnrollPath)) {
        Write-Log -Level Warning -Message "CertEnroll путь не найден: $certEnrollPath" -Operation 'Alignment' -OutputPath $OutputPath
        return
    }
    
    # КРИТИЧЕСКАЯ ПРОВЕРКА: Валидация базового пути
    try {
        $resolvedCertEnrollPath = [System.IO.Path]::GetFullPath($certEnrollPath)
    }
    catch {
        Write-Log -Level Error -Message "Некорректный путь CertEnroll: $certEnrollPath" -Operation 'Alignment' -OutputPath $OutputPath
        return
    }
    
    $crlFiles = Get-ChildItem -Path $certEnrollPath -Filter '*.crl' -ErrorAction SilentlyContinue
    
    foreach ($crlFile in $crlFiles) {
        # КРИТИЧЕСКАЯ ПРОВЕРКА: Целостность CRL перед копированием
        $crlIntegrity = Test-CRLIntegrity -CRLPath $crlFile.FullName
        if (-not $crlIntegrity.Valid) {
            Write-Log -Level Warning -Message "CRL файл не прошёл проверку целостности: $($crlFile.Name) - $($crlIntegrity.Reason)" -Operation 'Alignment' -OutputPath $OutputPath
            continue
        }
        
        # КРИТИЧЕСКАЯ ПРОВЕРКА: Безопасность пути к файлу
        $fileSafety = Test-SafeFilePath -FilePath $crlFile.FullName -AllowedExtensions @('.crl') -BasePath $resolvedCertEnrollPath
        if (-not $fileSafety.Safe) {
            Write-Log -Level Error -Message "Небезопасный путь к файлу: $($fileSafety.Reason)" -Operation 'Alignment' -OutputPath $OutputPath
            continue
        }
        
        $destinations = @()
        
        if ($config.copyRules.fromCertEnroll.crl.enabled) {
            foreach ($dest in $config.copyRules.fromCertEnroll.crl.destinations) {
                $destPath = switch ($dest) {
                    'PKI/CDP' { $config.paths.pkiCdpPath }
                    'Certs' { $config.paths.legacyCertsPath }
                    default { $null }
                }
                
                if ($destPath) {
                    # КРИТИЧЕСКАЯ ПРОВЕРКА: Path traversal protection
                    try {
                        $resolvedDestPath = [System.IO.Path]::GetFullPath($destPath)
                        # Проверка, что путь находится в разрешенной директории (IIS web root)
                        $webRoot = [System.IO.Path]::GetFullPath($config.iis.webRootPath)
                        if (-not (Test-PathTraversal -Path $resolvedDestPath -BasePath $webRoot)) {
                            Write-Log -Level Error -Message "Путь назначения вне web root: $destPath" -Operation 'Alignment' -OutputPath $OutputPath
                            continue
                        }
                        $destinations += $resolvedDestPath
                    }
                    catch {
                        Write-Log -Level Error -Message "Некорректный путь назначения: $destPath - $_" -Operation 'Alignment' -OutputPath $OutputPath
                        continue
                    }
                }
            }
        }
        
        foreach ($destPath in $destinations) {
            if (-not (Test-Path $destPath)) {
                if ($Apply) {
                    # Проверка прав перед созданием директории
                    $permCheck = Test-WritePermissions -Path (Split-Path $destPath -Parent)
                    if (-not $permCheck.HasPermission) {
                        Write-Log -Level Error -Message "Нет прав на создание директории: $($permCheck.Reason)" -Operation 'Alignment' -OutputPath $OutputPath
                        continue
                    }
                    Test-PathExists -Path $destPath -CreateIfNotExists | Out-Null
                }
            }
            
            $destFile = Join-Path $destPath $crlFile.Name
            
            # КРИТИЧЕСКАЯ ПРОВЕРКА: Path traversal для файла назначения
            if (-not (Test-PathTraversal -Path $destFile -BasePath $destPath)) {
                Write-Log -Level Error -Message "Path traversal обнаружен в пути назначения: $destFile" -Operation 'Alignment' -OutputPath $OutputPath
                continue
            }
            
            # КРИТИЧЕСКАЯ ПРОВЕРКА: Безопасность файла назначения
            $destFileSafety = Test-SafeFilePath -FilePath $destFile -AllowedExtensions @('.crl') -BasePath $destPath
            if (-not $destFileSafety.Safe) {
                Write-Log -Level Error -Message "Небезопасный путь назначения: $($destFileSafety.Reason)" -Operation 'Alignment' -OutputPath $OutputPath
                continue
            }
            
            $needsCopy = $false
            if (-not (Test-Path $destFile)) {
                $needsCopy = $true
            }
            else {
                try {
                    $sourceTime = (Get-Item $crlFile.FullName).LastWriteTime
                    $destTime = (Get-Item $destFile).LastWriteTime
                    $needsCopy = $sourceTime -gt $destTime
                }
                catch {
                    Write-Log -Level Warning -Message "Ошибка сравнения времени файлов: $_" -Operation 'Alignment' -OutputPath $OutputPath
                    $needsCopy = $true
                }
            }
            
            if ($needsCopy) {
                Add-ChangePlan -Category 'CRL_Copy' -Description "Копирование CRL: $($crlFile.Name) -> $destPath" `
                    -OldValue @{ exists = (Test-Path $destFile); path = $destFile } -NewValue @{ path = $destFile; source = $crlFile.FullName } `
                    -ApplyAction {
                        param($changeData)
                        try {
                            # Повторная проверка целостности перед копированием
                            $sourceFile = $changeData.newValue.source
                            $destFile = $changeData.newValue.path
                            
                            $finalIntegrityCheck = Test-CRLIntegrity -CRLPath $sourceFile
                            if (-not $finalIntegrityCheck.Valid) {
                                Write-Log -Level Error -Message "CRL не прошёл финальную проверку целостности: $($finalIntegrityCheck.Reason)" -Operation 'Alignment' -OutputPath $OutputPath
                                return $false
                            }
                            
                            # Проверка прав на запись
                            $permCheck = Test-WritePermissions -Path (Split-Path $destFile -Parent)
                            if (-not $permCheck.HasPermission) {
                                Write-Log -Level Error -Message "Нет прав на запись: $($permCheck.Reason)" -Operation 'Alignment' -OutputPath $OutputPath
                                return $false
                            }
                            
                            # Создание backup существующего файла (если есть)
                            if (Test-Path $destFile) {
                                $backupFile = "$destFile.backup_$(Get-Timestamp)"
                                Copy-Item -Path $destFile -Destination $backupFile -ErrorAction SilentlyContinue
                            }
                            
                            Copy-Item -Path $sourceFile -Destination $destFile -Force -ErrorAction Stop
                            
                            # Проверка целостности скопированного файла
                            $copiedIntegrityCheck = Test-CRLIntegrity -CRLPath $destFile
                            if (-not $copiedIntegrityCheck.Valid) {
                                Write-Log -Level Error -Message "Скопированный CRL не прошёл проверку целостности. Откат." -Operation 'Alignment' -OutputPath $OutputPath
                                # Откат
                                if (Test-Path "$destFile.backup_*") {
                                    $backupFiles = Get-ChildItem -Path (Split-Path $destFile -Parent) -Filter "$(Split-Path $destFile -Leaf).backup_*"
                                    if ($backupFiles) {
                                        Copy-Item -Path $backupFiles[0].FullName -Destination $destFile -Force
                                    }
                                }
                                else {
                                    Remove-Item -Path $destFile -Force -ErrorAction SilentlyContinue
                                }
                                return $false
                            }
                            
                            Write-Log -Level Info -Message "CRL скопирован и проверен: $destFile" -Operation 'Alignment' -OutputPath $OutputPath
                            return $true
                        }
                        catch {
                            Write-Log -Level Error -Message "Ошибка копирования CRL: $_" -Operation 'Alignment' -OutputPath $OutputPath
                            return $false
                        }
                    } `
                    -RollbackAction {
                        param($changeData)
                        try {
                            $destFile = $changeData.newValue.path
                            $backupFiles = Get-ChildItem -Path (Split-Path $destFile -Parent) -Filter "$(Split-Path $destFile -Leaf).backup_*" -ErrorAction SilentlyContinue
                            if ($backupFiles) {
                                Copy-Item -Path $backupFiles[0].FullName -Destination $destFile -Force
                                Write-Log -Level Info -Message "CRL откачен из backup: $destFile" -Operation 'Rollback' -OutputPath $OutputPath
                            }
                            elseif ($changeData.oldValue.exists) {
                                # Файл существовал, но backup не найден - удаляем (если был создан скриптом)
                                Remove-Item -Path $destFile -Force -ErrorAction SilentlyContinue
                                Write-Log -Level Info -Message "CRL файл удалён (был создан скриптом): $destFile" -Operation 'Rollback' -OutputPath $OutputPath
                            }
                            return $true
                        }
                        catch {
                            Write-Log -Level Error -Message "Ошибка rollback CRL: $_" -Operation 'Rollback' -OutputPath $OutputPath
                            return $false
                        }
                    }
            }
        }
    }
}

#endregion

#region Применение изменений

function Invoke-ApplyChanges {
    Write-Log -Level Info -Message "Применение изменений..." -Operation 'Alignment' -OutputPath $OutputPath
    
    if (-not $Apply) {
        Write-Log -Level Info -Message "Режим WhatIf, изменения не применяются" -Operation 'Alignment' -OutputPath $OutputPath
        return
    }
    
    # Создание backup перед изменениями
    New-Backup -BackupType 'Registry' -Description 'Backup реестра перед выравниванием'
    New-Backup -BackupType 'IIS' -Description 'Backup IIS перед выравниванием'
    New-Backup -BackupType 'Certificates' -Description 'Backup сертификатов перед выравниванием'
    
    $appliedCount = 0
    $failedCount = 0
    
    foreach ($change in $script:AlignmentPlan.changes) {
        try {
            Write-Log -Level Info -Message "Применение изменения: $($change.description) (ID: $($change.changeId))" -Operation 'Alignment' -OutputPath $OutputPath
            
            # Передача данных изменения в applyAction
            if ($change.applyAction) {
                $result = & $change.applyAction $change
                if ($result) {
                    $change.applied = $true
                    $appliedCount++
                    Write-Log -Level Info -Message "Изменение применено успешно: $($change.changeId)" -Operation 'Alignment' -OutputPath $OutputPath
                }
                else {
                    $failedCount++
                    Write-Log -Level Warning -Message "Изменение не применено: $($change.changeId)" -Operation 'Alignment' -OutputPath $OutputPath
                }
            }
            else {
                Write-Log -Level Warning -Message "ApplyAction не определён для изменения: $($change.changeId)" -Operation 'Alignment' -OutputPath $OutputPath
                $failedCount++
            }
        }
        catch {
            Write-Log -Level Error -Message "Ошибка применения изменения: $_ (ID: $($change.changeId))" -Exception $_ -Operation 'Alignment' -OutputPath $OutputPath
            $failedCount++
        }
    }
    
    Write-Log -Level Info -Message "Изменения применены: $appliedCount успешно, $failedCount ошибок" -Operation 'Alignment' -OutputPath $OutputPath
}

#endregion

#region Rollback функции

#endregion

#region Экспорт плана

function Export-AlignmentPlan {
    $planPath = Join-Path $OutputPath "alignment_plan_$(Get-Timestamp).json"
    # Используем безопасную сериализацию, чтобы избежать ошибок вида
    # "Элемент с тем же ключом уже был добавлен" внутри ConvertTo-Json.
    $planJson = ConvertTo-SafeJson -InputObject $script:AlignmentPlan -Depth 10
    $planJson | Out-File -FilePath $planPath -Encoding UTF8
    
    Write-Log -Level Info -Message "План выравнивания экспортирован: $planPath" -Operation 'Alignment' -OutputPath $OutputPath
    return $planPath
}

#endregion

#region Main

try {
    # Создание backup перед началом
    if ($Backup) {
        Write-Log -Level Info -Message "Создание rollback point: $rollbackPointName" -Operation 'Alignment' -OutputPath $OutputPath
    }
    
    # Выполнение выравнивания
    Invoke-AlignIisMimeTypes
    Invoke-AlignIisAcls
    Invoke-AlignCRLPublication
    Invoke-CopyCRLToIis
    
    # Экспорт плана
    $planPath = Export-AlignmentPlan
    
    # Применение изменений (если -Apply)
    Invoke-ApplyChanges
    
    $duration = (Get-Date) - $script:StartTime
    Write-Log -Level Info -Message "Выравнивание завершено. Время выполнения: $($duration.TotalSeconds) сек" -Operation 'Alignment' -OutputPath $OutputPath
    
    Write-Host "`n=== Результаты выравнивания ===" -ForegroundColor Green
    Write-Host "Запланировано изменений: $($script:AlignmentPlan.changes.Count)" -ForegroundColor Cyan
    Write-Host "План: $planPath" -ForegroundColor Cyan
    Write-Host "Rollback point: $rollbackPointName" -ForegroundColor Cyan
    
    if (-not $Apply) {
        Write-Host "`n⚠️ Режим WhatIf. Используйте -Apply для применения изменений." -ForegroundColor Yellow
        exit 10
    }
    
    exit 0
}
catch {
    Write-Log -Level Error -Message "Критическая ошибка выравнивания: $_" -Exception $_ -Operation 'Alignment' -OutputPath $OutputPath
    exit 1
}

#endregion
