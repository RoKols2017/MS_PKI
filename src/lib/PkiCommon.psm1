# PkiCommon.psm1
# Общие функции для работы с PKI

function Import-PkiConfig {
    <#
    .SYNOPSIS
    Загружает конфигурацию из JSON файла.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )
    
    if (-not (Test-Path $ConfigPath)) {
        throw "Конфигурационный файл не найден: $ConfigPath"
    }
    
    try {
        $config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return $config
    }
    catch {
        throw "Ошибка загрузки конфигурации: $_"
    }
}

function Test-PkiConfig {
    <#
    .SYNOPSIS
    Проверяет наличие обязательных полей в конфигурации env.json.
    
    .PARAMETER Config
    Объект конфигурации (результат Import-PkiConfig).
    
    .PARAMETER ForAlignment
    Если указан, проверяются дополнительные поля, необходимые для Alignment.
    
    .OUTPUTS
    $true если конфигурация валидна. Иначе выбрасывает исключение.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,
        
        [switch]$ForAlignment
    )
    
    $required = @('domain', 'ca0', 'ca1', 'iis', 'paths', 'endpoints')
    foreach ($key in $required) {
        if ($null -eq $Config.$key) {
            throw "Обязательное поле конфигурации отсутствует: $key"
        }
    }
    
    # Проверка критичных вложенных полей
    if (-not $Config.ca1.name) {
        throw "Обязательное поле конфигурации отсутствует: ca1.name"
    }
    if (-not $Config.iis.siteName) {
        throw "Обязательное поле конфигурации отсутствует: iis.siteName"
    }
    if (-not $Config.iis.certEnrollPath) {
        throw "Обязательное поле конфигурации отсутствует: iis.certEnrollPath"
    }
    
    if ($ForAlignment) {
        if (-not $Config.namespaces -or -not $Config.namespaces.canonical -or -not $Config.namespaces.canonical.cdp) {
            throw "Обязательное поле для Alignment отсутствует: namespaces.canonical.cdp"
        }
        if (-not $Config.copyRules) {
            throw "Обязательное поле для Alignment отсутствует: copyRules"
        }
    }
    
    return $true
}

function Test-Administrator {
    <#
    .SYNOPSIS
    Проверяет, запущен ли скрипт с правами администратора.
    #>
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    <#
    .SYNOPSIS
    Проверяет права администратора и выбрасывает исключение, если их нет.
    #>
    if (-not (Test-Administrator)) {
        throw "Скрипт должен быть запущен с правами администратора."
    }
}

function Get-CertUtilOutput {
    <#
    .SYNOPSIS
    Выполняет certutil команду и возвращает вывод.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        
        [switch]$IgnoreErrors
    )
    
    try {
        $output = & certutil $Arguments 2>&1
        if ($LASTEXITCODE -ne 0 -and -not $IgnoreErrors) {
            Write-Warning "certutil завершился с кодом $LASTEXITCODE. Аргументы: $($Arguments -join ' ')"
        }
        return $output
    }
    catch {
        if (-not $IgnoreErrors) {
            throw "Ошибка выполнения certutil: $_"
        }
        return $null
    }
}

function Get-RegistryValue {
    <#
    .SYNOPSIS
    Получает значение из реестра CA.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        
        [string]$ValueName = ''
    )
    
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\$Key"
    
    if (-not (Test-Path $regPath)) {
        return $null
    }
    
    if ($ValueName) {
        $value = Get-ItemProperty -Path $regPath -Name $ValueName -ErrorAction SilentlyContinue
        return $value.$ValueName
    }
    else {
        return Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
    }
}

function Export-RegistryBackup {
    <#
    .SYNOPSIS
    Создаёт backup реестра CA.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        
        [string]$CAName = '*'
    )
    
    $backupPath = Join-Path $OutputPath "registry_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').reg"
    
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration"
    
    if (-not (Test-Path $regPath)) {
        Write-Warning "Путь реестра не найден: $regPath"
        return $null
    }
    
    try {
        reg export "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration" $backupPath /y | Out-Null
        return $backupPath
    }
    catch {
        Write-Warning "Ошибка экспорта реестра: $_"
        return $null
    }
}

function Get-ServiceStatus {
    <#
    .SYNOPSIS
    Получает статус службы.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName
    )
    
    try {
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($service) {
            return @{
                Name      = $service.Name
                Status    = $service.Status.ToString()
                StartType = $service.StartType.ToString()
            }
        }
        return $null
    }
    catch {
        return $null
    }
}

function Test-PathExists {
    <#
    .SYNOPSIS
    Проверяет существование пути и создаёт, если не существует.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [switch]$CreateIfNotExists
    )
    
    if (-not (Test-Path $Path)) {
        if ($CreateIfNotExists) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            return $true
        }
        return $false
    }
    return $true
}

function Get-Timestamp {
    <#
    .SYNOPSIS
    Возвращает timestamp для именования файлов.
    #>
    return Get-Date -Format "yyyyMMdd_HHmmss"
}

function ConvertTo-SafeJson {
    <#
    .SYNOPSIS
    Конвертирует объект в JSON с обработкой ошибок.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,
        
        [int]$Depth = 10
    )
    
    try {
        return $InputObject | ConvertTo-Json -Depth $Depth -Compress
    }
    catch {
        # Попытка сериализации без проблемных свойств
        $cleaned = $InputObject | Select-Object -Property * -ExcludeProperty PS*, Runspace, SyncRoot
        return $cleaned | ConvertTo-Json -Depth $Depth -Compress
    }
}

Export-ModuleMember -Function Import-PkiConfig, Test-PkiConfig, Test-Administrator, Assert-Administrator, Get-CertUtilOutput, Get-RegistryValue, Export-RegistryBackup, Get-ServiceStatus, Test-PathExists, Get-Timestamp, ConvertTo-SafeJson
