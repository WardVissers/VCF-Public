<#
.SYNOPSIS
    Configures a Microsoft Certificate Authority in VCF Operations (VCF 9.x).

.DESCRIPTION
    PowerShell translation of the curl/bash steps:
      0. Pre-check       : is the CA reachable from this system (warnings only)
      1. Get token       : POST /suite-api/api/auth/token/acquire
      2. Read current CA : GET  /suite-api/api/fleet-management/certificate-management/certificate-authorities
      3. Configure CA    : PUT  (same endpoint)
      4. Verify result   : GET  (same endpoint)

    Adjust the values in the $config block below and run the script.
    Leave a password empty ('') to be prompted for it securely at runtime.
#>

# =====================================================================
#  CONFIGURATION - adjust these values
# =====================================================================
$config = @{
      # VCF Operations
    vcfOperationsFqdn  = 'vcf-ops-01.wardhomelab.nl'
    vcfOperationsUser  = 'admin'
    vcfOperationsPass  = '<YourPasswordHere>'

    # Microsoft Certificate Authority
    certificateAuthorityUrl      = 'https://dc.wardvissers.nl/certsrv'
    certificateAuthorityUser     = 'wardvissers\svc-vcf-ca'
    certificateAuthorityPass     = '<YourPasswordHere>'
    certificateAuthorityTemplate = 'VCF_Template'

    # $true = negeer self-signed / niet-vertrouwde certificaten (zoals 'curl -k')
    skipCertificateCheck = $true
}
# =====================================================================

$ErrorActionPreference = 'Stop'
$script:step = 'Initialization'

# --- Helper functions -------------------------------------------------
function Read-PlainPassword {
    param([string]$Prompt)
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}

function Get-ApiErrorText {
    param($ErrorRecord)

    $raw = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $raw = $ErrorRecord.ErrorDetails.Message
    }
    elseif ($ErrorRecord.Exception.Response -and
            $ErrorRecord.Exception.Response.PSObject.Methods['GetResponseStream']) {
        try {
            $reader = New-Object System.IO.StreamReader($ErrorRecord.Exception.Response.GetResponseStream())
            $raw = $reader.ReadToEnd()
        } catch { }
    }
    if (-not $raw) { return $ErrorRecord.Exception.Message }

    # Try to format the VCF Operations error response nicely
    try {
        $json  = $raw | ConvertFrom-Json
        $lines = @()
        if ($json.httpStatusCode) { $lines += "HTTP status : $($json.httpStatusCode)" }
        if ($json.message)        { $lines += "Message     : $($json.message)" }
        foreach ($info in $json.moreInformation) {
            $lines += "Detail      : $($info.name) = $($info.value)"
        }
        if ($lines.Count -gt 0) { return ($lines -join [Environment]::NewLine) }
    } catch { }

    return $raw
}

function Test-CertificateAuthorityEndpoint {
    # Note: this tests the connection from THIS system. VCF Operations must be able
    # to reach the CA itself, so a warning here is a hint and not a hard failure.
    param([string]$Url, [string]$User, [string]$Pass)

    $uri  = [uri]$Url
    $port = if ($uri.Port -gt 0) { $uri.Port } else { 443 }

    # DNS
    try {
        $null = [System.Net.Dns]::GetHostAddresses($uri.Host)
        Write-Host "      DNS      : $($uri.Host) resolves." -ForegroundColor Green
    } catch {
        Write-Warning "DNS: $($uri.Host) cannot be resolved from this system."
        return
    }

    # TCP
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $tcp.BeginConnect($uri.Host, $port, $null, $null)
        if ($connect.AsyncWaitHandle.WaitOne(5000) -and $tcp.Connected) {
            Write-Host "      TCP      : port $port is reachable." -ForegroundColor Green
        } else {
            Write-Warning "TCP: port $port on $($uri.Host) is not reachable (timeout). Check the firewall."
            return
        }
    } catch {
        Write-Warning "TCP: connection to $($uri.Host):$port failed. $($_.Exception.Message)"
        return
    } finally {
        $tcp.Close()
    }

    # HTTP with credentials (Web Enrollment page)
    $cred   = New-Object System.Management.Automation.PSCredential(
                  $User, (ConvertTo-SecureString $Pass -AsPlainText -Force))
    $params = @{ Uri = $Url; Credential = $cred; UseBasicParsing = $true; TimeoutSec = 10 }
    if ($config.skipCertificateCheck -and $isCore) { $params.SkipCertificateCheck = $true }

    try {
        $response = Invoke-WebRequest @params
        Write-Host "      HTTP     : $Url responded with status $($response.StatusCode). Credentials look valid." -ForegroundColor Green
    } catch {
        $status = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        switch ($status) {
            401     { Write-Warning "HTTP 401: login to the CA failed. Check the username (DOMAIN\user) and password." }
            403     { Write-Warning "HTTP 403: the account has no access to Web Enrollment." }
            404     { Write-Warning "HTTP 404: path not found. Is the 'Certification Authority Web Enrollment' role installed and is the URL (/certsrv) correct?" }
            default { Write-Warning "HTTP test failed: $($_.Exception.Message)" }
        }
    }
}

function Invoke-VcfOpsApi {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{},
        [string]$Body
    )

    $params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $Headers
        ContentType = 'application/json'
    }
    if ($Body) { $params.Body = $Body }
    if ($config.skipCertificateCheck -and $isCore) { $params.SkipCertificateCheck = $true }

    Invoke-RestMethod @params
}

function Show-CertificateAuthority {
    param($Config)
    # Mask the password in the output
    $copy = $Config | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    if ($copy.microsoftCertificateAuthoritySpec.secret) {
        $copy.microsoftCertificateAuthoritySpec.secret = 'XXXXX'
    }
    $copy | ConvertTo-Json -Depth 10
}

# --- Preparation ------------------------------------------------------
if ([string]::IsNullOrEmpty($config.vcfOperationsPass)) {
    $config.vcfOperationsPass = Read-PlainPassword "Password for VCF Operations user '$($config.vcfOperationsUser)'"
}
if ([string]::IsNullOrEmpty($config.certificateAuthorityPass)) {
    $config.certificateAuthorityPass = Read-PlainPassword "Password for CA user '$($config.certificateAuthorityUser)'"
}

# TLS / certificate handling (works in Windows PowerShell 5.1 and PowerShell 7+)
$isCore = $PSVersionTable.PSEdition -eq 'Core'

if ($config.skipCertificateCheck -and -not $isCore) {
    if (-not ('TrustAllCertsPolicy' -as [type])) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
                                      WebRequest req, int problem) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$baseUri = "https://$($config.vcfOperationsFqdn)/suite-api/api"
$caUri   = "$baseUri/fleet-management/certificate-management/certificate-authorities"

# --- Execution --------------------------------------------------------
try {
    # 0. Pre-check CA
    $script:step = 'Pre-check Certificate Authority'
    Write-Host "[0/4] Checking Certificate Authority ($($config.certificateAuthorityUrl)) ..." -ForegroundColor Cyan

    if ($config.certificateAuthorityUser -notmatch '\\' -and $config.certificateAuthorityUser -notmatch '@') {
        Write-Warning "Username '$($config.certificateAuthorityUser)' contains no domain. Try DOMAIN\user or user@domain."
    }
    if ($config.certificateAuthorityTemplate -match '\s') {
        Write-Warning "Template name '$($config.certificateAuthorityTemplate)' contains spaces. Use the internal template name (without spaces)."
    }
    Test-CertificateAuthorityEndpoint -Url $config.certificateAuthorityUrl `
        -User $config.certificateAuthorityUser -Pass $config.certificateAuthorityPass

    # 1. Authenticate and obtain a token
    $script:step = 'Get token'
    Write-Host "[1/4] Requesting token from $($config.vcfOperationsFqdn) ..." -ForegroundColor Cyan

    $authBody = @{
        username = $config.vcfOperationsUser
        password = $config.vcfOperationsPass
    } | ConvertTo-Json

    $tokenResponse = Invoke-VcfOpsApi -Method POST -Uri "$baseUri/auth/token/acquire" `
        -Headers @{ Accept = 'application/json' } -Body $authBody

    $token = $tokenResponse.token
    if (-not $token) { throw 'No token received from VCF Operations.' }
    Write-Host "      Token received." -ForegroundColor Green

    $headers = @{
        Authorization = "OpsToken $token"
        Accept        = 'application/json'
    }

    # 2. Check the current configuration
    $script:step = 'Read current configuration'
    Write-Host "[2/4] Current Certificate Authority configuration:" -ForegroundColor Cyan
    $current = Invoke-VcfOpsApi -Method GET -Uri $caUri -Headers $headers
    Show-CertificateAuthority -Config $current

    # 3. Build the JSON payload and configure the CA
    $script:step = 'Configure Certificate Authority (PUT)'
    Write-Host "[3/4] Configuring Microsoft Certificate Authority ..." -ForegroundColor Cyan

    $payload = [ordered]@{
        certificateAuthorityType   = 'MICROSOFT'
        certificateAuthoritiesSpec = [ordered]@{
            microsoftCertificateAuthoritySpec = [ordered]@{
                serverUrl    = $config.certificateAuthorityUrl
                username     = $config.certificateAuthorityUser
                secret       = $config.certificateAuthorityPass
                templateName = $config.certificateAuthorityTemplate
            }
        }
    } | ConvertTo-Json -Depth 10

    Invoke-VcfOpsApi -Method PUT -Uri $caUri -Headers $headers -Body $payload | Out-Null
    Write-Host "      PUT completed." -ForegroundColor Green

    # 4. Verify the result
    $script:step = 'Verification'
    Write-Host "[4/4] Verifying the configuration:" -ForegroundColor Cyan
    $result = Invoke-VcfOpsApi -Method GET -Uri $caUri -Headers $headers
    Show-CertificateAuthority -Config $result

    $spec = $result.microsoftCertificateAuthoritySpec
    if ($spec.serverUrl -eq $config.certificateAuthorityUrl -and $spec.templateName -eq $config.certificateAuthorityTemplate) {
        Write-Host "Microsoft Certificate Authority was configured successfully." -ForegroundColor Green
    } else {
        Write-Warning 'The returned configuration does not match the values you entered. Check the output above.'
    }
}
catch {
    Write-Host ''
    Write-Host "ERROR during step: $script:step" -ForegroundColor Red
    Write-Host (Get-ApiErrorText $_) -ForegroundColor Red

    if ($script:step -like '*PUT*') {
        Write-Host ''
        Write-Host 'Possible causes (VCF Operations cannot validate the CA):' -ForegroundColor Yellow
        Write-Host '  - CA not reachable from the VCF Operations appliance (DNS/firewall, port 443)'
        Write-Host '  - Web Enrollment (/certsrv) not installed or incorrect URL'
        Write-Host '  - Username without domain (use DOMAIN\user or user@domain)'
        Write-Host '  - Template not published, wrong name, or no Enroll permission'
        Write-Host '  - CA certificate is not trusted by VCF Operations'
    }
    exit 1
}
