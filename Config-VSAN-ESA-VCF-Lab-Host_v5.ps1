Clear-Host
# Begin Settings to Change
$vmhost_name = read-host "What is the name of the host without FQDN"
$vmhost_temp_ip = read-host "What is the IP of the Host"
$dns_domain = read-host "What is the domain name"


if ([string]::IsNullOrEmpty($vmhost_name)) {
    Write-Host "Hostname is empty" -ForegroundColor Red
    Break
}
elseif ([string]::IsNullOrEmpty($vmhost_temp_ip)) {
    Write-Host "IP is empty" -ForegroundColor Red
    Break
}
elseif ([string]::IsNullOrEmpty($dns_domain)) {
    Write-Host "Domain name is empty" -ForegroundColor Red
    Break
}

# General Settings
$MiniforumServer="AMD EPYC Ryzen 9 9955HX" # AMD EPYC Ryzen 9 7945HX or AMD EPYC Ryzen 9 7940HX or AMD EPYC Ryzen 9 9955HX
$TargetMtu="9000"
$ntpserver="213.75.85.246"
$vSANESAMockVib = ".\nested-vsan-esa-mock-hw.vib"
$SynologyNFSVib = ".\Synology_bootbank_Synology-ESX-syno-nfs-vaai-plugin_2.0-1109.vib"
$RealtekNetVib  = ".\vmw_bootbank_if-re_1.101.01-5vmw.800.1.0.20613240.vib"
$AMDterminalVib  = ".\vmw_bootbank_smntemp_910.1.0.0005-5vmw.803.0.0.24022510.vib"


# Location
switch ((get-host).Name) { 
    'Windows PowerShell ISE Host' { $vib_folder = $psISE.CurrentFile.FullPath -replace ($psISE.CurrentFile.DisplayName,"") }
    'ConsoleHost' { $vib_folder = $myInvocation.MyCommand.Path -replace ($myInvocation.MyCommand.Name,"")  }
    'Visual Studio Code Host'{ $vib_folder = $psEditor.GetEditorContext().CurrentFile.Path | Split-Path  }
}

# Ignore Self Signed Cert
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

# Go to the Packer folder
Set-Location $vib_folder

function Connect-ESXiSSH {
    param(
        [Parameter(Mandatory)]
        [VMware.VimAutomation.ViCore.Impl.V1.Inventory.VMHostImpl]$VMHost,

        [Parameter(Mandatory)]
        [pscredential]$Credential
    )

    try {
        Write-Host "Checking SSH service on $($VMHost.Name)..." -ForegroundColor Cyan

        $sshService = Get-VMHostService -VMHost $VMHost |
            Where-Object { $_.Key -eq "TSM-SSH" }

        if (-not $sshService) {
            throw "SSH service (TSM-SSH) not found on $($VMHost.Name)"
        }

        if (-not $sshService.Running) {
            Write-Host "Starting SSH on $($VMHost.Name)..." -ForegroundColor Yellow
            Start-VMHostService -HostService $sshService -Confirm:$false | Out-Null
        }
        else {
            Write-Host "SSH already enabled on $($VMHost.Name)" -ForegroundColor Green
        }

        Write-Host "Creating SSH session to $($VMHost.Name)..." -ForegroundColor Cyan

        $session = New-SSHSession `
            -ComputerName $VMHost.Name `
            -Credential $Credential `
            -Force `
            -AcceptKey:$true

        Write-Host "SSH connection successful: $($VMHost.Name)" -ForegroundColor Green
N
        return $session
    }
    catch {
        Write-Host "Failed to connect to $($VMHost.Name): $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Ensure-VMhostConnection {
    param(
        [string]$vmhost,
        [pscredential]$Credential,
        [int]$MaxRetries = 3
    )

    $attempt = 1

    while ($attempt -le $MaxRetries) {
        try {
            $existing = $global:DefaultVIServers | Where-Object {
                $_.Name -eq $vmhost -and $_.IsConnected
            }

            if ($existing) {
                Write-Host "Already connected to $vmhost" -ForegroundColor Green
                return $existing
            }

            Write-Host "Attempt $attempt/$MaxRetries connecting to $vmhost..." -ForegroundColor Yellow

            $connection = Connect-VIServer `
                -Server $vmhost `
                -Credential $Credential `
                -ErrorAction Stop

            Write-Host "Connected successfully" -ForegroundColor Green
            return $connection
        }
        catch {
            Write-Host "Connection attempt $attempt failed: $($_.Exception.Message)" -ForegroundColor Red
            Start-Sleep -Seconds 5
            $attempt++
        }
    }

    throw "Unable to connect to $vmhost after $MaxRetries attempts."
    break
}

# Main Script

$ESXCreds = Get-Credential -UserName root -Message "Fill in creds of $vmhost_name"

Ensure-VMhostConnection -vmhost $vmhost_temp_ip -Credential $ESXCreds

$vmhost = "$vmhost_name.$dns_domain"

# Disable IPv6
$esxcli = Get-EsxCli -VMHost $vmhost_temp_ip -V2
$argument = $esxcli.system.module.parameters.set.CreateArgs()
$argument.module = "tcpip4"
$argument.parameterstring = "ipv6=0"
$esxcli.system.module.parameters.set.Invoke($argument)

# Set Fixt DNS enz
$vmHostNetworkInfo = Get-VmHostNetwork -Host $vmhost_temp_ip
Set-VMHostNetwork -Network $vmHostNetworkInfo -DomainName $dns_domain -HostName $vmhost_name

# DNS Name to IP (Not Used)
# $ip = [System.Net.Dns]::GetHostaddresses($vmhost) | Select-Object IPAddressToString 
# $vmhost_ip = $ip.IPAddressToString

$vmhost = Get-VMHost 

# Rename local datastore
Get-VMhost $vmhost | Get-Datastore -Name datastore* | Set-Datastore -Name "$vmhost_name-datastore"

# NTP
try {
Add-VmHostNtpServer -NtpServer $ntpserver -vmhost $vmhost
#Start NTP client service and set to automatic
Get-VmHostService -VMHost $vmhost | Where-Object {$_.key -eq "ntpd"} | Set-VMHostService -policy "on"
Get-VmHostService -VMHost $vmhost | Where-Object {$_.key -eq "ntpd"} | Start-VMHostService -Confirm:$false
}
catch {
   Write-Host "NTP Settings are already set $vmHost" -ForegroundColor Yellow 
}


Set-VMHost -VMHost $vmhost -State Maintenance -Confirm:$false

do {
    Start-Sleep -Seconds 10
    $state = (Get-VMHost $vmhost).ConnectionState
    Write-Host "Current state: $state"
}
until ($state -eq "Maintenance")


# ---- MTU ----
try {
Write-Host "`n  [*] Setting vSwitch0 MTU to $TargetMtu..." -ForegroundColor Cyan
$vSwitch = Get-VirtualSwitch -VMHost $vmhost_temp_ip -Name "vSwitch0" -ErrorAction Stop
Set-VirtualSwitch -VirtualSwitch $vSwitch -Mtu $TargetMtu -Confirm:$false | Out-Null
Write-Host "  [+] vSwitch0 MTU set to $TargetMtu" -ForegroundColor Green
} catch {
    Write-Host "❌ MTU Settings are not set $vmHost" -ForegroundColor Red
}

# Datastore Vib Settings
$esxDatastore = "${vmhost_name}-datastore"
$vmstorePath = "vmstores:\$vmhost@443\ha-datacenter\$esxDatastore"


# === vSAN ESA Mock VIB ===
Write-Host "Are you want to install vSAN ESA Mock VIB? (Y/N)" 
$answer = Read-Host 
if ($answer -match '^[Yy]$') {
# === VIB vSAN ESA Mock Deployment ===
    $vibPath = "/vmfs/volumes/$esxDatastore/nested-vsan-esa-mock-hw.vib"
    Write-Host "Connecting to $vmhost for VIB installation..." -ForegroundColor Cyan
    try {
        $esxcli = Get-EsxCli -VMHost $vmhost -V2
        Write-Host "Uploading '$vSANESAMockVib' to $vmstorePath ..."
        Copy-DatastoreItem -Item $vSANESAMockVib -Destination $vmstorePath -Force -ErrorAction Stop 

        Write-Host "Setting acceptance level to CommunitySupported ..."
        $esxcli.software.acceptance.set.Invoke(@{ level = "CommunitySupported" })

        Write-Host "Installing VIB ..."
        $installParams = @{ viburl = $vibPath; nosigcheck = $true }
        $result = $esxcli.software.vib.install.Invoke($installParams)

        Write-Host "✅ VIB installation result: $($result.Message)" -ForegroundColor Green
    } catch {
        Write-Host "❌ EsxCLI operations failed on $VMName ($vmhost): $_" -ForegroundColor Red
    }

    # vSAN Optimizations, stops guest VM latency during vSAN resync when using 10Gb on ESA 
    # NOT required when using 25Gbps networking
    try {
        $session = Connect-ESXiSSH -VMHost $vmhost -Credential $ESXCreds
        # vSAN Cluster Compliance # https://knowledge.broadcom.com/external/article/372309/workaround-to-reduce-impact-of-resync-tr.html
        # esxcfg-advcfg -s 1 /VSAN/DOMNetworkSchedulerThrottleComponent
        $vSANClusterCompliance = "esxcli system settings advanced set -i 1 -o /VSAN/DOMNetworkSchedulerThrottleComponent"
        Invoke-SSHCommand -SSHSession $session -Command $vSANClusterCompliance
        # Remove-SSHSession -SSHSession $session
        Write-Host "✅ vSAN Settings on Host on $vmHost" -ForegroundColor Green
        } catch {
        Write-Host "❌ vSAN Settings is not set on $vmHost" -ForegroundColor Red
    }
}

# === Synology VIB ===
Write-Host "Are you want to install Synology VIB? (Y/N)" 
$answer = Read-Host
if ($answer -match '^[Yy]$') {    
    # === Synology Vib Deployment ===
        $vibPath = "/vmfs/volumes/$esxDatastore/Synology_bootbank_Synology-ESX-syno-nfs-vaai-plugin_2.0-1109.vib"
        Write-Host "Connecting to $vmhost for VIB installation..." -ForegroundColor Cyan
    try {
        $esxcli = Get-EsxCli -VMHost $vmhost -V2
        Write-Host "Uploading '$SynologyNFSVib' to $vmstorePath ..."
        Copy-DatastoreItem -Item $SynologyNFSVib -Destination $vmstorePath -Force -ErrorAction Stop 

        # Skip ivm Already Done
        #Write-Host "Setting acceptance level to CommunitySupported ..."
        #$esxcli.software.acceptance.set.Invoke(@{ level = "CommunitySupported" })

        Write-Host "Installing VIB ..."
        $installParams = @{ viburl = $vibPath; nosigcheck = $true }
        $result = $esxcli.software.vib.install.Invoke($installParams)

        Write-Host "✅ VIB installation result: $($result.Message)" -ForegroundColor Green
    } catch {
        Write-Host "❌ EsxCLI operations failed on $VMName ($vmhost): $_" -ForegroundColor Red
    }
}

# Are you running a MS-A2 host & Disable apichv
Write-Host "Are you running a Miniforum MS-A2 host? (Y/N)" -foreground Yellow
$answer = Read-Host
if ($answer -match '^[Yy]$') {
    try {
    $session = Connect-ESXiSSH -VMHost $vmhost -Credential $ESXCreds
    
    # Workaround required for AMD Ryzen-based CPU to allow NVMe Tiering
    $GenerateDisableCommand = "echo 'monitor_control.disable_apichv ='TRUE'' >> /etc/vmware/config"
    Invoke-SSHCommand -SSHSession $session -Command $GenerateDisableCommand

    # NSX Edge workaround for non-EPYC systems
    $GenerateDisableCommand2 = "echo 'cpuid.brandstring = '$MiniforumServer'' >> /etc/vmware/config"
    Invoke-SSHCommand -SSHSession $session -Command $GenerateDisableCommand2


    ## Fix some performance issues with intel X710 hardware offload
    $GenerateDisableCommand3 = "esxcli system settings advanced set -i 0 -o /Net/TcpipDefLROEnabled"
    Invoke-SSHCommand -SSHSession $session -Command $GenerateDisableCommand3
    $GenerateDisableCommand4 = "esxcli system settings advanced set -o /Net/UseHwTSO -i 0"
    Invoke-SSHCommand -SSHSession $session -Command $GenerateDisableCommand4

    # Performance tweak for zen5 processor architecture
    $GenerateDisableCommand5 = "esxcli system settings kernel set -s entropySources -v 1"
    Invoke-SSHCommand -SSHSession $session -Command $GenerateDisableCommand5

    Write-Host "✅ VM Settings are deployed on $vmHost " -ForegroundColor Green
    } catch {
      Write-Host "❌ VM Settings are NOT deployed on $vmHost" -ForegroundColor Red
    }
}

# Memory Optimalisation
try {
    $session = Connect-ESXiSSH -VMHost $vmhost -Credential $ESXCreds
    
    # Enable inter vm transparent memory sharing
    # https://knowledge.broadcom.com/external/article/323624/additional-transparent-page-sharing-mana.html
    $GenerateDisableCommand6 = "esxcli system settings advanced set -o /Mem/ShareForceSalting -i 0"
    Invoke-SSHCommand -SSHSession $session -Command $GenerateDisableCommand6
    # Activate backing of guest large pages with host large pages. 
    # Reduces TLB misses and improves performance in server workloads that use guest large pages
    $GenerateDisableCommand7 = "esxcli system settings advanced set -o /Mem/AllocGuestLargePage -i 0"
    Invoke-SSHCommand -SSHSession $session -Command $GenerateDisableCommand7
  
    Write-Host "✅ Memory Optimalisation Settings are deployed on $vmHost " -ForegroundColor Green
} catch {
    Write-Host "❌ Memory Optimalisation Settings are NOT deployed on $vmHost" -ForegroundColor Red
}

# === AMD Zen4/Zen5 IPMI Thermal Driver ===
# https://williamlam.com/2026/05/amd-zen4-zen5-ipmi-thermal-driver-for-esx-fling.html
Write-Host "Do you want to install Miniforum MS-A2 Temp? (Y/N)" -foreground Yellow
$answer = Read-Host 
if ($answer -match '^[Yy]$') {
    $vibPath = "/vmfs/volumes/$esxDatastore/vmw_bootbank_smntemp_910.1.0.0006-5vmw.803.0.0.24022510.vib"
    Write-Host "Connecting to $vmhost for VIB installation..." -ForegroundColor Cyan
    try {
            $esxcli = Get-EsxCli -VMHost $vmhost -V2
            Write-Host "Uploading '$AMDterminalVib' to $vmstorePath ..."
            Copy-DatastoreItem -Item $AMDterminalVib -Destination $vmstorePath -Force -ErrorAction Stop 

            Write-Host "Setting acceptance level to CommunitySupported ..."
            $esxcli.software.acceptance.set.Invoke(@{ level = "CommunitySupported" })

            Write-Host "Installing VIB ..."
            $installParams = @{ viburl = $vibPath; nosigcheck = $true }
            $result = $esxcli.software.vib.install.Invoke($installParams)

             Write-Host "✅ VIB installation result: $($result.Message)" -ForegroundColor Green
        } catch {
        Write-Host "❌ EsxCLI operations failed on $VMName ($vmhost): $_" -ForegroundColor Red
        }

    }
Else {
    Write-Host "Skipped because host is not MS-A2 host"
}

# Enable Memory Tiering
Write-Host "Are you want to enable Memory Tiering? (Y/N)" -foreground Yellow
$answer = Read-Host 
if ($answer -match '^[Yy]$') {
        Write-Output "Fetching disks for host: $($vmHost.Name)"
        $esxcli = Get-EsxCli -VMHost $vmhost -V2
        $datastores = Get-Datastore -VMHost $vmhost

        # Get boot devices / OS partitions
        $disks = Get-ScsiLun -VMHost $vmhost -LunType disk | Where-Object { $_.Vendor -like "*NVMe*" } | ForEach-Object {

            $lun = $_

            # Check partitions
            $partitions = $esxcli.storage.core.device.partition.list.Invoke(@{
            device = $lun.CanonicalName
            })

            # Check VMFS usage
            $inVMFS = $datastores | Where-Object {$_.ExtensionData.Info.Vmfs -and $_.ExtensionData.Info.Vmfs.Extent.DiskName -contains $lun.CanonicalName }

            # Check ESXi boot/system partitions
            $isSystemDisk = $partitions | Where-Object {$_.Type -match "EFI|bootbank|OSDATA|Diagnostic" }

            [PSCustomObject]@{
                CanonicalName = $lun.CanonicalName
                RuntimeName   = $lun.RuntimeName
                Model         = $lun.Model
                Vendor        = $lun.Vendor
                HasPartitions = ($partitions.Count -gt 0)
                InVMFS        = [bool]$inVMFS
                IsSystemDisk  = [bool]$isSystemDisk
                InUse         = (
                    ($partitions.Count -gt 0) -or
                    [bool]$inVMFS -or
                    [bool]$isSystemDisk
                )
            }
            } | Where-Object {
                $_.InVMFS -eq $false
        }

        if (-not $disks) {
            Write-Warning "No NVMe disks found on host $($vmHost.Name)"
            continue
        }

        # Display disk selection table
        $selectedDisK =  $disks | Out-GridView -OutputMode Single -Title "Select Memory Tier Disk"

        # Get selected disk
         $devicePath = "/vmfs/devices/disks/$($selectedDisk.CanonicalName)"

        # Confirm action
        Write-Output "Selected disk: $($selectedDisk.CanonicalName) on host $($vmHost.Name)"
        $confirm = Read-Host -Prompt "Confirm NVMe Memory Tier configuration? This may erase data (Y/N)"
        if ($confirm -match '^[Yy]$') {
           
            Write-Host "Are you want to running ESX 9.1? (Y/N)" -foreground Yellow
            $answer = Read-Host 
            if ($answer -match '^[Yy]$') {
                try {
                $session = Connect-ESXiSSH -VMHost $vmhost -Credential $ESXCreds
   
                $GenerateMemoryCommand = "esxcli system settings kernel set -s MemoryTiering -v TRUE"
                Invoke-SSHCommand -SSHSession $session -Command $GenerateMemoryCommand

                $GenerateDiskCommand = "esxcli memtier enable -d $devicePath"
                Invoke-SSHCommand -SSHSession $session -Command $GenerateDiskCommand
                Write-Host "✅ Successfully configured NVMe Memory Tier on host $($vmHost.Name)" -ForegroundColor Green
                } catch {
                Write-Host "❌ Memory Teiring Configration Failed on $vmHost" -ForegroundColor Red
                }
                
            }
            Else{
                try {    
                Write-Host "Your are running ESX 8u3 or 9.0"
                
                $esxcli = Get-EsxCli -VMHost $vmhost -V2
                $arguments = $esxcli.system.tierdevice.create.CreateArgs()
                $arguments.nvmedevice = $devicePath
                $esxcli.system.tierdevice.create.invoke($arguments)
                $esxcli.system.tierdevice.list.invoke()    

                $arguments = $esxcli.system.settings.kernel.set.CreateArgs()
                $arguments.setting = "MemoryTiering"
                $arguments.value = "true"
                $esxcli.system.settings.kernel.set.invoke($arguments)
                Get-VMHost $vmhost | Get-AdvancedSetting -Name "Mem.TierNvmePct" 
                Get-VMHost $vmhost | Get-AdvancedSetting -Name "Mem.TierNvmePct" | Set-AdvancedSetting -value 100 -Confirm:$false
                Write-Host "✅ Successfully configured NVMe Memory Tier on host $($vmHost.Name)" -ForegroundColor Green
                } catch {
                Write-Host "❌ Memory Teiring Configration Failed on $vmHost" -ForegroundColor Red
                }
            }
        }
    }
Else { 
    Write-Output "Configuration cancelled for host $($vmHost.Name)."
}


# VCF 9 Check    
Set-VMHost -VMHost $vmhost -State Connected -Confirm:$false


# Generate new certificate on the ESXi host
try {
    $session = Connect-ESXiSSH -VMHost $vmhost -Credential $ESXCreds
   
    $GenerateCertCommand = "/sbin/generate-certificates"
    Invoke-SSHCommand -SSHSession $session -Command $GenerateCertCommand

    $restartCommand = "/etc/init.d/hostd restart && /etc/init.d/vpxa restart && /etc/init.d/rhttpproxy restart"
    Invoke-SSHCommand -SSHSession $session -Command $restartCommand
    # Remove-SSHSession -SSHSession $session
    Write-Host "✅ New Selfsigned Certificate is generated on $vmHost" -ForegroundColor Green
} catch {
    Write-Host "❌ Selfsigned Certificate is NOT generated on $vmHost" -ForegroundColor Red
    }


Start-Sleep 10

#Reboot Host
$hostrestart="reboot"
Invoke-SSHCommand -SSHSession $session -Command $hostrestart

Start-Sleep 15

do {
    $ping = Test-Connection -ComputerName $vmhost_temp_ip -Count 1 -Quiet

    if ($ping) {
        Write-Host "$vmhost_name responds to ping" -ForegroundColor Green
    }
    else {
        Write-Host "$vmhost_name still offline..." -ForegroundColor Yellow
        Start-Sleep -Seconds 15
    }

} while (-not $ping)

# Disconnect-ViCenter
Disconnect-VIServer * -Confirm:$false | Out-Null
