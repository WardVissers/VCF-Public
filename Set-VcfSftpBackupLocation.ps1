<#
.SYNOPSIS
    Configureert een SFTP backup locatie voor VCF Management Services (Fleet LCM),
    SDDC Manager en vCenter via de VCF REST API's.

.DESCRIPTION
    PowerShell-versie van de curl/jq scripts uit:
    https://my-cloudy-world.com/2026/08/13/vmware-cloud-foundation-apis-configure-sftp-backup-location/

    Vereist PowerShell 7+ (gebruikt -SkipCertificateCheck voor zelfondertekende certificaten).

.EXAMPLE
    # Alleen vCenter
    .\Set-VcfSftpBackupLocation.ps1 -Component vCenter `
        -vCenterFqdn 'sfo-m01-vc01.sfo.rainpole.io' -vCenterUser 'administrator@vsphere.local' `
        -vCenterPass 'VMw@re1!VMw@re1!' `
        -SftpServerIp '10.167.173.55' -SftpDirectory '/media/backups/' `
        -SftpUser 'svc-vcf-bck' -SftpPass 'VMw@re1!' -EncryptionPassphrase 'VMw@re1!VMw@re1!'

.EXAMPLE
    # Waarden staan in het blok "Configuratie" in het script
    .\Set-VcfSftpBackupLocation.ps1 -Component FleetLifecycle

.EXAMPLE
    # Fleet Lifecycle SFTP-locatie + backup-schema (full op zondag 02:00 UTC, incrementeel uit)
    .\Set-VcfSftpBackupLocation.ps1 -Component FleetLifecycle -ConfigureFleetBackupSchedule

.EXAMPLE
    # Alleen het schema, en alleen als er al een SFTP backup-locatie is geconfigureerd
    # (de SFTP-parameters worden opnieuw meegestuurd, gebruik dus dezelfde waarden als bij de SFTP-configuratie)
    .\Set-VcfSftpBackupLocation.ps1 -Component FleetBackupSchedule

.EXAMPLE
    # SDDC Manager backup-schema (aparte taak, los van de SFTP-locatie), met het ingebouwde standaardschema
    # (dinsdag en donderdag 23:00, retentie 3). Er is geen JSON-bestand nodig.
    .\Set-VcfSftpBackupLocation.ps1 -Component SddcManagerBackupSchedule

.EXAMPLE
    # Zelfde taak met een eigen schema via parameters
    .\Set-VcfSftpBackupLocation.ps1 -Component SddcManagerBackupSchedule `
        -SddcBackupDays MONDAY,WEDNESDAY,FRIDAY -SddcBackupHour 2 -SddcBackupMinute 30 -SddcBackupRetention 5

.EXAMPLE
    # Eigen JSON-bestand gebruiken (wordt met het standaardschema aangemaakt als het nog niet bestaat)
    .\Set-VcfSftpBackupLocation.ps1 -Component SddcManagerBackupSchedule -SddcBackupScheduleFile .\sddc-backup-schedule.json

.EXAMPLE
    # Eigen dagen en tijd (UTC), met incrementele backup
    .\Set-VcfSftpBackupLocation.ps1 -Component FleetLifecycle -ConfigureFleetBackupSchedule `
        -FullBackupDays SUN -FullBackupStartTime '01:00Z' -EnableIncrementalBackup `
        -IncrementalBackupDays MON,TUE,WED,THU,FRI,SAT

.EXAMPLE
    # Alles in één keer (@params is optioneel; lege waarden worden aangevuld uit het script)
    .\Set-VcfSftpBackupLocation.ps1 -Component All @params
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('FleetLifecycle', 'FleetBackupSchedule', 'SddcManager', 'SddcManagerBackupSchedule', 'vCenter', 'All')]
    [string]$Component = 'All',

    # --- SDDC Manager backup-schema (-Component SddcManagerBackupSchedule) ---
    # Standaardschema (wekelijks); wordt automatisch opgebouwd, een JSON-bestand is niet nodig.
    [ValidateSet('MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY', 'SUNDAY')]
    [string[]]$SddcBackupDays = @('TUESDAY', 'THURSDAY'),
    [ValidateRange(0, 23)]
    [int]$SddcBackupHour = 23,
    [ValidateRange(0, 59)]
    [int]$SddcBackupMinute = 0,
    [ValidateRange(1, 365)]
    [int]$SddcBackupRetention = 3,   # geldt voor aantal backups en voor dagen uurlijks/dagelijks

    # Optioneel: eigen JSON-bestand met het backup-schema. Bestaat het bestand niet, dan wordt het
    # aangemaakt met het standaardschema hierboven en meteen gebruikt. Leeg = standaardschema.
    [string]$SddcBackupScheduleFile,

    # Optie: stuur bij de Fleet Lifecycle SFTP-configuratie ook een backup-schema mee
    # (zelfde PATCH en zelfde backupConfigSpec als de SFTP-locatie).
    [switch]$ConfigureFleetBackupSchedule,

    # Bij -Component FleetBackupSchedule en SddcManagerBackupSchedule (alleen het schema): sla de
    # controle op een bestaande backup-configuratie over. Handig als de API de configuratie niet
    # in de respons laat zien.
    [switch]$SkipConfigCheck,

    # De standaardwaarden voor onderstaande tekstparameters staan in het blok
    # "Configuratie" hieronder. Een parameter die je niet (of leeg) meegeeft, ook via
    # @params, wordt daaruit aangevuld.

    # --- VCF Fleet Lifecycle Service ---
    [string]$FleetLifecycleFqdn,
    [string]$FleetLifecycleUser,
    [string]$FleetLifecyclePass,

    # --- Backup-schema (alleen gebruikt met -ConfigureFleetBackupSchedule) ---
    # Dagen en starttijd (UTC) van de volledige backup, zoals in de backupConfigSpec van Fleet LCM.
    [ValidateSet('MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN')]
    [string[]]$FullBackupDays = @('SUN'),
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\dZ$')]
    [string]$FullBackupStartTime = '02:00Z',

    # Incrementele backup staat standaard uit. Met -EnableIncrementalBackup krijgt hij onderstaand schema.
    [switch]$EnableIncrementalBackup,
    [ValidateSet('MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN')]
    [string[]]$IncrementalBackupDays = @('MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'),
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\dZ$')]
    [string]$IncrementalBackupStartTime = '02:00Z',

    # --- SDDC Manager ---
    [string]$SddcManagerFqdn,
    [string]$SddcManagerUser,
    [string]$SddcManagerPass,

    # --- vCenter ---
    [string]$vCenterFqdn,
    [string]$vCenterUser,
    [string]$vCenterPass,

    # --- SFTP server ---
    [string]$SftpServerIp,
    [int]$SftpPort = 22,
    [string]$SftpDirectory,
    [string]$SftpUser,
    [string]$SftpPass,
    [string]$EncryptionPassphrase,

    # Submap onder SftpDirectory voor SDDC Manager / NSX Manager (wordt aangemaakt via Posh-SSH)
    [string]$SddcBackupFolder = 'SDDC_Backups',

    # --- Polling ---
    [int]$FleetPollSeconds = 60,
    [int]$SddcPollSeconds = 10,

    # Pad voor de JSON payload bestanden (handig voor controle achteraf)
    [string]$OutputDirectory = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

# -SddcBackupScheduleFile zonder -Component: alleen het SDDC Manager backup-schema toepassen
if ($PSBoundParameters.ContainsKey('SddcBackupScheduleFile') -and -not $PSBoundParameters.ContainsKey('Component')) {
    $Component = 'SddcManagerBackupSchedule'
}

#region Configuratie ----------------------------------------------------------
# Pas hier je omgeving aan, dan hoef je geen @params of losse parameters mee te geven.
# Parameters die je wel meegeeft (niet leeg) gaan altijd voor.

$Config = [ordered]@{
     # VCF Fleet Lifecycle Service
    FleetLifecycleFqdn   = 'vcf-flt-01.wardhomelab.nl'
    FleetLifecycleUser   = 'admin@vsp.local'
    FleetLifecyclePass = '<YourPasswordHere>'
    
    # SDDC Manager
    SddcManagerFqdn = 'vcf-sddcm-01.wardhomelab.nl'
    SddcManagerUser = 'administrator@vsphere.local'
    SddcManagerPass = '<YourPasswordHere>'
    
    # vCenter
    vCenterFqdn = 'vcf-m01-vc01.wardhomelab.nl'
    vCenterUser = 'administrator@vsphere.local'
    vCenterPass = '<YourPasswordHere>'

    # SFTP server
    SftpServerIp = '192.168.150.3'
    SftpDirectory = '/VCF_Backups/'
    SftpUser = 'vcfuser'
    SftpPass = '<YourPasswordHere>'
    EncryptionPassphrase = '<YourEncyptionPasswordHere>'
}

# Niet meegegeven of leeg (bijvoorbeeld een lege waarde in @params): vul aan uit $Config
foreach ($key in $Config.Keys) {
    $current = [string](Get-Variable -Name $key -ValueOnly -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($current)) {
        Set-Variable -Name $key -Value $Config[$key]
    }
}

#endregion

#region Helpers ---------------------------------------------------------------

function Invoke-VcfApi {
    <# Dunne wrapper om Invoke-RestMethod die -k (cert check overslaan) afhandelt. #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'PATCH')][string]$Method,
        [hashtable]$Headers = @{},
        $Body,
        [string]$ContentType = 'application/json'
    )

    $params = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = $Headers
        ContentType = $ContentType
    }
    if ($PSBoundParameters.ContainsKey('Body')) { $params.Body = $Body }
    # Zelfondertekende certificaten accepteren (equivalent van curl -k)
    $params.SkipCertificateCheck = $true

    Invoke-RestMethod @params
}

function Save-JsonPayload {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$FileName)
    $path = Join-Path $OutputDirectory $FileName
    $json = $Object | ConvertTo-Json -Depth 10
    Set-Content -Path $path -Value $json -Encoding UTF8
    Write-Host "JSON payload opgeslagen: $path" -ForegroundColor DarkGray
    return $json
}

function New-SftpDirectoryIfMissing {
    <# Maakt een directory (en ontbrekende bovenliggende mappen) aan op de SFTP-server via Posh-SSH. #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
        throw "De module Posh-SSH ontbreekt. Installeer hem met: Install-Module Posh-SSH -Scope CurrentUser"
    }
    Import-Module Posh-SSH -ErrorAction Stop

    $credential = [pscredential]::new($SftpUser, (ConvertTo-SecureString $SftpPass -AsPlainText -Force))
    # -AcceptKey accepteert de host key van de SFTP-server automatisch (alleen voor het aanmaken van de map)
    $session = New-SFTPSession -ComputerName $SftpServerIp -Port $SftpPort -Credential $credential -AcceptKey -ErrorAction Stop
    try {
        $current = ''
        foreach ($segment in ($Path.Trim('/') -split '/')) {
            $current = "$current/$segment"
            if (Test-SFTPPath -SessionId $session.SessionId -Path $current) {
                Write-Host "Map bestaat al op de SFTP-server: $current" -ForegroundColor DarkGray
            }
            else {
                New-SFTPItem -SessionId $session.SessionId -Path $current -ItemType Directory | Out-Null
                Write-Host "Map aangemaakt op de SFTP-server: $current" -ForegroundColor Green
            }
        }
    }
    finally {
        Remove-SFTPSession -SessionId $session.SessionId | Out-Null
    }
}

function Get-ComponentBackupDirectory {
    <# Geeft de basisdirectory + een submap met de hostnaam zonder domein (alles voor de eerste punt). #>
    param([Parameter(Mandatory)][string]$Fqdn)
    $shortName = ($Fqdn -split '\.')[0]
    $baseDir = $SftpDirectory.TrimEnd('/')
    return "$baseDir/$shortName/"
}

#endregion

#region VCF Management Services (Fleet LCM) -----------------------------------

function Test-FleetBackupConfigured {
    <# Controleert of de primaire SDDC LCM al een SFTP backup-locatie heeft. Het zoekt in de
       lijst-entry en in de detail-respons naar een 'sftp' object met een ingevulde 'host'.
       Omdat de vorm van de respons niet gedocumenteerd is, toont het bij 'niet gevonden' welke
       velden de API teruggaf, zodat de controle zo nodig kan worden aangepast. #>
    param(
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)]$ListEntry,
        [Parameter(Mandatory)][string]$Id
    )

    $sources = @($ListEntry)
    try {
        $sources += Invoke-VcfApi -Method GET -Uri "$Base/fleet-lcm/v1/sddc-lcms/$Id" -Headers $Headers
    }
    catch {
        Write-Host "Detail-aanroep van de SDDC LCM instance mislukt ($($_.Exception.Message)); alleen de lijst wordt gecontroleerd." -ForegroundColor DarkGray
    }

    foreach ($source in $sources) {
        $text = $source | ConvertTo-Json -Depth 20 -Compress
        if ($text -match '"sftp"\s*:\s*\{[^{}]*"host"\s*:\s*"[^"]+"') { return $true }
    }

    $fields = ($sources | ForEach-Object { $_.PSObject.Properties.Name } | Sort-Object -Unique) -join ', '
    Write-Host "Velden die de API teruggaf: $fields" -ForegroundColor DarkGray
    return $false
}

function Set-FleetLifecycleSftpBackup {
    # -ScheduleOnly: alleen het backup-schema toepassen, en alleen als er al een SFTP backup-locatie is
    param([switch]$ScheduleOnly)

    if ($ScheduleOnly) {
        Write-Host "`n=== Backup-schema: VCF Management Services (Fleet Lifecycle) ===" -ForegroundColor Cyan
    }
    else {
        Write-Host "`n=== SFTP backup: VCF Management Services (Fleet Lifecycle) ===" -ForegroundColor Cyan
    }
    $base = "https://$FleetLifecycleFqdn"
    $backupDirectory = Get-ComponentBackupDirectory -Fqdn $FleetLifecycleFqdn
    Write-Host "Backup directory: $backupDirectory"

    # 1. Token ophalen (form-urlencoded)
    $tokenResponse = Invoke-VcfApi -Method POST -Uri "$base/api/v1/identity/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{
            grant_type = 'password'
            username   = $FleetLifecycleUser
            password   = $FleetLifecyclePass
        }
    $token = $tokenResponse.access_token
    if (-not $token) { throw 'Geen access_token ontvangen van de Fleet Lifecycle Service.' }
    Write-Host 'Token succesvol opgehaald.'

    $headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }

    # 2. Primaire SDDC LCM instance ophalen
    $lcms = Invoke-VcfApi -Method GET -Uri "$base/fleet-lcm/v1/sddc-lcms" -Headers $headers
    $primaryEntry = $lcms.sddcLcms | Where-Object { $_.isPrimary -eq $true }
    $primarySddcLcms = $primaryEntry.id
    if (-not $primarySddcLcms) { throw 'Geen primaire SDDC LCM instance gevonden.' }
    Write-Host "Primaire SDDC LCM: $primarySddcLcms"

    # Alleen schema: eerst controleren of er al een backup-locatie is geconfigureerd
    if ($ScheduleOnly) {
        if ($SkipConfigCheck) {
            Write-Host 'Controle op bestaande backup-configuratie overgeslagen (-SkipConfigCheck).' -ForegroundColor Yellow
        }
        elseif (Test-FleetBackupConfigured -Base $base -Headers $headers -ListEntry $primaryEntry -Id $primarySddcLcms) {
            Write-Host 'Bestaande SFTP backup-configuratie gevonden: schema wordt toegepast.' -ForegroundColor Green
        }
        else {
            Write-Warning ('Geen bestaande SFTP backup-configuratie gevonden voor de primaire SDDC LCM; het schema is NIET toegepast. ' +
                'Configureer eerst de SFTP-locatie (-Component FleetLifecycle) of sla de controle over met -SkipConfigCheck.')
            return
        }
    }

    # 3. SFTP fingerprint ophalen
    $fpBody = ConvertTo-Json -InputObject @(@{ address = $SftpServerIp; port = $SftpPort }) -Compress
    $fpResponse = Invoke-VcfApi -Method POST `
        -Uri "$base/fleet-lcm/v1/address-attributes?type=SSH_THUMBPRINT" `
        -Headers $headers -Body $fpBody
    $sftpFingerprint = @($fpResponse)[0].value
    if (-not $sftpFingerprint) { throw 'Kon de SFTP fingerprint niet ophalen.' }
    Write-Host "SFTP fingerprint: $sftpFingerprint"

    # 4. Payload opbouwen
    $payload = [ordered]@{
        backupConfigSpec = [ordered]@{
            storage = [ordered]@{
                sftp = [ordered]@{
                    host       = $SftpServerIp
                    port       = "$SftpPort"
                    username   = $SftpUser
                    password   = $SftpPass
                    directory  = $backupDirectory
                    thumbprint = $sftpFingerprint
                }
            }
            encryptionPassphrase = $EncryptionPassphrase
        }
    }

    # Optioneel: backup-schema in dezelfde backupConfigSpec meesturen. Het schema moet samen
    # met de SFTP-locatie in dezelfde PATCH worden verstuurd; apart versturen zonder storage
    # kan de bestaande configuratie overschrijven.
    if ($ConfigureFleetBackupSchedule -or $ScheduleOnly) {
        $payload.backupConfigSpec['fullSchedule'] = [ordered]@{
            enabled  = $true
            schedule = [ordered]@{
                days      = @($FullBackupDays)
                startTime = $FullBackupStartTime
            }
        }
        if ($EnableIncrementalBackup) {
            # Let op: dezelfde opbouw als fullSchedule; voor incrementeel is dit niet geverifieerd
            $payload.backupConfigSpec['incrementalSchedule'] = [ordered]@{
                enabled  = $true
                schedule = [ordered]@{
                    days      = @($IncrementalBackupDays)
                    startTime = $IncrementalBackupStartTime
                }
            }
        }
        else {
            $payload.backupConfigSpec['incrementalSchedule'] = [ordered]@{ enabled = $false }
        }
        $payload.backupConfigSpec['retention'] = [ordered]@{}
        Write-Host "Backup-schema: full $($FullBackupDays -join ',') om $FullBackupStartTime (UTC)" -ForegroundColor DarkGray
    }
    $json = Save-JsonPayload -Object $payload -FileName 'sftp-backup-location.json'

    # 5. Backup locatie (en eventueel schema) configureren
    $task = Invoke-VcfApi -Method PATCH `
        -Uri "$base/fleet-lcm/v1/sddc-lcms/$($primarySddcLcms)?action=apply" `
        -Headers $headers -Body $json
    $taskId = $task.id
    Write-Host "Taak gestart: $taskId"

    # 6. Wachten tot de taak niet meer RUNNING is
    do {
        $status = (Invoke-VcfApi -Method GET -Uri "$base/fleet-lcm/v1/tasks/$taskId" -Headers $headers).status
        if ($status -eq 'RUNNING') {
            Write-Host "Nog in 'RUNNING' status... wacht $FleetPollSeconds seconden."
            Start-Sleep -Seconds $FleetPollSeconds
        }
    } while ($status -eq 'RUNNING')

    Write-Host "Fleet Lifecycle taak afgerond met status: $status" -ForegroundColor Green
    Invoke-VcfApi -Method GET -Uri "$base/fleet-lcm/v1/tasks/$taskId" -Headers $headers
}

#endregion

#region SDDC Manager (en NSX Manager) -----------------------------------------

function Set-SddcManagerSftpBackup {
    Write-Host "`n=== SFTP backup: SDDC Manager / NSX Manager ===" -ForegroundColor Cyan
    $base = "https://$SddcManagerFqdn"
    # SDDC Manager / NSX Manager gebruiken de submap SDDC_Backups onder de SftpDirectory
    $backupDirectory = "$($SftpDirectory.TrimEnd('/'))/$SddcBackupFolder/"
    Write-Host "Backup directory: $backupDirectory"

    # Map op de SFTP-server aanmaken (indien nodig) voordat SDDC Manager hem gebruikt
    New-SftpDirectoryIfMissing -Path $backupDirectory

    # 1. Token ophalen
    $tokenBody = @{ username = $SddcManagerUser; password = $SddcManagerPass } | ConvertTo-Json -Compress
    $token = (Invoke-VcfApi -Method POST -Uri "$base/v1/tokens" -Body $tokenBody).accessToken
    if (-not $token) { throw 'Geen accessToken ontvangen van SDDC Manager.' }
    Write-Host 'Token succesvol opgehaald.'

    $headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }

    # 2. SFTP fingerprint ophalen
    $fpUri = "$base/v1/system/backup-configuration/backup-locations?serverIp=$SftpServerIp&port=$SftpPort"
    $sftpFingerprint = (Invoke-VcfApi -Method GET -Uri $fpUri -Headers $headers).sshFingerprint
    if (-not $sftpFingerprint) { throw 'Kon de SFTP fingerprint niet ophalen.' }
    Write-Host "SFTP fingerprint: $sftpFingerprint"

    # 3. Payload opbouwen
    $payload = [ordered]@{
        backupLocations = @(
            [ordered]@{
                directoryPath  = $backupDirectory
                password       = $SftpPass
                port           = $SftpPort
                protocol       = 'SFTP'
                server         = $SftpServerIp
                sshFingerprint = $sftpFingerprint
                username       = $SftpUser
            }
        )
        encryption = [ordered]@{ passphrase = $EncryptionPassphrase }
    }
    $json = Save-JsonPayload -Object $payload -FileName 'sftp-backup-location-sddcm.json'

    # 4. Backup locatie configureren
    $task = Invoke-VcfApi -Method PUT -Uri "$base/v1/system/backup-configuration" -Headers $headers -Body $json
    $taskId = $task.id
    Write-Host "Taak gestart: $taskId"

    # 5. Wachten tot de taak niet meer 'In Progress' is
    do {
        $status = (Invoke-VcfApi -Method GET -Uri "$base/v1/tasks/$taskId" -Headers $headers).status
        if ($status -eq 'In Progress') {
            Write-Host "Nog in 'In Progress' status... wacht $SddcPollSeconds seconden."
            Start-Sleep -Seconds $SddcPollSeconds
        }
    } while ($status -eq 'In Progress')

    Write-Host "SDDC Manager taak afgerond met status: $status" -ForegroundColor Green
    Invoke-VcfApi -Method GET -Uri "$base/v1/tasks/$taskId" -Headers $headers
}

function New-SddcBackupSchedulePayload {
    <# Bouwt het standaard backup-schema voor SDDC Manager op uit de parameters
       (-SddcBackupDays, -SddcBackupHour, -SddcBackupMinute, -SddcBackupRetention). #>
    return [ordered]@{
        backupSchedules = @(
            [ordered]@{
                resourceType            = 'SDDC_MANAGER'
                frequency               = 'WEEKLY'
                daysOfWeek              = @($SddcBackupDays)
                hourOfDay               = $SddcBackupHour
                minuteOfHour            = $SddcBackupMinute
                takeScheduledBackups    = $true
                takeBackupOnStateChange = $false
                retentionPolicy         = [ordered]@{
                    numberOfMostRecentBackups   = $SddcBackupRetention
                    numberOfDaysOfHourlyBackups = $SddcBackupRetention
                    numberOfDaysOfDailyBackups  = $SddcBackupRetention
                }
            }
        )
    }
}

function Set-SddcManagerBackupSchedule {
    <# Past het backup-schema van SDDC Manager toe (aparte taak, los van de SFTP-locatie).
       Zonder -SddcBackupScheduleFile bouwt het script zelf een standaard schema op uit de parameters.
       Gebruikt PATCH /v1/system/backup-configuration; de SFTP-locatie moet al zijn ingesteld. #>
    Write-Host "`n=== Backup-schema: SDDC Manager ===" -ForegroundColor Cyan

    # 1. Schema bepalen: eigen JSON-bestand, of het ingebouwde standaardschema
    if ([string]::IsNullOrWhiteSpace($SddcBackupScheduleFile)) {
        $path = Join-Path $OutputDirectory 'sddc-backup-schedule.json'
        $body = Save-JsonPayload -Object (New-SddcBackupSchedulePayload) -FileName 'sddc-backup-schedule.json'
        Write-Host 'Standaard backup-schema gebruikt (geen JSON-bestand opgegeven).'
    }
    else {
        $path = $SddcBackupScheduleFile
        if (-not (Test-Path -LiteralPath $path)) {
            # Bestand bestaat nog niet: aanmaken met het standaardschema (en meteen gebruiken)
            New-SddcBackupSchedulePayload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
            Write-Host "Bestand '$path' bestond niet en is aangemaakt met het standaard backup-schema." -ForegroundColor Yellow
        }
        $body = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    }
    try { $spec = $body | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Het bestand '$path' bevat geen geldige JSON: $($_.Exception.Message)" }
    if (-not $spec.backupSchedules -or @($spec.backupSchedules).Count -eq 0) {
        throw "Het bestand '$path' bevat geen 'backupSchedules'. Verwacht: { `"backupSchedules`": [ { ... } ] }"
    }
    foreach ($schedule in @($spec.backupSchedules)) {
        Write-Host ("Schema: {0}, {1}, dagen {2}, {3:D2}:{4:D2}" -f $schedule.resourceType, $schedule.frequency,
            (@($schedule.daysOfWeek) -join ','), $schedule.hourOfDay, $schedule.minuteOfHour)
    }

    if ([string]::IsNullOrWhiteSpace($SddcManagerFqdn)) { throw 'SddcManagerFqdn is leeg.' }
    $base = "https://$SddcManagerFqdn"

    # 2. Token ophalen
    $tokenBody = @{ username = $SddcManagerUser; password = $SddcManagerPass } | ConvertTo-Json -Compress
    $token = (Invoke-VcfApi -Method POST -Uri "$base/v1/tokens" -Body $tokenBody).accessToken
    if (-not $token) { throw 'Geen accessToken ontvangen van SDDC Manager.' }
    Write-Host 'Token succesvol opgehaald.'
    $headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }

    # 3. Controleren of er al een backup-locatie is ingesteld (anders heeft het schema niets om naartoe te schrijven)
    if ($SkipConfigCheck) {
        Write-Host 'Controle op bestaande backup-configuratie overgeslagen (-SkipConfigCheck).' -ForegroundColor Yellow
    }
    else {
        $current = Invoke-VcfApi -Method GET -Uri "$base/v1/system/backup-configuration" -Headers $headers
        if (@($current.backupLocations).Count -gt 0) {
            Write-Host 'Bestaande backup-locatie gevonden: schema wordt toegepast.' -ForegroundColor Green
        }
        else {
            $fields = ($current.PSObject.Properties.Name | Sort-Object) -join ', '
            Write-Host "Velden die de API teruggaf: $fields" -ForegroundColor DarkGray
            Write-Warning ('Geen bestaande backup-locatie gevonden in SDDC Manager; het schema is NIET toegepast. ' +
                'Stel eerst de SFTP-locatie in (-Component SddcManager) of sla de controle over met -SkipConfigCheck.')
            return
        }
    }

    # 4. Schema toepassen
    $task = Invoke-VcfApi -Method PATCH -Uri "$base/v1/system/backup-configuration" -Headers $headers -Body $body
    $taskId = $task.id
    if (-not $taskId) { throw 'Geen taak-ID ontvangen na het toepassen van het backup-schema.' }
    Write-Host "Taak gestart: $taskId"

    # 5. Wachten tot de taak niet meer 'In Progress' is
    do {
        $result = Invoke-VcfApi -Method GET -Uri "$base/v1/tasks/$taskId" -Headers $headers
        $status = $result.status
        if ($status -eq 'In Progress') {
            Write-Host "Nog in 'In Progress' status... wacht $SddcPollSeconds seconden."
            Start-Sleep -Seconds $SddcPollSeconds
        }
    } while ($status -eq 'In Progress')

    if ($status -eq 'Failed') {
        throw "De SDDC Manager taak is mislukt: $($result | ConvertTo-Json -Depth 10 -Compress)"
    }
    Write-Host "SDDC Manager backup-schema taak afgerond met status: $status" -ForegroundColor Green
    $result
}

#endregion

#region vCenter ---------------------------------------------------------------

function Set-VCenterSftpBackup {
    Write-Host "`n=== SFTP backup: vCenter ===" -ForegroundColor Cyan
    $base = "https://$vCenterFqdn"
    $backupDirectory = Get-ComponentBackupDirectory -Fqdn $vCenterFqdn
    Write-Host "Backup directory: $backupDirectory"

    # 1. Sessietoken ophalen via Basic auth
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${vCenterUser}:${vCenterPass}"))
    $token = Invoke-VcfApi -Method POST -Uri "$base/api/session" -Headers @{ Authorization = "Basic $basic" }
    $token = "$token".Trim('"')
    if (-not $token) { throw 'Geen sessietoken ontvangen van vCenter.' }
    Write-Host 'Sessietoken succesvol opgehaald.'

    $headers = @{ 'vmware-api-session-id' = $token; Accept = 'application/json' }

    # vCenter versleutelt de backup alleen als backup_password is ingevuld (8-20 tekens,
    # hoofdletter, kleine letter, cijfer, speciaal teken, geen spaties).
    if ([string]::IsNullOrEmpty($EncryptionPassphrase)) {
        throw 'EncryptionPassphrase is leeg: de vCenter backup zou dan niet versleuteld worden.'
    }
    if ($EncryptionPassphrase.Length -lt 8 -or $EncryptionPassphrase.Length -gt 20 -or
        $EncryptionPassphrase -cnotmatch '[A-Z]' -or $EncryptionPassphrase -cnotmatch '[a-z]' -or
        $EncryptionPassphrase -notmatch '\d' -or $EncryptionPassphrase -notmatch '[^A-Za-z0-9]' -or
        $EncryptionPassphrase -match '\s') {
        throw 'EncryptionPassphrase voldoet niet aan de vCenter-eisen (8-20 tekens, hoofdletter, kleine letter, cijfer, speciaal teken, geen spaties).'
    }

    # 2. Payload opbouwen
    $payload = [ordered]@{
        schedule = 'default'
        spec     = [ordered]@{
            location          = "sftp://$SftpServerIp$backupDirectory"
            location_user     = $SftpUser
            location_password = $SftpPass
            parts             = @('supervisors', 'seat', 'common')
            backup_password   = $EncryptionPassphrase
            recurrence_info   = [ordered]@{ days = @(); hour = 23; minute = '0' }
            retention_info    = [ordered]@{ max_count = 3 }
        }
    }
    $json = Save-JsonPayload -Object $payload -FileName 'sftp-backup-location-vcenter.json'

    # 3. Backup schedule aanmaken
    Invoke-VcfApi -Method POST -Uri "$base/api/appliance/recovery/backup/schedules" -Headers $headers -Body $json
    Write-Host 'vCenter backup schedule aangemaakt.' -ForegroundColor Green
}

#endregion

#region Uitvoeren -------------------------------------------------------------

try {
    switch ($Component) {
        'FleetLifecycle' { Set-FleetLifecycleSftpBackup }
        'FleetBackupSchedule' { Set-FleetLifecycleSftpBackup -ScheduleOnly }
        'SddcManager'    { Set-SddcManagerSftpBackup }
        'SddcManagerBackupSchedule' { Set-SddcManagerBackupSchedule }
        'vCenter'        { Set-VCenterSftpBackup }
        'All' {
            Set-FleetLifecycleSftpBackup
            Set-SddcManagerSftpBackup
            Set-VCenterSftpBackup
        }
    }
}
catch {
    Write-Error "Fout tijdens uitvoeren: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
    throw
}

#endregion
