# PkiSecurity.psm1
# Функции безопасности для PKI операций

function Test-PathTraversal {
    <#
    .SYNOPSIS
    Проверяет путь на path traversal атаки.
    
    .PARAMETER Path
    Путь для проверки
    
    .PARAMETER BasePath
    Базовый путь, относительно которого проверяется
    
    .RETURNS
    $true если путь безопасен, $false если обнаружен path traversal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )
    
    try {
        # Нормализация путей
        $resolvedPath = [System.IO.Path]::GetFullPath($Path)
        $resolvedBase = [System.IO.Path]::GetFullPath($BasePath)

        # Проверка с учетом границ сегментов пути
        $pathForCompare = $resolvedPath.TrimEnd('\\', '/') + '\\'
        $baseForCompare = $resolvedBase.TrimEnd('\\', '/') + '\\'
        return $pathForCompare.StartsWith($baseForCompare, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        Write-Warning "Ошибка проверки path traversal: $_"
        return $false
    }
}

function Test-SafeFilePath {
    <#
    .SYNOPSIS
    Проверяет, что путь к файлу безопасен для операций.
    
    .PARAMETER FilePath
    Путь к файлу
    
    .PARAMETER AllowedExtensions
    Разрешенные расширения файлов
    
    .PARAMETER BasePath
    Базовый путь (опционально)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        
        [string[]]$AllowedExtensions = @('.crl', '.crt', '.cer'),
        
        [string]$BasePath = ''
    )
    
    # Проверка расширения
    $extension = [System.IO.Path]::GetExtension($FilePath)
    if ($extension -and $AllowedExtensions -notcontains $extension.ToLower()) {
        return @{
            Safe = $false
            Reason = "Расширение файла не разрешено: $extension"
        }
    }
    
    # Проверка path traversal (если указан базовый путь)
    if ($BasePath) {
        if (-not (Test-PathTraversal -Path $FilePath -BasePath $BasePath)) {
            return @{
                Safe = $false
                Reason = "Path traversal обнаружен: $FilePath"
            }
        }
    }
    
    return @{
        Safe = $true
        Reason = ''
    }
}

function Test-CAExists {
    <#
    .SYNOPSIS
    Проверяет существование и доступность CA.
    #>
    [CmdletBinding()]
    param(
        [string]$CAName = '*'
    )
    
    try {
        # Проверка через certutil
        $result = Get-CertUtilOutput -Arguments @('-getconfig', '-', '-ping') -IgnoreErrors -IncludeResult
        if ($null -ne $result -and $result.ExitCode -eq 0) {
            return @{
                Exists = $true
                Available = $true
            }
        }
        
        # Дополнительная проверка через реестр
        $regRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'
        if ($CAName -eq '*') {
            $caKeys = @(Get-ChildItem -Path $regRoot -ErrorAction SilentlyContinue)
            if ($caKeys.Count -gt 0) {
                return @{
                    Exists = $true
                    Available = $false
                }
            }
        }
        else {
            $regPath = Join-Path $regRoot $CAName
            if (Test-Path $regPath) {
                return @{
                    Exists = $true
                    Available = $false
                }
            }
        }

        if ($result -and $result.ExitCode -ne 0) {
            return @{
                Exists = $false
                Available = $false
                Error = "certutil ping failed with code $($result.ExitCode)"
            }
        }
        
        return @{
            Exists = $false
            Available = $false
        }
    }
    catch {
        return @{
            Exists = $false
            Available = $false
            Error = $_.Exception.Message
        }
    }
}

function Test-CRLIntegrity {
    <#
    .SYNOPSIS
    Проверяет целостность CRL файла.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CRLPath
    )
    
    if (-not (Test-Path $CRLPath)) {
        return @{
            Valid = $false
            Reason = "Файл не найден: $CRLPath"
        }
    }
    
    try {
        # Проверка через certutil -dump
        $output = Get-CertUtilOutput -Arguments @('-dump', $CRLPath) -IgnoreErrors
        
        # Проверка наличия обязательных полей
        $hasThisUpdate = $false
        $hasNextUpdate = $false
        $hasSignature = $false
        
        foreach ($line in $output) {
            if ($line -match 'ThisUpdate:') {
                $hasThisUpdate = $true
            }
            if ($line -match 'NextUpdate:') {
                $hasNextUpdate = $true
            }
            if ($line -match 'Signature Algorithm:') {
                $hasSignature = $true
            }
        }
        
        if (-not $hasThisUpdate -or -not $hasNextUpdate -or -not $hasSignature) {
            return @{
                Valid = $false
                Reason = "CRL файл поврежден или неполный"
            }
        }
        
        # Проверка размера файла (CRL не должен быть пустым)
        $fileInfo = Get-Item $CRLPath
        if ($fileInfo.Length -eq 0) {
            return @{
                Valid = $false
                Reason = "CRL файл пустой"
            }
        }
        
        return @{
            Valid = $true
            Reason = ''
        }
    }
    catch {
        return @{
            Valid = $false
            Reason = "Ошибка проверки CRL: $_"
        }
    }
}

function Test-UrlFormat {
    <#
    .SYNOPSIS
    Проверяет формат URL для CRL/AIA публикации.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )
    
    # Базовые проверки
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return @{
            Valid = $false
            Reason = "URL пустой"
        }
    }
    
    # Проверка формата URL
    try {
        $uri = [System.Uri]::new($Url)
        
        # Только HTTP/HTTPS разрешены
        if ($uri.Scheme -notin @('http', 'https')) {
            return @{
                Valid = $false
                Reason = "Неподдерживаемая схема URL: $($uri.Scheme)"
            }
        }
        
        # Проверка наличия хоста
        if ([string]::IsNullOrWhiteSpace($uri.Host)) {
            return @{
                Valid = $false
                Reason = "URL не содержит хоста"
            }
        }
        
        return @{
            Valid = $true
            Reason = ''
        }
    }
    catch {
        return @{
            Valid = $false
            Reason = "Некорректный формат URL: $_"
        }
    }
}

function Test-WritePermissions {
    <#
    .SYNOPSIS
    Проверяет права на запись в указанный путь.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [ValidateSet('FileSystem', 'Registry')]
        [string]$Provider = 'FileSystem'
    )
    
    try {
        if ($Provider -eq 'Registry') {
            if (-not (Test-Path $Path)) {
                return @{
                    HasPermission = $false
                    Reason = "Ключ реестра не существует: $Path"
                }
            }

            $testProperty = "pki_test_$([System.Guid]::NewGuid().ToString('N'))"
            try {
                New-ItemProperty -Path $Path -Name $testProperty -PropertyType String -Value 'test' -Force -ErrorAction Stop | Out-Null
                Remove-ItemProperty -Path $Path -Name $testProperty -Force -ErrorAction SilentlyContinue
                return @{
                    HasPermission = $true
                    Reason = ''
                }
            }
            catch {
                return @{
                    HasPermission = $false
                    Reason = "Нет прав на запись в реестр: $_"
                }
            }
        }

        # Проверка существования пути
        if (-not (Test-Path $Path)) {
            # Проверка прав на создание в родительской директории
            $parentPath = Split-Path -Path $Path -Parent
            if (-not (Test-Path $parentPath)) {
                return @{
                    HasPermission = $false
                    Reason = "Родительская директория не существует: $parentPath"
                }
            }
        }
        
        # Попытка создать тестовый файл
        $testFile = Join-Path $Path ".pki_test_$(Get-Random)"
        try {
            New-Item -ItemType File -Path $testFile -Force | Out-Null
            Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
            return @{
                HasPermission = $true
                Reason = ''
            }
        }
        catch {
            return @{
                HasPermission = $false
                Reason = "Нет прав на запись: $_"
            }
        }
    }
    catch {
        return @{
            HasPermission = $false
            Reason = "Ошибка проверки прав: $_"
        }
    }
}

Export-ModuleMember -Function Test-PathTraversal, Test-SafeFilePath, Test-CAExists, Test-CRLIntegrity, Test-UrlFormat, Test-WritePermissions
