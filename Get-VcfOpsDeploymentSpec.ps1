<#
.SYNOPSIS
    Retrieves the latest SDDC deployment spec from SDDC Manager and shows a
    clean overview of every account and password it contains.

.DESCRIPTION
    PowerShell equivalent of:
      1. POST /v1/tokens              -> accessToken
      2. GET  /v1/sddcs/latest        -> id of the latest deployment
      3. GET  /v1/sddcs/<id>/spec     -> full deployment spec
    The spec itself is used only in memory to extract credentials; it is
    never written to disk or returned as a whole.

.PARAMETER Server
    FQDN or IP address of SDDC Manager. Defaults to localhost.

.PARAMETER Credential
    Credentials for the API (for example admin@local).

.PARAMETER OutFile
    Optional: path used to derive the KeePass-importable CSV file name
    (<name>-credentials-keepass.csv). No spec JSON is written. If omitted,
    the file is named "<sddcId>-credentials-keepass.csv" in the current folder.

.EXAMPLE
    .\Get-VcfOpsDeploymentSpec.ps1 -Server sddc-manager.lab.local -OutFile .\sddc-spec.json
    # writes .\sddc-spec-credentials-keepass.csv, ready for KeePass/KeePassXC import
#>

[CmdletBinding()]
param(
    [string]$Server = '192.168.150.245',

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [string]$OutFile
)

Clear-Host

# Location
switch ((get-host).Name) { 
    'Windows PowerShell ISE Host' { $folder = $psISE.CurrentFile.FullPath -replace ($psISE.CurrentFile.DisplayName,"") }
    'ConsoleHost' { $folder = $myInvocation.MyCommand.Path -replace ($myInvocation.MyCommand.Name,"")  }
    'Visual Studio Code Host'{ $folder = $psEditor.GetEditorContext().CurrentFile.Path | Split-Path  }
}

Set-Location $folder


$ErrorActionPreference = 'Stop'

# --- Allow self-signed certificates (equivalent of curl -k) ----------------
$restParams = @{}
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $restParams['SkipCertificateCheck'] = $true
}
else {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) {
        return true;
    }
}
"@ -ErrorAction SilentlyContinue
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

if ($Credential -eq [System.Management.Automation.PSCredential]::Empty) {
    $Credential = Get-Credential -Message "SDDC Manager API" -UserName 'admin@local'
}

$baseUri = "https://$Server"

# --- 1. Request an access token -------------------------------------------
Write-Verbose "Requesting token from $baseUri/v1/tokens"

$tokenBody = @{
    username = $Credential.UserName
    password = $Credential.GetNetworkCredential().Password
} | ConvertTo-Json

$tokenResponse = Invoke-RestMethod @restParams `
    -Uri "$baseUri/v1/tokens" `
    -Method Post `
    -ContentType 'application/json' `
    -Body $tokenBody

$token = $tokenResponse.accessToken
if (-not $token) { throw "No accessToken returned by $baseUri" }

$headers = @{
    Authorization = "Bearer $token"
    Accept        = 'application/json'
}

# --- 2. Get the ID of the latest deployment -------------------------------
Write-Verbose "Retrieving the latest SDDC"

$latest = Invoke-RestMethod @restParams `
    -Uri "$baseUri/v1/sddcs/latest" `
    -Method Get `
    -Headers $headers `
    -ContentType 'application/json'

$sddcId = $latest.id
if (-not $sddcId) { throw "No SDDC id found in /v1/sddcs/latest" }

Write-Host "Latest SDDC deployment id: $sddcId" -ForegroundColor Cyan

# --- 3. Retrieve the spec (used only in memory to extract credentials) ----
$spec = Invoke-RestMethod @restParams `
    -Uri "$baseUri/v1/sddcs/$sddcId/spec" `
    -Method Get `
    -Headers $headers `
    -ContentType 'application/json'



# Map a JSON path to a friendly component name matching the SDDC Manager UI.
# Used only as a fallback classifier for password-like fields that aren't
# covered by the explicit rules below (see Get-ExplicitCredentials).
function Get-ComponentName {
    param([string]$Path)

    switch -Regex ($Path) {
        '(?i)sddcManager'                                          { return 'SDDC Manager' }
        '(?i)nsxt|nsxManager|nsxSpec'                              { return 'NSX Manager' }
        '(?i)vcenter'                                              { return 'vCenter' }
        '(?i)vcfAutomation|automationSpec'                         { return 'VCF Automation' }
        '(?i)vspCluster|fleetLcm|sddcLcm|fleetDepot|telemetryAcceptor|vidbSpec|saltSpec|saltRaas' { return 'VCF Management Services' }
        '(?i)vcfOperationsCollector|cloudProxy'                    { return 'Cloud Proxy' }
        '(?i)vcfOperations(?!Collector)|vrealizeOperations|vrops'  { return 'VCF Operations' }
        '(?i)hostSpecs|esxi|\.hosts\b'                             { return 'Hosts' }
        default                                                    { return 'Other' }
    }
}

# --- 4. Build a clean overview of usernames / passwords -------------------
# Two layers:
#   1. Explicit, hand-mapped rules for the known VCF 9.1 install-spec fields
#      (accurate Component/Type/Username, since these field names don't
#      carry a "username" of their own - e.g. "rootVcenterPassword" implies
#      username "root" but doesn't say so literally).
#   2. A generic fallback scan that catches any other *Password/username
#      field the explicit rules don't recognise (e.g. on a future VCF
#      version), tagged via Get-ComponentName / Get-CredentialType so
#      nothing silently disappears.
# The same type/component can legitimately occur multiple times (e.g. Root
# on every ESXi host), so nothing is de-duplicated away.

function New-CredEntry {
    param($List, [string]$Component, [string]$Type, [string]$Username, $Password, [string]$Path, [string]$Hostname)
    if ([string]::IsNullOrEmpty($Password)) { return }
    $List.Add([PSCustomObject]@{
        Component = $Component
        Type      = $Type
        Username  = $Username
        Password  = $Password
        Path      = $Path
        Hostname  = $Hostname
    }) | Out-Null
}

function Get-ExplicitCredentials {
    param($Spec)

    $list = [System.Collections.Generic.List[PSCustomObject]]::new()

    # --- Hosts -------------------------------------------------------------
    if ($Spec.hostSpecs) {
        $i = 0
        foreach ($h in $Spec.hostSpecs) {
            if ($h.credentials) {
                New-CredEntry $list 'Hosts' 'Root' $h.credentials.username $h.credentials.password ".hostSpecs[$i].credentials" $h.hostname
            }
            $i++
        }
    }

    # --- vCenter -------------------------------------------------------------
    if ($Spec.vcenterSpec) {
        New-CredEntry $list 'vCenter' 'Root' 'root' $Spec.vcenterSpec.rootVcenterPassword '.vcenterSpec.rootVcenterPassword' $Spec.vcenterSpec.vcenterHostname
        $ssoDomain = $(if ($Spec.vcenterSpec.ssoDomain) { $Spec.vcenterSpec.ssoDomain } else { 'vsphere.local' })
        New-CredEntry $list 'vCenter' 'Administrator' "administrator@$ssoDomain" $Spec.vcenterSpec.adminUserSsoPassword '.vcenterSpec.adminUserSsoPassword' $Spec.vcenterSpec.vcenterHostname
    }

    # --- NSX Manager -----------------------------------------------------
    if ($Spec.nsxtSpec) {
        $nsxHost = $(if ($Spec.nsxtSpec.vipFqdn) { $Spec.nsxtSpec.vipFqdn } elseif ($Spec.nsxtSpec.nsxtManagers) { $Spec.nsxtSpec.nsxtManagers[0].hostname } else { $null })
        New-CredEntry $list 'NSX Manager' 'Root'  'root'  $Spec.nsxtSpec.rootNsxtManagerPassword '.nsxtSpec.rootNsxtManagerPassword' $nsxHost
        New-CredEntry $list 'NSX Manager' 'Admin' 'admin' $Spec.nsxtSpec.nsxtAdminPassword        '.nsxtSpec.nsxtAdminPassword' $nsxHost
        New-CredEntry $list 'NSX Manager' 'Audit' 'audit' $Spec.nsxtSpec.nsxtAuditPassword         '.nsxtSpec.nsxtAuditPassword' $nsxHost
    }

    # --- SDDC Manager --------------------------------------------------------
    if ($Spec.sddcManagerSpec) {
        New-CredEntry $list 'SDDC Manager' 'Root'  'root'        $Spec.sddcManagerSpec.rootPassword      '.sddcManagerSpec.rootPassword' $Spec.sddcManagerSpec.hostname
        New-CredEntry $list 'SDDC Manager' 'SSH'   'vcf'         $Spec.sddcManagerSpec.sshPassword        '.sddcManagerSpec.sshPassword' $Spec.sddcManagerSpec.hostname
        New-CredEntry $list 'SDDC Manager' 'Admin' 'admin@local' $Spec.sddcManagerSpec.localUserPassword  '.sddcManagerSpec.localUserPassword' $Spec.sddcManagerSpec.hostname
    }

    # --- VCF Management Services (vspClusterSpec: instance/fleet platform) --
    # systemUserPassword provisions TWO accounts with the same password:
    # the internal 'vmware-system-user' service account and the
    # 'admin@vsp.local' UI/API admin account.
    if ($Spec.vspClusterSpec) {
        $vspHost = $(if ($Spec.vspClusterSpec.platformFqdn) { $Spec.vspClusterSpec.platformFqdn } else { $Spec.vspClusterSpec.instanceFqdn })
        New-CredEntry $list 'VCF Management Services' 'VCF'           'vmware-system-user' $Spec.vspClusterSpec.systemUserPassword '.vspClusterSpec.systemUserPassword (vmware-system-user)' $vspHost
        New-CredEntry $list 'VCF Management Services' 'Administrator' 'admin@vsp.local'     $Spec.vspClusterSpec.systemUserPassword '.vspClusterSpec.systemUserPassword (admin@vsp.local)' $vspHost
    }

    # --- VCF Operations ------------------------------------------------------
    if ($Spec.vcfOperationsSpec) {
        $i = 0
        foreach ($n in $Spec.vcfOperationsSpec.nodes) {
            New-CredEntry $list 'VCF Operations' 'Root' 'root' $n.rootUserPassword ".vcfOperationsSpec.nodes[$i].rootUserPassword" $n.hostname
            $i++
        }
        $opsHost = $(if ($Spec.vcfOperationsSpec.loadBalancerFqdn) { $Spec.vcfOperationsSpec.loadBalancerFqdn } elseif ($Spec.vcfOperationsSpec.nodes) { $Spec.vcfOperationsSpec.nodes[0].hostname } else { $null })
        New-CredEntry $list 'VCF Operations' 'Admin' 'admin' $Spec.vcfOperationsSpec.adminUserPassword '.vcfOperationsSpec.adminUserPassword' $opsHost
    }

    # --- Cloud Proxy (VCF Operations Collector) -------------------------------
    if ($Spec.vcfOperationsCollectorSpec) {
        New-CredEntry $list 'Cloud Proxy' 'Root' 'root' $Spec.vcfOperationsCollectorSpec.rootUserPassword '.vcfOperationsCollectorSpec.rootUserPassword' $Spec.vcfOperationsCollectorSpec.hostname
    }

    # --- VCF Automation --------------------------------------------------------
    if ($Spec.vcfAutomationSpec) {
        New-CredEntry $list 'VCF Automation' 'Admin' 'admin' $Spec.vcfAutomationSpec.adminUserPassword '.vcfAutomationSpec.adminUserPassword' $Spec.vcfAutomationSpec.hostname

        # The 'vmware-system-user' OS account on VCF Automation (confirmed
        # via Broadcom KB 424323 / 419010) shares the same password as the
        # 'admin' account above - both come from adminUserPassword.
        New-CredEntry $list 'VCF Automation' 'VCF' 'vmware-system-user' $Spec.vcfAutomationSpec.adminUserPassword '.vcfAutomationSpec.adminUserPassword (vmware-system-user)' $Spec.vcfAutomationSpec.hostname
    }

    return $list
}

# Map a username / property name value to one of the credential types we
# care about. Returns $null when nothing matches (fallback scan only).
function Get-CredentialType {
    param([string]$Text)

    if (-not $Text) { return $null }

    switch -Regex ($Text) {
        '(?i)^root$'                              { return 'Root' }
        '(?i)administrator'                       { return 'Administrator' }
        '(?i)ssh'                                 { return 'SSH' }
        '(?i)audit'                               { return 'Audit' }
        '(?i)vcf'                                 { return 'VCF' }
        '(?i)^admin$|adminuser|admin(?!istrator)' { return 'Admin' }
        default                                   { return $null }
    }
}

# Generic fallback: recursively scans for any password-like field the
# explicit rules above didn't already capture (matched by Path), so a
# future/slightly different spec never silently loses a credential.
function Get-FallbackCredentials {
    param($InputObject, [string]$Path = '', [System.Collections.Generic.HashSet[string]]$KnownPaths)

    $results = @()
    if ($null -eq $InputObject) { return $results }

    if ($InputObject -is [System.Collections.IEnumerable] -and
        -not ($InputObject -is [string]) -and
        -not ($InputObject -is [System.Collections.IDictionary])) {
        $i = 0
        foreach ($item in $InputObject) {
            $results += Get-FallbackCredentials -InputObject $item -Path "$Path[$i]" -KnownPaths $KnownPaths
            $i++
        }
        return $results
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $props = $InputObject.PSObject.Properties.Name
        $passProp = $props | Where-Object { $_ -match '(?i)password$' } | Select-Object -First 1
        $userProp = $props | Where-Object { $_ -match '(?i)^(username|userName)$' } | Select-Object -First 1

        if ($passProp) {
            $passPath = "$Path.$passProp"
            if (-not $KnownPaths.Contains($passPath)) {
                $credType = Get-CredentialType -Text $(if ($userProp) { $InputObject.$userProp } else { $passProp })
                if (-not $credType) { $credType = Get-CredentialType -Text ($Path -split '\.' | Select-Object -Last 1) }
                if ($credType) {
                    $results += [PSCustomObject]@{
                        Component = Get-ComponentName -Path $passPath
                        Type      = $credType
                        Username  = $(if ($userProp) { $InputObject.$userProp } else { '' })
                        Password  = $InputObject.$passProp
                        Path      = $passPath
                        Hostname  = ''
                    }
                }
            }
        }

        foreach ($p in $props) {
            $results += Get-FallbackCredentials -InputObject $InputObject.$p -Path "$Path.$p" -KnownPaths $KnownPaths
        }
    }

    return $results
}

$explicitCreds = Get-ExplicitCredentials -Spec $spec
$knownPaths = [System.Collections.Generic.HashSet[string]]::new([string[]]($explicitCreds.Path))
$fallbackCreds = Get-FallbackCredentials -InputObject $spec -KnownPaths $knownPaths

# Rows without a known hostname (e.g. fallback matches, or a spec that
# doesn't set a component's hostname field) are dropped - a credential you
# can't tie to a system isn't useful in a password manager entry.
$credentialOverview = @($explicitCreds) + @($fallbackCreds) |
    Sort-Object Component, Type, Path -Unique |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_.Hostname) }

# Fixed display order for components, matching the SDDC Manager UI grouping.
$componentOrder = @(
    'SDDC Manager', 'NSX Manager', 'vCenter', 'VCF Automation',
    'VCF Management Services', 'Cloud Proxy', 'VCF Operations', 'Hosts', 'Other'
)

Write-Host ""
Write-Host "=== Credential overview ===" -ForegroundColor Yellow
$credentialOverview |
    Sort-Object { $componentOrder.IndexOf($_.Component) }, Type, Path |
    Format-Table -AutoSize -Property Component, Hostname, Username, Password

# --- KeePass-compatible CSV export -----------------------------------------
# KeePass/KeePassXC's generic CSV importer expects: Group,Title,Username,
# Password,URL,Notes (any extra columns are ignored, so this file also opens
# fine as a plain spreadsheet).
#   Group  -> Component (creates one KeePass group per VCF component)
#   Title  -> Hostname if known, otherwise "<Component> - <Type>"
#   URL    -> https://<Hostname> when a hostname was found
#   Notes  -> the credential Type (Root/Administrator/SSH/Admin/Audit/VCF)
$keepassRows = $credentialOverview |
    Sort-Object { $componentOrder.IndexOf($_.Component) }, Type, Path |
    ForEach-Object {
        [PSCustomObject]@{
            Group    = $_.Component
            Title    = $(if ($_.Hostname) { $_.Hostname } else { "$($_.Component) - $($_.Type)" })
            Username = $_.Username
            Password = $_.Password
            URL      = $(if ($_.Hostname) { "https://$($_.Hostname)" } else { '' })
            Notes    = $_.Type
        }
    }

$credOutFile = $(if ($OutFile) {
    [System.IO.Path]::ChangeExtension($OutFile, $null).TrimEnd('.') + '-credentials-keepass.csv'
} else {
    Join-Path -Path (Get-Location) -ChildPath "$sddcId-credentials-keepass.csv"
})

$keepassRows | Export-Csv -Path $credOutFile -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "KeePass-importable CSV written to $credOutFile" -ForegroundColor Green
Write-Host "In KeePass(XC): File > Import > CSV File, and map the columns if not auto-detected." -ForegroundColor DarkGray

# The extracted overview stays available on the pipeline (Component,
# Hostname, Username, Password only - internal Type/Path fields are dropped):
#   $creds = .\Get-VcfOpsDeploymentSpec.ps1 -Server sddc-manager.lab.local
#   $creds | Where-Object Component -eq 'vCenter'
return $credentialOverview | Select-Object Component, Hostname, Username, Password
