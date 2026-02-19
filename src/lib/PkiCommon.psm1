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

function Invoke-ExternalCommand {
    <#
    .SYNOPSIS
    Безопасно выполняет внешнюю команду с timeout/retry и сбором stdout/stderr.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [int]$TimeoutSeconds = 60,

        [int]$RetryCount = 0,

        [int]$RetryDelaySeconds = 2,

        [switch]$IgnoreErrors
    )

    $attempt = 0
    $maxAttempts = [Math]::Max(1, $RetryCount + 1)
    $lastResult = $null

    while ($attempt -lt $maxAttempts) {
        $attempt++
        $stdOutFile = [System.IO.Path]::GetTempFileName()
        $stdErrFile = [System.IO.Path]::GetTempFileName()

        try {
            $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru -RedirectStandardOutput $stdOutFile -RedirectStandardError $stdErrFile -ErrorAction Stop

            if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
                try { $proc.Kill() } catch {}
                throw "Таймаут выполнения команды ($TimeoutSeconds сек): $FilePath $($Arguments -join ' ')"
            }

            $stdOut = Get-Content -Path $stdOutFile -Raw -ErrorAction SilentlyContinue
            $stdErr = Get-Content -Path $stdErrFile -Raw -ErrorAction SilentlyContinue

            $lastResult = @{
                FilePath    = $FilePath
                Arguments   = $Arguments
                ExitCode    = [int]$proc.ExitCode
                StdOut      = $stdOut
                StdErr      = $stdErr
                Attempt     = $attempt
                CommandLine = "$FilePath $($Arguments -join ' ')"
            }

            if ($lastResult.ExitCode -eq 0 -or $IgnoreErrors) {
                return $lastResult
            }

            if ($attempt -lt $maxAttempts) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
        catch {
            if ($attempt -ge $maxAttempts) {
                if ($IgnoreErrors) {
                    return $lastResult
                }
                throw
            }

            Start-Sleep -Seconds $RetryDelaySeconds
        }
        finally {
            Remove-Item -Path $stdOutFile -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $stdErrFile -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $IgnoreErrors -and $lastResult -and $lastResult.ExitCode -ne 0) {
        throw "Команда завершилась с кодом $($lastResult.ExitCode): $($lastResult.CommandLine)`nSTDERR: $($lastResult.StdErr)"
    }

    return $lastResult
}

function Convert-CommandTextToLines {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return @()
    }

    return @($Text -split "`r?`n" | Where-Object { $_ -ne '' })
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
        
        [switch]$IgnoreErrors,

        [switch]$IncludeResult,

        [int]$TimeoutSeconds = 120,

        [int]$RetryCount = 1
    )
    
    try {
        $result = Invoke-ExternalCommand -FilePath 'certutil.exe' -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds -RetryCount $RetryCount -RetryDelaySeconds 2 -IgnoreErrors:$IgnoreErrors
        if (-not $result) {
            return $null
        }

        $lines = @()
        $lines += Convert-CommandTextToLines -Text $result.StdOut
        $lines += Convert-CommandTextToLines -Text $result.StdErr

        if ($result.ExitCode -ne 0 -and -not $IgnoreErrors) {
            Write-Warning "certutil завершился с кодом $($result.ExitCode). Аргументы: $($Arguments -join ' ')"
        }

        if ($IncludeResult) {
            return [PSCustomObject]@{
                ExitCode = [int]$result.ExitCode
                Output   = $lines
                StdOut   = $result.StdOut
                StdErr   = $result.StdErr
            }
        }

        return $lines
    }
    catch {
        if (-not $IgnoreErrors) {
            throw "Ошибка выполнения certutil: $_"
        }

        if ($IncludeResult) {
            return [PSCustomObject]@{
                ExitCode = -1
                Output   = @()
                StdOut   = ''
                StdErr   = ''
            }
        }

        return $null
    }
}

function Get-AppCmdOutput {
    <#
    .SYNOPSIS
    Выполняет appcmd.exe и возвращает вывод.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [switch]$IgnoreErrors,

        [int]$TimeoutSeconds = 60
    )

    $appCmdPath = Join-Path $env:SystemRoot 'System32\inetsrv\appcmd.exe'
    if (-not (Test-Path $appCmdPath)) {
        if ($IgnoreErrors) {
            return @()
        }
        throw "appcmd.exe не найден: $appCmdPath"
    }

    $result = Invoke-ExternalCommand -FilePath $appCmdPath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds -IgnoreErrors:$IgnoreErrors
    if (-not $result) {
        return @()
    }

    $lines = @()
    $lines += Convert-CommandTextToLines -Text $result.StdOut
    $lines += Convert-CommandTextToLines -Text $result.StdErr
    return $lines
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
        $result = Invoke-ExternalCommand -FilePath 'reg.exe' -Arguments @('export', 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration', $backupPath, '/y') -TimeoutSeconds 60
        if (-not $result -or $result.ExitCode -ne 0) {
            Write-Warning "reg export завершился с ошибкой."
            return $null
        }
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

Export-ModuleMember -Function Import-PkiConfig, Test-PkiConfig, Test-Administrator, Assert-Administrator, Invoke-ExternalCommand, Get-CertUtilOutput, Get-AppCmdOutput, Get-RegistryValue, Export-RegistryBackup, Get-ServiceStatus, Test-PathExists, Get-Timestamp, ConvertTo-SafeJson
