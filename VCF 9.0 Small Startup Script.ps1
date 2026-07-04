# --------------------------------------------------------
# VMware Cloud Foundation Startup Script
# Author: PowerCLI
# Starts VMs in dependency order
# --------------------------------------------------------
# =============================================================================
# SCRIPT LOCATION
# =============================================================================
switch ((Get-Host).Name) {
    'Windows PowerShell ISE Host' { $current_file_folder = $psISE.CurrentFile.FullPath -replace ($psISE.CurrentFile.DisplayName, "") }
    'ConsoleHost'                 { $current_file_folder = $MyInvocation.MyCommand.Path -replace ($MyInvocation.MyCommand.Name, "") }
    'Visual Studio Code Host'     { $current_file_folder = $psEditor.GetEditorContext().CurrentFile.Path | Split-Path }
}
Set-Location $current_file_folder
# =============================================================================
# vCenter Connection
# =============================================================================
 
# Zet InvalidCertificateAction op Ignore voor deze sessie
    $config = Get-PowerCLIConfiguration

    if ($config.InvalidCertificateAction -ne 'Ignore') {
        Write-Host "InvalidCertificateAction is not set to Ignore. Updating..." -ForegroundColor Yellow
        Set-PowerCLIConfiguration `
            -InvalidCertificateAction Ignore `
            -Scope Session `
            -Confirm:$false | Out-Null
        Write-Host "InvalidCertificateAction set to Ignore." -ForegroundColor Green
    }
    else {
        Write-Host "InvalidCertificateAction is already set to Ignore." -ForegroundColor Green
    }

 # Check if already connected
    if ($global:DefaultVIServers -and $global:DefaultVIServers.IsConnected) {
    write-host "Already connected to vCenter: $($global:DefaultVIServers.Name)" -ForegroundColor Green
    }
    else {
        $vCenterCreds = Get-Credential -Message "Enter credentials for $vCenter" 
        $vCenter = read-host "What is the name of the vCenter"
        Connect-VIServer -Server $vCenter -Credential $vCenterCreds -ErrorAction Stop
    }


# ------------------------------------------------------------------
# Functions
# ------------------------------------------------------------------

function Start-VMOrdered {
    param(
        [string]$VMName,
        [int]$WaitSeconds = 180
    )

    Write-Host "---------------------------------------"
    Write-Host "Starting VM: $VMName"
    
    $vm = Get-VM -Name $VMName -ErrorAction Stop

    if ($vm.PowerState -ne "PoweredOn") {
        Start-VM -VM $vm -Confirm:$false
        Write-Host "$VMName power-on initiated"
        Write-Host "Waiting $WaitSeconds seconds for services to initialize..."
        Start-Sleep -Seconds $WaitSeconds
    }
    else {
        Write-Host "$VMName already powered on"
    }

}

# --------------------------------------------------------
# VM Definitions
# --------------------------------------------------------

$sddcmanager = "vcf-m01-sddc01"
$nsxmanager = "vcf-m01-nsx01"
$nsxedge1 = "edge01a"
$nsxedge2 = "edge01b"
$vcfoperations = "vcf-ops-a01"
$vcfoperationsft = "vcf-fm-a01"
$vcflogs = "vcf-logs-a01"
$vcfopscol = "vcf-oc-a01"
$vcfautomation = "vcf-au-node-d9db2"
# --------------------------------------------------------
# STARTUP ORDER
# --------------------------------------------------------

# 1 - SDDC Manager
Start-VMOrdered -VMName $sddcmanager -WaitSeconds 300

# 2 - NSX Manager Cluster
Start-VMOrdered -VMName $nsxmanager -WaitSeconds 240


# 3 - NSX Edge Nodes
Start-VMOrdered -VMName $nsxedge1 -WaitSeconds 180
Start-VMOrdered -VMName $nsxedge2 -WaitSeconds 180

# 3 - VCF Operations
Start-VMOrdered -VMName $vcfoperations -WaitSeconds 180

# 4 - VCF Operations Fleet Management
Start-VMOrdered -VMName $vcfoperationsft -WaitSeconds 180

# 5 - VCF Operations for Logs
Start-VMOrdered -VMName $vcflogs -WaitSeconds 180

# 6 - VCF Operations Collector
Start-VMOrdered -VMName $vcfopscol  -WaitSeconds 180

# 7 - VCF Automation
Start-VMOrdered -VMName $vcfautomation -WaitSeconds 240

# --------------------------------------------------------

Write-Host "VCF Startup sequence completed" -ForegroundColor Green

Disconnect-VIServer -Confirm:$false