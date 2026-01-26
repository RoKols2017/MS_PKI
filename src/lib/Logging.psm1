# Logging.psm1
# Модуль структурированного логирования

function Write-Log {
    <#
    .SYNOPSIS
    Записывает структурированное логирование.
    
    .PARAMETER Level
    Уровень логирования: Debug, Info, Warning, Error
    
    .PARAMETER Message
    Текст сообщения
    
    .PARAMETER Operation
    Название операции
    
    .PARAMETER Role
    Роль (CA0, CA1, IIS, Client, All)
    
    .PARAMETER Parameters
    Дополнительные параметры (hashtable)
    
    .PARAMETER Exception
    Объект исключения
    
    .PARAMETER OutputPath
    Путь для сохранения логов
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level,
        
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [string]$Operation = '',
        [string]$Role = '',
        [hashtable]$Parameters = @{},
        [Exception]$Exception = $null,
        [string]$OutputPath = ''
    )
    
    $logEntry = @{
        timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ")
        level     = $Level
        message   = $Message
    }
    
    if ($Operation) { $logEntry.operation = $Operation }
    if ($Role) { $logEntry.role = $Role }
    if ($Parameters.Count -gt 0) { $logEntry.parameters = $Parameters }
    if ($Exception) {
        $logEntry.exception = @{
            message = $Exception.Message
            type    = $Exception.GetType().FullName
            stack   = $Exception.StackTrace
        }
    }
    
    $logJson = $logEntry | ConvertTo-Json -Depth 10 -Compress
    
    # Консольный вывод
    $color = switch ($Level) {
        'Debug'   { 'Gray' }
        'Info'    { 'White' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
    }
    
    Write-Host "[$($Level)] $Message" -ForegroundColor $color
    if ($Exception) {
        Write-Host "  Exception: $($Exception.Message)" -ForegroundColor $color
    }
    
    # Файловый вывод
    if ($OutputPath) {
        $logFile = Join-Path $OutputPath "pki-$(Get-Date -Format 'yyyyMMdd').log"
        $logJson | Out-File -FilePath $logFile -Append -Encoding UTF8
    }
}

function Initialize-Logging {
    <#
    .SYNOPSIS
    Инициализирует логирование.
    #>
    [CmdletBinding()]
    param(
        [string]$OutputPath,
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    
    if ($OutputPath -and -not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        Write-Log -Level Info -Message "Создана директория для логов: $OutputPath" -OutputPath $OutputPath
    }
    
    $script:LogOutputPath = $OutputPath
    $script:LogLevel = $Level
    
    Write-Log -Level Info -Message "Логирование инициализировано. Уровень: $Level" -OutputPath $OutputPath
}

function Get-LogLevel {
    return $script:LogLevel
}

Export-ModuleMember -Function Write-Log, Initialize-Logging, Get-LogLevel
