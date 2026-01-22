# Runbook: Публикация Issuing CA CRL

## Описание

Процедура публикации CRL для Enterprise Issuing CA (CA1). CRL публикуется автоматически, но требует проверки и копирования в IIS директории.

## Предварительные требования

- Доступ к CA1 (Issuing CA с IIS)
- Права: Local Administrator
- CA Service должен быть запущен

## Частота выполнения

- **Issuing CA CRL Validity**: 7-14 дней
- **Автоматическая публикация**: Настроена в CA
- **Проверка**: Ежедневно или при каждом обновлении CRL
- **Копирование в IIS**: При каждом обновлении CRL

## Процедура

### Шаг 1: Проверка текущего CRL

```powershell
# Путь к CRL
$certEnrollPath = "C:\Windows\System32\CertSrv\CertEnroll"
$crlFiles = Get-ChildItem -Path $certEnrollPath -Filter "*.crl"

foreach ($crl in $crlFiles) {
    Write-Host "CRL: $($crl.Name)"
    certutil -dump $crl.FullName | Select-String "NextUpdate"
}
```

### Шаг 2: Проверка конфигурации CRL

```powershell
# Проверка настроек CRL
certutil -getreg CA\CRLPeriod
certutil -getreg CA\CRLPeriodUnits
certutil -getreg CA\CRLOverlapPeriod
certutil -getreg CA\CRLOverlapUnits
certutil -getreg CA\CRLFlags
certutil -getreg CA\CRLDeltaPeriod
certutil -getreg CA\CRLDeltaPeriodUnits

# Проверка URLs публикации
certutil -getreg CA\CRLPublicationURLs
```

### Шаг 3: Принудительная публикация CRL (если требуется)

```powershell
# Публикация базового CRL
certutil -crl

# Публикация Delta CRL (если настроено)
certutil -crl -delta
```

### Шаг 4: Копирование CRL в IIS директории

```powershell
# Пути для публикации
$certEnrollPath = "C:\Windows\System32\CertSrv\CertEnroll"
$pkiCdpPath = "C:\inetpub\wwwroot\PKI\CDP"
$legacyCertsPath = "C:\inetpub\wwwroot\Certs"

# Создание директорий (если не существуют)
New-Item -ItemType Directory -Path $pkiCdpPath -Force | Out-Null
New-Item -ItemType Directory -Path $legacyCertsPath -Force | Out-Null

# Копирование всех CRL
$crlFiles = Get-ChildItem -Path $certEnrollPath -Filter "*.crl"

foreach ($crl in $crlFiles) {
    # Canonical path
    $destCanonical = Join-Path $pkiCdpPath $crl.Name
    Copy-Item -Path $crl.FullName -Destination $destCanonical -Force
    Write-Host "✅ Скопирован в PKI/CDP: $($crl.Name)" -ForegroundColor Green
    
    # Legacy path (для совместимости)
    $destLegacy = Join-Path $legacyCertsPath $crl.Name
    Copy-Item -Path $crl.FullName -Destination $destLegacy -Force
    Write-Host "✅ Скопирован в Certs: $($crl.Name)" -ForegroundColor Green
}
```

### Шаг 5: Копирование сертификатов CA в AIA

```powershell
# Пути для AIA
$certEnrollPath = "C:\Windows\System32\CertSrv\CertEnroll"
$pkiAiaPath = "C:\inetpub\wwwroot\PKI\AIA"
$legacyCertsAiaPath = "C:\inetpub\wwwroot\CertsAIA"

# Создание директорий
New-Item -ItemType Directory -Path $pkiAiaPath -Force | Out-Null
New-Item -ItemType Directory -Path $legacyCertsAiaPath -Force | Out-Null

# Копирование сертификатов CA
$certFiles = Get-ChildItem -Path $certEnrollPath -Filter "*.crt"

foreach ($cert in $certFiles) {
    # Canonical path
    $destCanonical = Join-Path $pkiAiaPath $cert.Name
    Copy-Item -Path $cert.FullName -Destination $destCanonical -Force
    Write-Host "✅ Скопирован в PKI/AIA: $($cert.Name)" -ForegroundColor Green
    
    # Legacy path
    $destLegacy = Join-Path $legacyCertsAiaPath $cert.Name
    Copy-Item -Path $cert.FullName -Destination $destLegacy -Force
    Write-Host "✅ Скопирован в CertsAIA: $($cert.Name)" -ForegroundColor Green
}
```

### Шаг 6: Проверка доступности по HTTP

```powershell
# Получение имени CA
$caInfo = certutil -cainfo
$caName = ($caInfo | Select-String "CA Name:\s*(.+)").Matches.Groups[1].Value

# Формирование URLs
$baseUrl = "http://ca1-issuing.contoso.local"
$crlUrls = @(
    "$baseUrl/PKI/CDP/$caName.crl",
    "$baseUrl/Certs/$caName.crl"
)

$certUrls = @(
    "$baseUrl/PKI/AIA/$caName.crt",
    "$baseUrl/CertsAIA/$caName.crt"
)

# Проверка CRL
Write-Host "`n=== Проверка CRL ===" -ForegroundColor Cyan
foreach ($url in $crlUrls) {
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
        Write-Host "✅ Доступен: $url (Status: $($response.StatusCode), Size: $($response.Content.Length) bytes)" -ForegroundColor Green
    }
    catch {
        Write-Host "❌ Недоступен: $url - $_" -ForegroundColor Red
    }
}

# Проверка сертификатов
Write-Host "`n=== Проверка сертификатов ===" -ForegroundColor Cyan
foreach ($url in $certUrls) {
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
        Write-Host "✅ Доступен: $url (Status: $($response.StatusCode), Size: $($response.Content.Length) bytes)" -ForegroundColor Green
    }
    catch {
        Write-Host "❌ Недоступен: $url - $_" -ForegroundColor Red
    }
}
```

### Шаг 7: Проверка через certutil

```powershell
# Проверка цепочки доверия
Write-Host "`n=== Проверка цепочки доверия ===" -ForegroundColor Cyan
certutil -verify -urlfetch

# Проверка конкретного сертификата (пример)
# certutil -verify -urlfetch <certificate.cer>
```

### Шаг 8: Проверка MIME типов

```powershell
Import-Module WebAdministration

# Проверка MIME типов
$mimeTypes = @(
    @{ Extension = ".crl"; MimeType = "application/pkix-crl" }
    @{ Extension = ".crt"; MimeType = "application/x-x509-ca-cert" }
    @{ Extension = ".cer"; MimeType = "application/x-x509-ca-cert" }
)

$siteName = "Default Web Site"

foreach ($mime in $mimeTypes) {
    $exists = Get-WebConfigurationProperty `
        -Filter "system.webServer/staticContent" `
        -Name "." `
        -PSPath "IIS:\Sites\$siteName" | 
        Where-Object { $_.fileExtension -eq $mime.Extension -and $_.mimeType -eq $mime.MimeType }
    
    if ($exists) {
        Write-Host "✅ MIME тип настроен: $($mime.Extension) -> $($mime.MimeType)" -ForegroundColor Green
    }
    else {
        Write-Host "❌ MIME тип отсутствует: $($mime.Extension) -> $($mime.MimeType)" -ForegroundColor Red
    }
}
```

## Автоматизация

### Использование скрипта выравнивания

```powershell
.\src\pki-align\Invoke-PkiAlignment.ps1 `
    -ConfigPath .\config\env.json `
    -OutputPath .\output `
    -BaselinePath .\output\baseline_*.json `
    -Apply `
    -Backup
```

### Запланированная задача (Task Scheduler)

Создайте задачу для автоматического копирования CRL:

```powershell
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-File C:\Scripts\Copy-CRLToIis.ps1"

$trigger = New-ScheduledTaskTrigger -Daily -At "02:00"

Register-ScheduledTask -TaskName "PKI-CopyCRLToIis" `
    -Action $action `
    -Trigger $trigger `
    -Description "Копирование CRL в IIS директории" `
    -User "SYSTEM" `
    -RunLevel Highest
```

## Проверка успешности

### Критерии успеха

1. ✅ CRL файл обновлён в CertEnroll
2. ✅ CRL скопирован в PKI/CDP (canonical)
3. ✅ CRL скопирован в Certs (legacy)
4. ✅ CRL доступен по HTTP (оба пути)
5. ✅ Сертификаты CA скопированы в AIA
6. ✅ certutil -verify -urlfetch не показывает CRYPT_E_REVOCATION_OFFLINE
7. ✅ NextUpdate CRL в будущем (минимум 7 дней)

### Проверочный список

- [ ] CRL обновлён в CertEnroll
- [ ] CRL скопирован в PKI/CDP
- [ ] CRL скопирован в Certs (legacy)
- [ ] Сертификаты CA скопированы в PKI/AIA
- [ ] Сертификаты CA скопированы в CertsAIA (legacy)
- [ ] CRL доступен по HTTP (canonical path)
- [ ] CRL доступен по HTTP (legacy path)
- [ ] MIME типы настроены
- [ ] ACL настроен
- [ ] certutil -verify проходит без ошибок

## Мониторинг

### Ежедневная проверка

```powershell
# Скрипт для ежедневной проверки
$certEnrollPath = "C:\Windows\System32\CertSrv\CertEnroll"
$crlFiles = Get-ChildItem -Path $certEnrollPath -Filter "*.crl"

foreach ($crl in $crlFiles) {
    $crlInfo = certutil -dump $crl.FullName | Select-String "NextUpdate"
    $daysUntilExpiry = # Парсинг и расчёт дней
    
    if ($daysUntilExpiry -lt 3) {
        Write-Warning "CRL истекает через $daysUntilExpiry дней: $($crl.Name)"
    }
}
```

## Troubleshooting

### Проблема: CRL не обновляется автоматически

**Причины**:
- CA Service не запущен
- Проблемы с конфигурацией CRL
- Проблемы с публикацией

**Решение**:
1. Проверить статус службы: `Get-Service CertSvc`
2. Проверить Event Logs: `Get-EventLog -LogName Application -Source "Microsoft-Windows-CertificateServices-CertificationAuthority"`
3. Принудительно опубликовать CRL: `certutil -crl`

### Проблема: CRL недоступен по HTTP

См. раздел Troubleshooting в `RootCRL_Runbook.md`

### Проблема: Delta CRL не работает

**Причины**:
- Delta CRL не настроен
- CRLDeltaPeriod не установлен

**Решение**:
```powershell
# Проверка настроек
certutil -getreg CA\CRLDeltaPeriod
certutil -getreg CA\CRLDeltaPeriodUnits

# Настройка Delta CRL (пример: 1 день)
certutil -setreg CA\CRLDeltaPeriod 1
certutil -setreg CA\CRLDeltaPeriodUnits Days
```

## Частота проверки

- **Ежедневно**: Проверка доступности CRL по HTTP
- **Еженедельно**: Проверка срока действия CRL
- **При каждом обновлении CRL**: Копирование в IIS директории

## Связанные документы

- `docs/01_Phase1_Audit_AS-IS.md` — процедура аудита
- `docs/Runbooks/RootCRL_Runbook.md` — публикация Root CA CRL
- `rules/PKI_RULES.md` — правила безопасности
