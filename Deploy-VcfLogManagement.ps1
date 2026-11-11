<#
.SYNOPSIS
    Deployt Log Management (OPS_LOGS) via de VCF Fleet Lifecycle Service APIs.

.DESCRIPTION
    PowerShell-versie van de blogpost "VMware Cloud Foundation APIs: Deploying Log Management"
    (https://my-cloudy-world.com/2026/07/09/vmware-cloud-foundation-apis-deploying-log-management/).

    Alle instellingen staan in het $config-blok bovenaan het script. Je kunt:
      - het $config-blok direct aanpassen, of
      - een JSON-bestand meegeven met -ConfigFile (waarden daarin overschrijven $config).

    Stappen:
      1. Authenticeren           POST /api/v1/identity/token
      2. Primaire SDDC LCM ID    GET  /fleet-lcm/v1/sddc-lcms
      3. Payload opbouwen
      4. Valideren               POST /fleet-lcm/v1/components/validations
      5. Deployen                POST /fleet-lcm/v1/components
      6. Voortgang volgen        GET  /fleet-lcm/v1/tasks/{taskId}

.PARAMETER ConfigFile
    Optioneel pad naar een JSON-configuratiebestand met dezelfde structuur als $config.
    Alleen de waarden die je opgeeft worden overschreven.

.PARAMETER ValidateOnly
    Voer alleen de validatie uit en start de deployment niet (overschrijft $config.Options.ValidateOnly).

.EXAMPLE
    .\Deploy-VcfLogManagement.ps1

.EXAMPLE
    .\Deploy-VcfLogManagement.ps1 -ConfigFile .\config.json -ValidateOnly
#>

[CmdletBinding()]
param(
    [string]$ConfigFile,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'

# ===========================================================================
# CONFIGURATIE - pas deze waarden aan voor jouw omgeving
# ===========================================================================
$config = @{
    FleetLifecycle = @{
        # FQDN van het component "Fleet lifecycle"
        # (VCF Operations > Build > Lifecycle > VCF Management > Components)
        Fqdn     = 'vcf-flt-01.wardhomelab.nl'
        User     = 'admin@vsp.local'
        # Laat leeg om tijdens het uitvoeren om het wachtwoord te vragen (aanbevolen).
        Password = '<YourPasswordHere>'
    }

    LogManagement = @{
        Fqdn          = 'vcf-log-01.wardhomelab.nl'
        Size          = 'small'
        NodeCount     = 1
        Version       = '9.1.1.0100'
        ComponentType = 'OPS_LOGS'
    }

    Options = @{
        # Negeer TLS-certificaatfouten (equivalent van curl -k)
        SkipCertificateCheck = $true
        # Alleen valideren, niet deployen
        ValidateOnly         = $false
        # Waar de JSON-payload wordt opgeslagen
        PayloadPath          = (Join-Path (Get-Location) 'log-management-deploy.json')
        # Wachttijd (seconden) tussen statuscontroles
        ValidationPollSeconds = 2
        DeploymentPollSeconds = 60
    }
}

# ---------------------------------------------------------------------------
# Optioneel: waarden overschrijven vanuit een JSON-bestand
# ---------------------------------------------------------------------------
function Merge-Config {
    param([hashtable]$Base, $Override)
    foreach ($prop in $Override.PSObject.Properties) {
        if ($prop.Value -is [System.Management.Automation.PSCustomObject] -and $Base.ContainsKey($prop.Name) -and $Base[$prop.Name] -is [hashtable]) {
            Merge-Config -Base $Base[$prop.Name] -Override $prop.Value
        }
        else {
            $Base[$prop.Name] = $prop.Value
        }
    }
}

if ($ConfigFile) {
    if (-not (Test-Path $ConfigFile)) { throw "Configuratiebestand niet gevonden: $ConfigFile" }
    $override = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
    Merge-Config -Base $config -Override $override
    Write-Host "Configuratie geladen uit $ConfigFile" -ForegroundColor DarkGray
}

if ($ValidateOnly) { $config.Options.ValidateOnly = $true }

# ---------------------------------------------------------------------------
# Configuratie controleren
# ---------------------------------------------------------------------------
foreach ($key in 'Fqdn', 'User') {
    if ([string]::IsNullOrWhiteSpace($config.FleetLifecycle[$key])) { throw "config.FleetLifecycle.$key is leeg." }
}
foreach ($key in 'Fqdn', 'Size', 'Version', 'ComponentType') {
    if ([string]::IsNullOrWhiteSpace($config.LogManagement[$key])) { throw "config.LogManagement.$key is leeg." }
}
if ([int]$config.LogManagement.NodeCount -lt 1) { throw 'config.LogManagement.NodeCount moet minimaal 1 zijn.' }

$fleetFqdn = $config.FleetLifecycle.Fqdn

# Wachtwoord: uit config of interactief
if ([string]::IsNullOrEmpty($config.FleetLifecycle.Password)) {
    $cred = Get-Credential -Message "Fleet Lifecycle Service ($fleetFqdn)" -UserName $config.FleetLifecycle.User
    $config.FleetLifecycle.User     = $cred.UserName
    $config.FleetLifecycle.Password = $cred.GetNetworkCredential().Password
}

# ---------------------------------------------------------------------------
# TLS-afhandeling (curl -k equivalent)
# ---------------------------------------------------------------------------
$script:UseSkipCertParam = $false
if ($config.Options.SkipCertificateCheck) {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $script:UseSkipCertParam = $true
    }
    else {
        # Windows PowerShell 5.1
        if (-not ('TrustAllCertsPolicy' -as [type])) {
            Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
        }
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    }
}

# ---------------------------------------------------------------------------
# Hulpfuncties
# ---------------------------------------------------------------------------
function Invoke-FleetApi {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Headers = @{},
        $Body,
        [string]$ContentType = 'application/json'
    )

    $params = @{
        Uri     = "https://$fleetFqdn$Path"
        Method  = $Method
        Headers = $Headers
    }
    if ($null -ne $Body) {
        $params.Body        = $Body
        $params.ContentType = $ContentType
    }
    if ($script:UseSkipCertParam) { $params.SkipCertificateCheck = $true }

    try {
        Invoke-RestMethod @params
    }
    catch {
        $detail = $_.ErrorDetails.Message
        if (-not $detail) { $detail = $_.Exception.Message }
        throw "API-aanroep $Method $Path mislukt: $detail"
    }
}

function Wait-FleetTask {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$Description,
        [int]$PollSeconds = 5
    )

    do {
        $task = Invoke-FleetApi -Method GET -Path "/fleet-lcm/v1/tasks/$TaskId" -Headers $Headers
        if ($task.status -eq 'RUNNING') {
            Write-Host "  $Description : status RUNNING... wacht $PollSeconds seconden." -ForegroundColor DarkGray
            Start-Sleep -Seconds $PollSeconds
        }
    } while ($task.status -eq 'RUNNING')

    return $task
}

# ---------------------------------------------------------------------------
# 1. Authenticeren
# ---------------------------------------------------------------------------
Write-Host '[1/6] Authenticeren bij de Fleet Lifecycle Service...' -ForegroundColor Cyan

$tokenBody = @{
    grant_type = 'password'
    username   = $config.FleetLifecycle.User
    password   = $config.FleetLifecycle.Password
}

$tokenResponse = Invoke-FleetApi -Method POST -Path '/api/v1/identity/token' `
    -Body $tokenBody -ContentType 'application/x-www-form-urlencoded'

$token = $tokenResponse.access_token
if (-not $token) { throw 'Geen access_token ontvangen.' }
Write-Host '      Token succesvol opgehaald.' -ForegroundColor Green

$headers = @{
    Authorization = "Bearer $token"
    Accept        = 'application/json'
}

# ---------------------------------------------------------------------------
# 2. Primaire SDDC LCM ID ophalen
# ---------------------------------------------------------------------------
Write-Host '[2/6] Primaire SDDC LCM instance ophalen...' -ForegroundColor Cyan

$sddcLcms = Invoke-FleetApi -Method GET -Path '/fleet-lcm/v1/sddc-lcms' -Headers $headers
$primarySddcLcmId = ($sddcLcms.sddcLcms | Where-Object { $_.isPrimary -eq $true } | Select-Object -First 1).id

if (-not $primarySddcLcmId) { throw 'Geen primaire SDDC LCM instance gevonden.' }
Write-Host "      Primaire SDDC LCM ID: $primarySddcLcmId" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. Payload opbouwen
# ---------------------------------------------------------------------------
Write-Host '[3/6] JSON-payload opbouwen...' -ForegroundColor Cyan

$payload = [ordered]@{
    componentSpecs = @(
        [ordered]@{
            sddcLcmId      = $primarySddcLcmId
            componentType  = $config.LogManagement.ComponentType
            deploymentType = 'VspComponentSpec'
            version        = $config.LogManagement.Version
            fqdn           = $config.LogManagement.Fqdn
            configSpec     = [ordered]@{
                size          = $config.LogManagement.Size
                numberOfNodes = [int]$config.LogManagement.NodeCount
            }
        }
    )
}

$payloadJson = $payload | ConvertTo-Json -Depth 10
Set-Content -Path $config.Options.PayloadPath -Value $payloadJson -Encoding UTF8
Write-Host "      Payload opgeslagen in $($config.Options.PayloadPath)" -ForegroundColor Green
Write-Host $payloadJson

# ---------------------------------------------------------------------------
# 4. Valideren
# ---------------------------------------------------------------------------
Write-Host '[4/6] Deployment valideren...' -ForegroundColor Cyan

$validation = Invoke-FleetApi -Method POST -Path '/fleet-lcm/v1/components/validations' `
    -Headers $headers -Body $payloadJson
$validationId = $validation.id
if (-not $validationId) { throw 'Geen validatie-ID ontvangen.' }
Write-Host "      Validatie-ID: $validationId"

$validationResult = Wait-FleetTask -TaskId $validationId -Headers $headers `
    -Description 'Validatie' -PollSeconds $config.Options.ValidationPollSeconds

Write-Host "      Validatie afgerond met status: $($validationResult.status)"
$validationResult | ConvertTo-Json -Depth 10

if ($validationResult.status -match 'FAIL|ERROR') {
    throw "Validatie mislukt (status: $($validationResult.status)). Controleer de bovenstaande uitvoer."
}
Write-Host '      Validatie geslaagd.' -ForegroundColor Green

if ($config.Options.ValidateOnly) {
    Write-Host 'ValidateOnly actief: deployment wordt niet gestart.' -ForegroundColor Yellow
    return
}

# ---------------------------------------------------------------------------
# 5. Deployment starten
# ---------------------------------------------------------------------------
Write-Host '[5/6] Deployment starten...' -ForegroundColor Cyan

$deployment = Invoke-FleetApi -Method POST -Path '/fleet-lcm/v1/components' `
    -Headers $headers -Body $payloadJson
$deploymentId = $deployment.id
if (-not $deploymentId) { throw 'Geen deployment-ID ontvangen.' }
Write-Host "      Deployment-ID: $deploymentId"

# ---------------------------------------------------------------------------
# 6. Voortgang bewaken
# ---------------------------------------------------------------------------
Write-Host '[6/6] Voortgang van de deployment volgen...' -ForegroundColor Cyan

$deploymentResult = Wait-FleetTask -TaskId $deploymentId -Headers $headers `
    -Description 'Deployment' -PollSeconds $config.Options.DeploymentPollSeconds

Write-Host "      Deployment afgerond met status: $($deploymentResult.status)"
$deploymentResult | ConvertTo-Json -Depth 10

if ($deploymentResult.status -match 'FAIL|ERROR') {
    throw "Deployment mislukt (status: $($deploymentResult.status))."
}
Write-Host "Log Management is gedeployd: https://$($config.LogManagement.Fqdn)" -ForegroundColor Green
