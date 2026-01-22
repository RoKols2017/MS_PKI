# Http.psm1
# Функции для работы с HTTP и IIS

function Test-HttpEndpoint {
    <#
    .SYNOPSIS
    Проверяет доступность HTTP endpoint.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        
        [int]$TimeoutSeconds = 10,
        
        [switch]$CheckContent
    )
    
    try {
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Timeout = $TimeoutSeconds * 1000
        $request.Method = "HEAD"
        
        $response = $request.GetResponse()
        $statusCode = [int]$response.StatusCode
        $response.Close()
        
        $result = @{
            Url        = $Url
            Available  = ($statusCode -ge 200 -and $statusCode -lt 400)
            StatusCode = $statusCode
            Timestamp  = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
        }
        
        if ($CheckContent) {
            try {
                $content = Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
                $result.ContentLength = $content.Content.Length
                $result.ContentType = $content.Headers.'Content-Type'
            }
            catch {
                $result.ContentError = $_.Exception.Message
            }
        }
        
        return $result
    }
    catch {
        return @{
            Url        = $Url
            Available  = $false
            StatusCode = 0
            Error      = $_.Exception.Message
            Timestamp  = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
        }
    }
}

function Get-IisSite {
    <#
    .SYNOPSIS
    Получает информацию о IIS сайте.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SiteName
    )
    
    try {
        Import-Module WebAdministration -ErrorAction Stop
        
        $site = Get-WebSite -Name $SiteName -ErrorAction SilentlyContinue
        if (-not $site) {
            return $null
        }
        
        $bindings = Get-WebBinding -Name $SiteName
        $vdirs = Get-WebVirtualDirectory -Site $SiteName
        
        return @{
            Name         = $site.Name
            State        = $site.State
            PhysicalPath = $site.PhysicalPath
            Bindings     = $bindings | ForEach-Object {
                @{
                    Protocol = $_.Protocol
                    Port     = $_.BindingInformation.Split(':')[1]
                    Hostname = $_.BindingInformation.Split(':')[2]
                }
            }
            VirtualDirectories = $vdirs | ForEach-Object {
                @{
                    Path        = $_.Path
                    PhysicalPath = $_.PhysicalPath
                }
            }
        }
    }
    catch {
        Write-Warning "Ошибка получения информации о IIS сайте: $_"
        return $null
    }
}

function Get-IisMimeTypes {
    <#
    .SYNOPSIS
    Получает MIME типы из IIS.
    #>
    [CmdletBinding()]
    param(
        [string]$SiteName = ''
    )
    
    try {
        Import-Module WebAdministration -ErrorAction Stop
        
        if ($SiteName) {
            $mimeTypes = Get-WebConfigurationProperty -Filter "system.webServer/staticContent" -Name "." -PSPath "IIS:\Sites\$SiteName"
        }
        else {
            $mimeTypes = Get-WebConfigurationProperty -Filter "system.webServer/staticContent" -Name "." -PSPath "MACHINE/WEBROOT/APPHOST"
        }
        
        return $mimeTypes | ForEach-Object {
            @{
                Extension = $_.fileExtension
                MimeType  = $_.mimeType
            }
        }
    }
    catch {
        Write-Warning "Ошибка получения MIME типов: $_"
        return @()
    }
}

function Test-IisMimeType {
    <#
    .SYNOPSIS
    Проверяет наличие MIME типа в IIS.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Extension,
        
        [Parameter(Mandatory = $true)]
        [string]$MimeType,
        
        [string]$SiteName = ''
    )
    
    $mimeTypes = Get-IisMimeTypes -SiteName $SiteName
    $found = $mimeTypes | Where-Object { $_.Extension -eq $Extension -and $_.MimeType -eq $MimeType }
    
    return ($null -ne $found)
}

function Get-FileAcl {
    <#
    .SYNOPSIS
    Получает ACL файла или директории.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    if (-not (Test-Path $Path)) {
        return $null
    }
    
    try {
        $acl = Get-Acl -Path $Path
        return $acl | ForEach-Object {
            @{
                Path        = $Path
                Owner       = $_.Owner
                AccessRules = $_.Access | ForEach-Object {
                    @{
                        Identity    = $_.IdentityReference.Value
                        Rights      = $_.FileSystemRights.ToString()
                        AccessType  = $_.AccessControlType.ToString()
                        IsInherited = $_.IsInherited
                    }
                }
            }
        }
    }
    catch {
        Write-Warning "Ошибка получения ACL: $_"
        return $null
    }
}

Export-ModuleMember -Function Test-HttpEndpoint, Get-IisSite, Get-IisMimeTypes, Test-IisMimeType, Get-FileAcl
