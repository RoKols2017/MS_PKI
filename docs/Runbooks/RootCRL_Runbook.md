# Runbook: Публикация Root CA CRL

## Описание

Процедура публикации CRL для Offline Root CA (CA0) через IIS на Issuing CA (CA1).

## Предварительные требования

- Доступ к CA0 (Offline Root CA)
- Доступ к CA1 (Issuing CA с IIS)
- Права: Local Administrator на обоих серверах
- Root CA сертификат и CRL файлы

## Частота выполнения

- **Root CA CRL Validity**: 6-12 месяцев (целевое 12 месяцев)
- **Рекомендуемая частота публикации**: Каждые 6-12 месяцев
- **Проверка**: За 1-2 недели до истечения текущего CRL

## Процедура

### Шаг 1: Подключение к CA0

1. Включите CA0 сервер (если он offline)
2. Войдите с правами Local Administrator
3. Откройте PowerShell с правами администратора

### Шаг 2: Генерация нового CRL

```powershell
# Проверка текущего CRL
certutil -getreg CA\CRLPeriod
certutil -getreg CA\CRLPeriodUnits

# Генерация нового CRL
certutil -crl
```

### Шаг 3: Проверка сгенерированного CRL

```powershell
# Путь к CRL
$crlPath = "C:\Windows\System32\CertSrv\CertEnroll\*.crl"

# Проверка информации о CRL
certutil -dump $crlPath

# Проверка NextUpdate
$crlInfo = certutil -dump $crlPath | Select-String "NextUpdate"
Write-Host "NextUpdate: $crlInfo"
```

### Шаг 4: Копирование CRL на CA1

```powershell
# На CA0: Копирование CRL на CA1
$ca1Server = "ca1-issuing.contoso.local"
$ca1Path = "\\$ca1Server\C$\Windows\System32\CertSrv\CertEnroll"
$crlFiles = Get-ChildItem -Path "C:\Windows\System32\CertSrv\CertEnroll\*.crl"

foreach ($crl in $crlFiles) {
    Copy-Item -Path $crl.FullName -Destination "$ca1Path\$($crl.Name)" -Force
    Write-Host "Скопирован: $($crl.Name)"
}
```

### Шаг 5: Копирование CRL в IIS директории на CA1

**На CA1 сервере**:

```powershell
# Пути для публикации
$certEnrollPath = "C:\Windows\System32\CertSrv\CertEnroll"
$pkiCdpPath = "C:\inetpub\wwwroot\PKI\CDP"
$legacyCertsPath = "C:\inetpub\wwwroot\Certs"

# Создание директорий (если не существуют)
New-Item -ItemType Directory -Path $pkiCdpPath -Force | Out-Null
New-Item -ItemType Directory -Path $legacyCertsPath -Force | Out-Null

# Копирование CRL
$crlFiles = Get-ChildItem -Path $certEnrollPath -Filter "*.crl"

foreach ($crl in $crlFiles) {
    # Canonical path
    Copy-Item -Path $crl.FullName -Destination "$pkiCdpPath\$($crl.Name)" -Force
    Write-Host "Скопирован в PKI/CDP: $($crl.Name)"
    
    # Legacy path (для совместимости)
    Copy-Item -Path $crl.FullName -Destination "$legacyCertsPath\$($crl.Name)" -Force
    Write-Host "Скопирован в Certs: $($crl.Name)"
}
```

### Шаг 6: Проверка доступности CRL по HTTP

```powershell
# На CA1 или клиенте
$crlUrls = @(
    "http://ca1-issuing.contoso.local/PKI/CDP/CONTOSO-Root-CA.crl",
    "http://ca1-issuing.contoso.local/Certs/CONTOSO-Root-CA.crl"
)

foreach ($url in $crlUrls) {
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
        Write-Host "✅ Доступен: $url (Status: $($response.StatusCode))" -ForegroundColor Green
    }
    catch {
        Write-Host "❌ Недоступен: $url - $_" -ForegroundColor Red
    }
}
```

### Шаг 7: Проверка через certutil

```powershell
# Проверка цепочки доверия
certutil -verify -urlfetch

# Проверка конкретного сертификата
certutil -verify -urlfetch <certificate.cer>
```

### Шаг 8: Отключение CA0 (если требуется)

После успешной публикации CRL, CA0 может быть отключён:

```powershell
# На CA0
shutdown /s /t 0
```

## Автоматизация

Используйте скрипт выравнивания для автоматического копирования:

```powershell
.\src\pki-align\Invoke-PkiAlignment.ps1 `
    -ConfigPath .\config\env.json `
    -OutputPath .\output `
    -BaselinePath .\output\baseline_*.json `
    -Apply `
    -Backup
```

## Проверка успешности

### Критерии успеха

1. ✅ CRL файл создан на CA0
2. ✅ CRL скопирован в CertEnroll на CA1
3. ✅ CRL доступен по HTTP (оба пути: canonical и legacy)
4. ✅ certutil -verify -urlfetch не показывает CRYPT_E_REVOCATION_OFFLINE
5. ✅ NextUpdate CRL в будущем (минимум 6 месяцев)

### Проверочный список

- [ ] CRL сгенерирован на CA0
- [ ] CRL скопирован на CA1
- [ ] CRL доступен по HTTP (canonical path)
- [ ] CRL доступен по HTTP (legacy path)
- [ ] MIME тип настроен (.crl → application/pkix-crl)
- [ ] ACL настроен (IIS_IUSRS имеет Read доступ)
- [ ] certutil -verify проходит без ошибок
- [ ] Документация обновлена

## Troubleshooting

### Проблема: CRL недоступен по HTTP

**Причины**:
- IIS не запущен
- Virtual directory не настроен
- MIME тип не настроен
- ACL не настроен
- Файл не скопирован

**Решение**:
1. Проверить статус IIS: `Get-Service W3SVC`
2. Проверить virtual directory: `Get-WebVirtualDirectory -Site "Default Web Site"`
3. Проверить MIME тип: `Get-WebConfigurationProperty -Filter "system.webServer/staticContent"`
4. Проверить ACL: `icacls C:\inetpub\wwwroot\PKI\CDP`
5. Проверить наличие файла: `Test-Path C:\inetpub\wwwroot\PKI\CDP\*.crl`

### Проблема: certutil показывает CRYPT_E_REVOCATION_OFFLINE

**Причины**:
- CRL недоступен по HTTP
- CRL истёк
- Неправильный URL в сертификате

**Решение**:
1. Проверить доступность CRL по HTTP (см. выше)
2. Проверить срок действия CRL: `certutil -dump <crl.crl> | Select-String "NextUpdate"`
3. Проверить CRLPublicationURLs в реестре CA

## Частота проверки

- **Еженедельно**: Проверка доступности CRL по HTTP
- **Ежемесячно**: Проверка срока действия CRL
- **За 1-2 недели до истечения**: Генерация нового CRL

## Связанные документы

- `docs/01_Phase1_Audit_AS-IS.md` — процедура аудита
- `docs/Runbooks/IssuingCRL_Runbook.md` — публикация Issuing CA CRL
- `rules/PKI_RULES.md` — правила безопасности
