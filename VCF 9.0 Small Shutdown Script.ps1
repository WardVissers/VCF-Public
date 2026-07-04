# --------------------------------------------------------
# VMware Cloud Foundation Shutdown Script
# Author: PowerCLI
# Stops VMs in reverse dependency order
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

# Function to shutdown VM and wait until powered off
function Stop-VMOrdered {
    param(
        [string]$VMName,
        [int]$TimeoutSeconds = 600
    )

    Write-Host "---------------------------------------"
    Write-Host "Stopping VM: $VMName"

    try {
        $vm = Get-VM -Name $VMName -ErrorAction Stop
    }
    catch {
        Write-Warning "VM $VMName not found, skipping..."
        return
    }

    if ($vm.PowerState -eq "PoweredOff") {
        Write-Host "$VMName already powered off"
        return
    }

    # Try graceful shutdown if VMware Tools is running
    if ($vm.ExtensionData.Guest.ToolsRunningStatus -eq "guestToolsRunning") {
        Write-Host "Attempting graceful shutdown via VMware Tools..."
        Shutdown-VMGuest -VM $vm -Confirm:$false
    }
    else {
        Write-Warning "VMware Tools not running, skipping graceful shutdown"
    }

    # Wait loop
    $elapsed = 0
    $interval = 10

    while ($elapsed -lt $TimeoutSeconds) {
        $vm = Get-VM -Name $VMName

        if ($vm.PowerState -eq "PoweredOff") {
            Write-Host "$VMName is powered off"
            return
        }

        Start-Sleep -Seconds $interval
        $elapsed += $interval
    }

    # Fallback: force power off
    Write-Warning "Timeout reached, forcing power off for $VMName"
    Stop-VM -VM $vm -Kill -Confirm:$false
}

Function Get-VsanClusterShutdownPrecheckResults {
<#
    .NOTES
    ===========================================================================
     Created by:    William Lam
     Blog:          www.williamlam.com
        ===========================================================================
    .DESCRIPTION
        This function demonstrates the use of vSAN Management API to retrieve
        the "clusterPowerOffPrecheck" Perspective results
    .PARAMETER Cluster
        The name of a vSAN Cluster
    .EXAMPLE
        Get-VsanClusterShutdownPrecheckResults -Cluster VCF-Mgmt-Cluster
#>
    param(
        [Parameter(Mandatory=$true)][String]$Cluster
    )
    $vchs = Get-VSANView -Id "VsanVcClusterHealthSystem-vsan-cluster-health-system"
    $cluster_view = (Get-Cluster -Name $Cluster).ExtensionData.MoRef
    $results = $vchs.VsanQueryVcClusterHealthSummary($cluster_view,$null,$null,$false,$null,$null,'clusterPowerOffPrecheck',$null,$null)
    $shutdownGroupTests = $results.Groups | where {$_.GroupId -eq "com.vmware.vsan.health.test.clusterpower"}

    $vmsNotShutdown = @()
    if($shutdownGroupTests.GroupHealth -eq "red") {
        $shutdownGroupTest = $shutdownGroupTests.GroupTests | where {$_.TestId -eq "com.vmware.vsan.health.test.allvmsshutdown"}
        if($shutdownGroupTest.TestHealth -eq "red") {
            $testDetailValues = $shutdownGroupTest.TestDetails.Rows.Values
            foreach ($testDetailValue in $testDetailValues) {
                $vmMoref = $testDetailValue.replace("mor:ManagedObjectReference:VirtualMachine:","")

                $vm = New-Object VMware.Vim.ManagedObjectReference
                $vm.Type = "VirtualMachine"
                $vm.Value = $vmMoref

                $vmsNotShutdown += (Get-View $vm).Name
            }
        }
    }
    Write-Host
    $vmsNotShutdown | Sort-Object
    foreach ($vm in $vmsNotShutdown){
        Stop-VMOrdered -VMName $vm
    }
    Write-Host
}

# --------------------------------------------------------
# VM Definitions
# --------------------------------------------------------

$managementcluster = "vcf-m01-cl01"
$vcenter         = "vcf-m01-vc01"
$sddcmanager     = "vcf-m01-sddc01"
$nsxmanager      = "vcf-m01-nsx01"
$nsxedge1        = "edge01a"
$nsxedge2        = "edge01b"
$vcfoperations   = "vcf-ops-a01"
$vcfoperationsft = "vcf-fm-a01"
$vcflogs         = "vcf-logs-a01"
$vcfopscol       = "vcf-oc-a01"
$vcfautomation   = "vcf-au-node-d9db2"

# --------------------------------------------------------
# SHUTDOWN ORDER (REVERSED)
# --------------------------------------------------------

# 1 - VCF Automation
Stop-VMOrdered -VMName $vcfautomation

# 2 - VCF Operations Collector
Stop-VMOrdered -VMName $vcfopscol

# 3 - VCF Operations for Logs
Stop-VMOrdered -VMName $vcflogs

# 4 - VCF Operations Fleet Management
Stop-VMOrdered -VMName $vcfoperationsft

# 5 - VCF Operations
Stop-VMOrdered -VMName $vcfoperations

# 6 - NSX Edge Nodes
Stop-VMOrdered -VMName $nsxedge2
Stop-VMOrdered -VMName $nsxedge1

# 7 - NSX Manager
Stop-VMOrdered -VMName $nsxmanager

# 8 - SDDC Manager (last)
Stop-VMOrdered -VMName $sddcmanager

# --------------------------------------------------------

Write-Host "VCF Shutdown sequence completed except vCenter & Hosts" -ForegroundColor Yellow



$vSANClusterEnabled = Get-Cluster $managementcluster | Select Name, VsanEnabled

if ($vSANClusterEnabled.VsanEnabled = $true) {
        Write-Host "Cluster $($vSANClusterEnabled.Name) has vSAN enabled" -ForegroundColor Yellow
        Get-VsanClusterShutdownPrecheckResults -Cluster $managementcluster
        Stop-VsanCluster -Cluster $vSANClusterEnabled
        Write-Host "vSAN Cluster $($vSANClusterEnabled.Name) Has Shuttign Down" -ForegroundColor Green
        # Do something here
    }
else {
    Write-Host "ESX Hosts with NFS or Fibre Channel Storage in the Management Domain is not shutting Down" -ForegroundColor Yellow
    Stop-VMOrdered -VMName $vCenter
}


# Disconnect vCenter
Disconnect-VIServer -Confirm:$false