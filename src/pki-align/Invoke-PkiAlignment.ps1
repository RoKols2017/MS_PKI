# Invoke-PkiAlignment.ps1
# Phase 4: safe PKI alignment

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    [string]$BaselinePath = '',
    [switch]$Apply,
    [switch]$Backup,
    [switch]$RestartCertSvc,
    [string]$RollbackPointName = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:StartTime = Get-Date
$script:AlignmentPlan = @{
    timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'
    changes = @()
    backups = @()
    rollbackPoints = @()
}

$libPath = Join-Path $PSScriptRoot '..\lib'
Import-Module (Join-Path $libPath 'Logging.psm1') -Force
Import-Module (Join-Path $libPath 'PkiCommon.psm1') -Force
Import-Module (Join-Path $libPath 'Http.psm1') -Force
Import-Module (Join-Path $libPath 'CertUtil.psm1') -Force
Import-Module (Join-Path $libPath 'PkiSecurity.psm1') -Force

if (-not $PSBoundParameters.ContainsKey('Apply')) { $Apply = $false }
if (-not $PSBoundParameters.ContainsKey('Backup')) { $Backup = $true }

Initialize-Logging -OutputPath $OutputPath -Level 'Info'

if (-not $Apply) {
    Write-Log -Level Info -Message 'WhatIf mode. Use -Apply to execute changes.' -Operation 'Alignment' -OutputPath $OutputPath
}

try {
    Assert-Administrator
}
catch {
    Write-Log -Level Error -Message $_ -Operation 'Alignment' -OutputPath $OutputPath
    exit 3
}

$config = Import-PkiConfig -ConfigPath $ConfigPath
Test-PkiConfig -Config $config -ForAlignment | Out-Null

$baseline = $null
if ($BaselinePath -and (Test-Path $BaselinePath)) {
    try {
        $baseline = Get-Content -Path $BaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Log -Level Info -Message "Baseline loaded: $BaselinePath" -Operation 'Alignment' -OutputPath $OutputPath
    }
    catch {
        Write-Log -Level Warning -Message "Baseline load error: $_" -Operation 'Alignment' -OutputPath $OutputPath
    }
}

function Get-CaRegistryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $regRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'
    $caKeys = @(Get-ChildItem -Path $regRoot -ErrorAction Stop)

    if ($caKeys.Count -eq 0) {
        throw "CA configuration not found in registry: $regRoot"
    }

    $targetCaName = if ($Config.ca1 -and $Config.ca1.name) { [string]$Config.ca1.name } else { '' }
    if ([string]::IsNullOrWhiteSpace($targetCaName)) {
        if ($caKeys.Count -eq 1) {
            return (Join-Path $regRoot $caKeys[0].PSChildName)
        }

        throw 'Multiple CA configurations found; config.ca1.name is required for unambiguous targeting.'
    }

    $matched = @($caKeys | Where-Object { $_.PSChildName -eq $targetCaName })
    if ($matched.Count -ne 1) {
        throw "CA configuration '$targetCaName' not found or ambiguous in registry."
    }

    return (Join-Path $regRoot $matched[0].PSChildName)
}

function Get-PublicationEntryUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Entry
    )

    $trimmed = $Entry.Trim()
    if ($trimmed -match '^\d+:(.+)$') {
        return $matches[1].Trim()
    }

    return $trimmed
}

function Merge-CrlPublicationUrls {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$CurrentRaw,

        [Parameter(Mandatory = $true)]
        [string]$NewUrl
    )

    $entries = @()
    if (-not [string]::IsNullOrWhiteSpace($CurrentRaw)) {
        $entries = @($CurrentRaw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $normalizedEntries = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $entries) {
        $exists = $false
        foreach ($existingEntry in $normalizedEntries) {
            if ([string]::Equals($existingEntry, $entry, [System.StringComparison]::OrdinalIgnoreCase)) {
                $exists = $true
                break
            }
        }

        if (-not $exists) {
            [void]$normalizedEntries.Add($entry)
        }
    }

    foreach ($entry in $normalizedEntries) {
        $entryUrl = Get-PublicationEntryUrl -Entry $entry
        if ([string]::Equals($entryUrl, $NewUrl, [System.StringComparison]::OrdinalIgnoreCase)) {
            return ($normalizedEntries -join "`n")
        }
    }

    $flagPrefix = '65'
    foreach ($entry in $normalizedEntries) {
        if ($entry -match '^(\d+):https?://') {
            $flagPrefix = $matches[1]
            break
        }
    }

    [void]$normalizedEntries.Add("$flagPrefix:$NewUrl")
    return ($normalizedEntries -join "`n")
}

$rollbackPointName = if ($RollbackPointName) { $RollbackPointName } else { "alignment_$(Get-Timestamp)" }
$rollbackPath = Join-Path $OutputPath "backups\$rollbackPointName"
Test-PathExists -Path $rollbackPath -CreateIfNotExists | Out-Null

function New-Backup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupType,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if (-not $Backup) {
        Write-Log -Level Info -Message "Backup disabled, skip: $BackupType" -Operation 'Backup' -OutputPath $OutputPath
        return $null
    }

    $backupInfo = @{
        type = $BackupType
        description = $Description
        timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'
        path = $null
    }

    try {
        switch ($BackupType) {
            'Registry' {
                $backupInfo.path = Export-RegistryBackup -OutputPath $rollbackPath
            }
            'IIS' {
                Import-Module WebAdministration -ErrorAction Stop
                $backupName = "pki_alignment_$(Get-Timestamp)"
                & "$env:SystemRoot\System32\inetsrv\appcmd.exe" backup $backupName | Out-Null
                $backupInfo.path = "$env:SystemRoot\System32\inetsrv\backup\$backupName"
            }
            'Certificates' {
                $certBackupPath = Join-Path $rollbackPath 'certificates'
                Test-PathExists -Path $certBackupPath -CreateIfNotExists | Out-Null
                if ($config.iis -and $config.iis.certEnrollPath -and (Test-Path $config.iis.certEnrollPath)) {
                    Copy-Item -Path (Join-Path $config.iis.certEnrollPath '*') -Destination $certBackupPath -Recurse -ErrorAction SilentlyContinue
                    $backupInfo.path = $certBackupPath
                }
            }
        }

        $script:AlignmentPlan.backups += $backupInfo
        return $backupInfo
    }
    catch {
        Write-Log -Level Warning -Message "Backup error for $BackupType : $_" -Operation 'Backup' -OutputPath $OutputPath
        return $null
    }
}

function Add-ChangePlan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,
        [Parameter(Mandatory = $true)]
        [string]$Description,
        [Parameter(Mandatory = $true)]
        [object]$OldValue,
        [Parameter(Mandatory = $true)]
        [object]$NewValue,
        [Parameter(Mandatory = $true)]
        [string]$ActionType
    )

    $change = @{
        category = $Category
        description = $Description
        oldValue = $OldValue
        newValue = $NewValue
        actionType = $ActionType
        applied = $false
        rolledBack = $false
        timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'
        changeId = [System.Guid]::NewGuid().ToString()
    }

    $script:AlignmentPlan.changes += $change
}

function Invoke-AlignIisMimeTypes {
    $siteName = $config.iis.siteName
    if (-not $siteName) { return }

    $requiredMimeTypes = @(
        @{ Extension = '.crl'; MimeType = 'application/pkix-crl' },
        @{ Extension = '.crt'; MimeType = 'application/x-x509-ca-cert' },
        @{ Extension = '.cer'; MimeType = 'application/x-x509-ca-cert' }
    )

    foreach ($mime in $requiredMimeTypes) {
        $exists = Test-IisMimeType -Extension $mime.Extension -MimeType $mime.MimeType -SiteName $siteName
        if (-not $exists) {
            Add-ChangePlan -Category 'IIS_MIME' -Description "Add MIME type: $($mime.Extension) -> $($mime.MimeType)" -OldValue @{ exists = $false } -NewValue @{ Extension = $mime.Extension; MimeType = $mime.MimeType; SiteName = $siteName } -ActionType 'IIS_MIME'
        }
    }
}

function Invoke-AlignIisAcls {
    $pkiPaths = @(
        $config.paths.pkiWebRoot,
        $config.paths.pkiAiaPath,
        $config.paths.pkiCdpPath
    ) | Where-Object { $_ }

    foreach ($path in $pkiPaths) {
        if (-not (Test-Path $path) -and $Apply) {
            Test-PathExists -Path $path -CreateIfNotExists | Out-Null
        }
        if (-not (Test-Path $path)) { continue }

        $acl = Get-Acl -Path $path -ErrorAction SilentlyContinue
        if (-not $acl) { continue }

        $hasReadAccess = $acl.Access | Where-Object {
            $_.IdentityReference -like '*IIS_IUSRS*' -and
            $_.FileSystemRights -match 'Read' -and
            $_.AccessControlType -eq 'Allow'
        }

        if (-not $hasReadAccess) {
            $aclBackupPath = Join-Path $rollbackPath "acl_$([System.Guid]::NewGuid().ToString()).xml"
            try {
                $acl | Export-Clixml -Path $aclBackupPath -ErrorAction Stop
            }
            catch {
                $aclBackupPath = ''
            }

            Add-ChangePlan -Category 'IIS_ACL' -Description "Set ACL for $path" -OldValue @{ path = $path; aclBackupPath = $aclBackupPath } -NewValue @{ path = $path } -ActionType 'IIS_ACL'
        }
    }
}

function Invoke-AlignCRLPublication {
    if (-not $baseline -or -not $baseline.ca1 -or -not $baseline.ca1.registry) {
        Write-Log -Level Warning -Message 'No baseline. Skip CRL publication alignment.' -Operation 'Alignment' -OutputPath $OutputPath
        return
    }

    $currentUrls = $baseline.ca1.registry.PublicationURLs.CRL
    $canonicalCdp = $config.namespaces.canonical.cdp
    if (-not $canonicalCdp) { return }

    $hostForUrl = if ($config.ca1.dnsName) { $config.ca1.dnsName } else { $config.ca1.hostname }
    $newUrl = "http://$hostForUrl$canonicalCdp/{CAName}{CRLNameSuffix}{DeltaCRLAllowed}.crl"
    $urlValidation = Test-UrlFormat -Url $newUrl
    if (-not $urlValidation.Valid) {
        Write-Log -Level Error -Message "Invalid URL format: $($urlValidation.Reason)" -Operation 'Alignment' -OutputPath $OutputPath
        return
    }

    $mergedUrls = Merge-CrlPublicationUrls -CurrentRaw $currentUrls -NewUrl $newUrl
    if ([string]::Equals([string]$mergedUrls, [string]$currentUrls, [System.StringComparison]::Ordinal)) {
        return
    }

    Add-ChangePlan -Category 'CRL_Publication' -Description 'Add canonical path into CRLPublicationURLs' -OldValue @{ urls = $currentUrls } -NewValue @{ urls = $mergedUrls; newUrl = $newUrl } -ActionType 'CRL_Publication'
}

function Invoke-CopyCRLToIis {
    if (-not $config.copyRules.enabled) { return }
    $certEnrollPath = $config.iis.certEnrollPath
    if (-not $certEnrollPath -or -not (Test-Path $certEnrollPath)) { return }

    $resolvedCertEnrollPath = [System.IO.Path]::GetFullPath($certEnrollPath)
    $crlFiles = Get-ChildItem -Path $certEnrollPath -Filter '*.crl' -ErrorAction SilentlyContinue

    foreach ($crlFile in $crlFiles) {
        $crlIntegrity = Test-CRLIntegrity -CRLPath $crlFile.FullName
        if (-not $crlIntegrity.Valid) { continue }

        $fileSafety = Test-SafeFilePath -FilePath $crlFile.FullName -AllowedExtensions @('.crl') -BasePath $resolvedCertEnrollPath
        if (-not $fileSafety.Safe) { continue }

        $destinations = @()
        if ($config.copyRules.fromCertEnroll.crl.enabled) {
            foreach ($dest in $config.copyRules.fromCertEnroll.crl.destinations) {
                $destPath = switch ($dest) {
                    'PKI/CDP' { $config.paths.pkiCdpPath }
                    'Certs' { $config.paths.legacyCertsPath }
                    default { $null }
                }
                if ($destPath) {
                    $resolvedDestPath = [System.IO.Path]::GetFullPath($destPath)
                    $webRoot = [System.IO.Path]::GetFullPath($config.iis.webRootPath)
                    if (Test-PathTraversal -Path $resolvedDestPath -BasePath $webRoot) {
                        $destinations += $resolvedDestPath
                    }
                }
            }
        }

        foreach ($destPath in $destinations) {
            $destFile = Join-Path $destPath $crlFile.Name
            if (-not (Test-PathTraversal -Path $destFile -BasePath $destPath)) { continue }
            $destFileSafety = Test-SafeFilePath -FilePath $destFile -AllowedExtensions @('.crl') -BasePath $destPath
            if (-not $destFileSafety.Safe) { continue }

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
                    $needsCopy = $true
                }
            }

            if ($needsCopy) {
                $backupPath = ''
                if (Test-Path $destFile) {
                    $backupPath = Join-Path $rollbackPath "filebackup_$([System.Guid]::NewGuid().ToString()).crl"
                    try { Copy-Item -Path $destFile -Destination $backupPath -Force -ErrorAction Stop } catch { $backupPath = '' }
                }

                Add-ChangePlan -Category 'CRL_Copy' -Description "Copy CRL: $($crlFile.Name) -> $destPath" -OldValue @{ exists = (Test-Path $destFile); path = $destFile; backupPath = $backupPath } -NewValue @{ source = $crlFile.FullName; path = $destFile; destination = $destPath } -ActionType 'CRL_Copy'
            }
        }
    }
}

function Invoke-ApplyChange {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Change
    )

    switch ([string]$Change.actionType) {
        'IIS_MIME' {
            Import-Module WebAdministration -ErrorAction Stop
            $mimeData = $Change.newValue
            Add-WebConfigurationProperty -Filter 'system.webServer/staticContent' -Name '.' -PSPath "IIS:\Sites\$($mimeData.SiteName)" -Value @{ fileExtension = $mimeData.Extension; mimeType = $mimeData.MimeType } -ErrorAction Stop
            return $true
        }
        'IIS_ACL' {
            $targetPath = $Change.newValue.path
            $currentAcl = Get-Acl -Path $targetPath
            $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule('IIS_IUSRS', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $currentAcl.SetAccessRule($accessRule)
            Set-Acl -Path $targetPath -AclObject $currentAcl
            return $true
        }
        'CRL_Publication' {
            $caCheck = Test-CAExists
            if (-not $caCheck.Exists) { return $false }
            $fullRegPath = Get-CaRegistryPath -Config $config
            $permCheck = Test-WritePermissions -Path $fullRegPath -Provider Registry
            if (-not $permCheck.HasPermission) { return $false }

            Set-ItemProperty -Path $fullRegPath -Name 'CRLPublicationURLs' -Value $Change.newValue.urls -ErrorAction Stop
            return $true
        }
        'CRL_Copy' {
            $src = $Change.newValue.source
            $dst = $Change.newValue.path
            $dstDir = Split-Path $dst -Parent
            if (-not (Test-Path $dstDir)) { Test-PathExists -Path $dstDir -CreateIfNotExists | Out-Null }

            $permCheck = Test-WritePermissions -Path $dstDir
            if (-not $permCheck.HasPermission) { return $false }

            Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop
            $copiedIntegrity = Test-CRLIntegrity -CRLPath $dst
            return [bool]$copiedIntegrity.Valid
        }
        default {
            return $false
        }
    }
}

function Invoke-ApplyChanges {
    if (-not $Apply) {
        Write-Log -Level Info -Message 'WhatIf mode, no changes applied.' -Operation 'Alignment' -OutputPath $OutputPath
        return
    }

    New-Backup -BackupType 'Registry' -Description 'Registry backup before alignment' | Out-Null
    New-Backup -BackupType 'IIS' -Description 'IIS backup before alignment' | Out-Null
    New-Backup -BackupType 'Certificates' -Description 'Certificate backup before alignment' | Out-Null

    $appliedCount = 0
    $failedCount = 0
    $restartNeeded = $false

    foreach ($change in $script:AlignmentPlan.changes) {
        try {
            if ($PSCmdlet.ShouldProcess($change.description, 'Apply PKI alignment change')) {
                $ok = Invoke-ApplyChange -Change $change
                if ($ok) {
                    $change.applied = $true
                    $appliedCount++
                    
                    # Check if this change requires service restart
                    if ($change.actionType -eq 'CRL_Publication') {
                        $restartNeeded = $true
                    }
                }
                else {
                    $failedCount++
                }
            }
        }
        catch {
            $failedCount++
            Write-Log -Level Error -Message "Apply error: $_ (ID: $($change.changeId))" -Exception $_ -Operation 'Alignment' -OutputPath $OutputPath
        }
    }

    if ($restartNeeded -and $RestartCertSvc) {
        Write-Log -Level Info -Message "Restarting CertSvc to apply changes..." -Operation 'Alignment' -OutputPath $OutputPath
        try {
            $serviceName = if ($config.ca1.serviceName) { $config.ca1.serviceName } else { 'CertSvc' }
            Restart-Service -Name $serviceName -Force -ErrorAction Stop
            Write-Log -Level Info -Message "Service $serviceName restarted successfully." -Operation 'Alignment' -OutputPath $OutputPath
        }
        catch {
            Write-Log -Level Error -Message "Failed to restart service: $_" -Operation 'Alignment' -OutputPath $OutputPath
            Write-Warning "Failed to restart service. Restart it manually in approved change window."
        }
    }
    elseif ($restartNeeded) {
        Write-Log -Level Warning -Message 'CRL publication settings changed. Restart CertSvc manually in approved window or run with -RestartCertSvc.' -Operation 'Alignment' -OutputPath $OutputPath
    }

    Write-Log -Level Info -Message "Apply result: $appliedCount success, $failedCount failed" -Operation 'Alignment' -OutputPath $OutputPath
}

function Export-AlignmentPlan {
    $planPath = Join-Path $OutputPath "alignment_plan_$(Get-Timestamp).json"
    $planJson = ConvertTo-SafeJson -InputObject $script:AlignmentPlan -Depth 10
    $planJson | Out-File -FilePath $planPath -Encoding UTF8
    Write-Log -Level Info -Message "Alignment plan exported: $planPath" -Operation 'Alignment' -OutputPath $OutputPath
    return $planPath
}

try {
    if ($Backup) {
        Write-Log -Level Info -Message "Create rollback point: $rollbackPointName" -Operation 'Alignment' -OutputPath $OutputPath
    }

    Invoke-AlignIisMimeTypes
    Invoke-AlignIisAcls
    Invoke-AlignCRLPublication
    Invoke-CopyCRLToIis

    $planPath = Export-AlignmentPlan
    Invoke-ApplyChanges

    $duration = (Get-Date) - $script:StartTime
    Write-Log -Level Info -Message "Alignment completed in $($duration.TotalSeconds) sec" -Operation 'Alignment' -OutputPath $OutputPath

    Write-Host "`n=== Alignment Results ===" -ForegroundColor Green
    Write-Host "Planned changes: $($script:AlignmentPlan.changes.Count)" -ForegroundColor Cyan
    Write-Host "Plan: $planPath" -ForegroundColor Cyan
    Write-Host "Rollback point: $rollbackPointName" -ForegroundColor Cyan

    if (-not $Apply) {
        Write-Host "`nWhatIf mode. Use -Apply to execute changes." -ForegroundColor Yellow
        exit 10
    }

    exit 0
}
catch {
    Write-Log -Level Error -Message "Critical alignment error: $_" -Exception $_ -Operation 'Alignment' -OutputPath $OutputPath
    exit 1
}
