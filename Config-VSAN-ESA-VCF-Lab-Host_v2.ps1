Clear
# Begin Settings to Change
$vmhost_name = "demoesx9"
$vmhost_temp_ip = "192.168.150.79"
$dns_domain = "wardhomelab.nl"

# Location
switch ((get-host).Name) { 
    'Windows PowerShell ISE Host' { $vib_folder = $psISE.CurrentFile.FullPath -replace ($psISE.CurrentFile.DisplayName,"") }
    'ConsoleHost' { $vib_folder = $myInvocation.MyCommand.Path -replace ($myInvocation.MyCommand.Name,"")  }
    'Visual Studio Code Host'{ $vib_folder = $psEditor.GetEditorContext().CurrentFile.Path | Split-Path  }
}

# Go to the Packer folder
Set-Location $vib_folder

# General Settings
$ntpserver="nl.pool.ntp.org"
$vSANESAMockVib = "$vib_folder\nested-vsan-esa-mock-hw.vib"
$SynologyNFSVib = "$vib_folder\Synology_bootbank_Synology-ESX-syno-nfs-vaai-plugin_2.0-1109.vib"
$RealtekNetVib = "$vib_folder\vmw_bootbank_if-re_1.101.01-5vmw.800.1.0.20613240.vib"

$ESXCreds = Get-Credential

Connect-VIServer $vmhost_temp_ip -Credential $ESXCreds

$vmhost = "$vmhost_name.$dns_domain"

# Start Fase 1
# Disable IPv6
$esxcli = Get-EsxCli -VMHost $vmhost_temp_ip -V2
$argument = $esxcli.system.module.parameters.set.CreateArgs()
$argument.module = "tcpip4"
$argument.parameterstring = "ipv6=0"
$esxcli.system.module.parameters.set.Invoke($argument)

# Set Fixt DNS enz
$vmHostNetworkInfo = Get-VmHostNetwork -Host $vmhost_temp_ip
Set-VMHostNetwork -Network $vmHostNetworkInfo -DomainName $dns_domain -HostName $vmhost_name

# DNS Name to IP
$ip = [System.Net.Dns]::GetHostaddresses($vmhost) | Select-Object IPAddressToString 
$vmhost_ip = $ip.IPAddressToString

$vmhost = Get-VMHost 

# Rename local datastore
Get-VMhost $vmhost | Get-Datastore -Name datastore* | Set-Datastore -Name "$vmhost_name-datastore"

# NTP
Add-VmHostNtpServer -NtpServer $ntpserver -vmhost $vmhost
#Start NTP client service and set to automatic
Get-VmHostService -VMHost $vmhost | Where-Object {$_.key -eq "ntpd"} | Set-VMHostService -policy "on"
Get-VmHostService -VMHost $vmhost | Where-Object {$_.key -eq "ntpd"} | Start-VMHostService -Confirm:$false

# Datastore Vib Settings
$esxDatastore = "${vmhost_name}-datastore"
$vmstorePath = "vmstores:\$vmhost@443\ha-datacenter\$esxDatastore"

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

# === Synology Vib Deployment ===
    $vibPath = "/vmfs/volumes/$esxDatastore/Synology_bootbank_Synology-ESX-syno-nfs-vaai-plugin_2.0-1109.vib"
    Write-Host "Connecting to $vmhost for VIB installation..." -ForegroundColor Cyan
try {
    $esxcli = Get-EsxCli -VMHost $vmhost -V2
    Write-Host "Uploading '$SynologyNFSVib' to $vmstorePath ..."
    Copy-DatastoreItem -Item $SynologyNFSVib -Destination $vmstorePath -Force -ErrorAction Stop 

    # Skip ivm Already Done
    #EWrite-Host "Setting acceptance level to CommunitySupported ..."
    #$esxcli.software.acceptance.set.Invoke(@{ level = "CommunitySupported" })

    Write-Host "Installing VIB ..."
    $installParams = @{ viburl = $vibPath; nosigcheck = $true }
    $result = $esxcli.software.vib.install.Invoke($installParams)

    Write-Host "✅ VIB installation result: $($result.Message)" -ForegroundColor Green
} catch {
    Write-Host "❌ EsxCLI operations failed on $VMName ($vmhost): $_" -ForegroundColor Red
    }

# === Realtek Vib Deployment ===
    $vibPath = "/vmfs/volumes/$esxDatastore/vmw_bootbank_if-re_1.101.01-5vmw.800.1.0.20613240.vib"
    Write-Host "Connecting to $vmhost for VIB installation..." -ForegroundColor Cyan
try {
    $esxcli = Get-EsxCli -VMHost $vmhost -V2
    Write-Host "Uploading '$RealtekNetVib' to $vmstorePath ..."
    Copy-DatastoreItem -Item $RealtekNetVib -Destination $vmstorePath -Force -ErrorAction Stop 

    # Skip ivm Already Done
    #EWrite-Host "Setting acceptance level to CommunitySupported ..."
    #$esxcli.software.acceptance.set.Invoke(@{ level = "CommunitySupported" })

    Write-Host "Installing VIB ..."
    $installParams = @{ viburl = $vibPath; nosigcheck = $true }
    $result = $esxcli.software.vib.install.Invoke($installParams)

    Write-Host "✅ VIB installation result: $($result.Message)" -ForegroundColor Green
} catch {
    Write-Host "❌ EsxCLI operations failed on $VMName ($vmhost): $_" -ForegroundColor Red
    }

# === Synology Vib Deployment ===
    $vibPath = "/vmfs/volumes/$esxDatastore/vmw_bootbank_if-re_1.101.01-5vmw.800.1.0.20613240.vib"
    Write-Host "Connecting to $vmhost for VIB installation..." -ForegroundColor Cyan
try {
    $esxcli = Get-EsxCli -VMHost $vmhost -V2
    Write-Host "Uploading '$SynologyNFSVib' to $vmstorePath ..."
    Copy-DatastoreItem -Item $SynologyNFSVib -Destination $vmstorePath -Force -ErrorAction Stop 

    # Skip ivm Already Done
    #EWrite-Host "Setting acceptance level to CommunitySupported ..."
    #$esxcli.software.acceptance.set.Invoke(@{ level = "CommunitySupported" })

    Write-Host "Installing VIB ..."
    $installParams = @{ viburl = $vibPath; nosigcheck = $true }
    $result = $esxcli.software.vib.install.Invoke($installParams)

    Write-Host "✅ VIB installation result: $($result.Message)" -ForegroundColor Green
} catch {
    Write-Host "❌ EsxCLI operations failed on $VMName ($vmhost): $_" -ForegroundColor Red
    }

   # vSAN settings 
try {
      Get-VMHostService -VMHost $vmhost | Where-Object {$_.Key -eq "TSM-SSH"} | Start-VMHostService
      $session = New-SSHSession -ComputerName $vmHost -Credential $ESXCreds -Force -AcceptKey:$true
      # vSAN Cluster Compliance # https://knowledge.broadcom.com/external/article/372309/workaround-to-reduce-impact-of-resync-tr.html
      # esxcfg-advcfg -s 1 /VSAN/DOMNetworkSchedulerThrottleComponent
      $vSANClusterCompliance = "esxcli system settings advanced set -i 1 -o /VSAN/DOMNetworkSchedulerThrottleComponent"
      Invoke-SSHCommand -SSHSession $session -Command $vSANClusterCompliance
      # Remove-SSHSession -SSHSession $session
      Write-Host "✅ vSAN Settings on Host on $vmHost" -ForegroundColor Green
} catch {
    Write-Host "❌ vSAN Settings is not set on $vmHost" -ForegroundColor Red
    }

 # Generate new certificate on the ESXi host
try {
      # Get-VMHostService -VMHost $vmhost | Where-Object {$_.Key -eq "TSM-SSH"} | Start-VMHostService
      # $session = New-SSHSession -ComputerName $vmHost -Credential $ESXCreds -Force -AcceptKey:$true
      $GenerateCertCommand = "/sbin/generate-certificates"
      Invoke-SSHCommand -SSHSession $session -Command $GenerateCertCommand

      $restartCommand = "/etc/init.d/hostd restart && /etc/init.d/vpxa restart"
      Invoke-SSHCommand -SSHSession $session -Command $restartCommand
      # Remove-SSHSession -SSHSession $session
      Write-Host "✅ New Selfsigned Certificate is generated on $vmHost" -ForegroundColor Green
} catch {
    Write-Host "❌ Selfsigned Certificate is NOT generated on $vmHost" -ForegroundColor Red
    }

# Are you running a MS-A2 host & Disable apichv
$answer = Read-Host "Are you running a MS-A2 host & Disable apichv? (Y/N)"
if ($answer -match '^[Yy]$') {
    try {
      # Get-VMHostService -VMHost $vmhost | Where-Object {$_.Key -eq "TSM-SSH"} | Start-VMHostService
      # $session = New-SSHSession -ComputerName $vmHost -Credential $ESXCreds -Force -AcceptKey:$true
      $GenerateDisableCommand = "echo 'monitor_control.disable_apichv ='TRUE'' >> /etc/vmware/config"
      Invoke-SSHCommand -SSHSession $session -Command $GenerateDisableCommand
      # Remove-SSHSession -SSHSession $session
      Write-Host "✅ VM Settings are deployed on $vmHost & Rebooted " -ForegroundColor Green
    } catch {
      Write-Host "❌ VM Settings are NOT deployed on $vmHost" -ForegroundColor Red
    }
}
Else {
         Write-Host "Skipped because host is not MS-A2 host"
}


# Enable Memory Tiering
$answer = Read-Host "Are you want to enable Memory Tiering? (Y/N)"
if ($answer -match '^[Yy]$') {
  try {
        Write-Output "Fetching disks for host: $($vmHost.Name)"
        $disks = @($vmHost | Get-ScsiLun -LunType disk | Where-Object { $_.Model -like "*NVMe*" } | Select-Object CanonicalName, Vendor, Model, MultipathPolicy,@{N='CapacityGB';E={[math]::Round($_.CapacityMB/1024,2)}} |  Sort-Object CanonicalName) # Explicit sorting
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
        if ($confirm -ne 'Y') {
            Write-Output "Configuration cancelled for host $($vmHost.Name)."
            continue
        }

        # $esxcli = Get-EsxCli -VMHost $VMHost -V2
        # Note: Verify the correct ESXCLI command for NVMe memory tiering; this is a placeholder
        # Replace with the actual command or API if available    
        $esxcli.system.tierdevice.create.Invoke(@{ nvmedevice = $devicePath }) # Hypothetical command
        Write-Output "NVMe Memory Tier created successfully on host $($VMHost.Name) with disk $DiskPath"
        return $true
        # Configure NVMe Memory Tier
       if ($result) {
             $arguments = $esxcli.system.settings.kernel.set.CreateArgs()
             $arguments.setting = "MemoryTiering"
             $arguments.value = "true"
             $esxcli.system.settings.kernel.set.invoke($arguments)
            Write-Output "Successfully configured NVMe Memory Tier on host $($vmHost.Name)."
        } else {
            Write-Warning "Failed to configure NVMe Memory Tier on host $($vmHost.Name)."
        }
    }
    catch {
       Write-Warning "An error occurred: $_"
    }    
    finally {
      # Disconnect from vCenter
       Disconnect-VIServer * -Confirm:$false -ErrorAction SilentlyContinue
       Write-Output "Disconnected from vCenter Server."
    }
  catch {
    Write-Warning "Failed to create NVMe Memory Tier on host $($VMHost.Name) with disk $DiskPath. Error: $_"
        return $false
  }
}


$hostrestart="reboot"
Invoke-SSHCommand -SSHSession $session -Command $hostrestart

# Disconnect-ViCenter
Disconnect-VIServer * -Confirm:$false | Out-Null