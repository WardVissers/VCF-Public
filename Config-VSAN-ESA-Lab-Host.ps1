Clear
# Begin Script
$vmhost_name = "vcf-w01-esx04"
$vmhost_temp_ip = "192.168.100.13"

# Settings to Change per VMhost
$mgmt_vlan = "100"
$dns_domain = "wardhomelab.nl"
$vmhost_subnetmask = "255.255.255.0"
$ntpserver="nl.pool.ntp.org"
$dnsAddress1 = "192.168.150.5"
$dnsAddress2 = "192.168.100.1"
$vmkernelgateway = "192.168.100.1"
$MockFile = "D:\ISO\VCF9\nested-vsan-esa-mock-hw.vib"

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
Set-VMHostNetwork -Network $vmHostNetworkInfo -DomainName $dns_domain -HostName $vmhost_name -DnsFromDhcp $false -DnsAddress $dnsAddress1.$dnsAddress2 -VMKernelGateway $vmkernelgateway

# DNS Name to IP
$ip = [System.Net.Dns]::GetHostaddresses($vmhost) | Select-Object IPAddressToString 
$vmhost_ip = $ip.IPAddressToString

#Config VMK0
Get-VMHostNetworkAdapter -VMHost $vmhost_temp_ip -Name vmk0 | Set-VMHostNetworkAdapter -IP $vmhost_ip -SubnetMask $vmhost_subnetmask -confirm:$false | Out-Null

Disconnect-VIServer * -Confirm:$false | Out-Null
Connect-VIServer $vmhost -Credential $ESXCreds

$vmhost = Get-VMHost 

# Rename local datastore
Get-VMhost $vmhost | Get-Datastore -Name datastore* | Set-Datastore -Name "$vmhost_name-datastore"

# NTP
Add-VmHostNtpServer -NtpServer $ntpserver -vmhost $vmhost
#Start NTP client service and set to automatic
Get-VmHostService -VMHost $vmhost | Where-Object {$_.key -eq "ntpd"} | Set-VMHostService -policy "on"
Get-VmHostService -VMHost $vmhost | Where-Object {$_.key -eq "ntpd"} | Start-VMHostService -Confirm:$false

  
# === VIB Deployment & vsanmgmtd Restart ===
    $esxDatastore = "${vmhost_name}-datastore"
    $vmstorePath = "vmstores:\$vmhost@443\ha-datacenter\$esxDatastore"
    $vibPath = "/vmfs/volumes/$esxDatastore/nested-vsan-esa-mock-hw.vib"
    Write-Host "Connecting to $vmhost for VIB installation..." -ForegroundColor Cyan
try {
    $esxcli = Get-EsxCli -VMHost $vmhost -V2
    Write-Host "Uploading '$MockFile' to $vmstorePath ..."
    Copy-DatastoreItem -Item $MockFile -Destination $vmstorePath -Force -ErrorAction Stop 

    Write-Host "Setting acceptance level to CommunitySupported ..."
    $esxcli.software.acceptance.set.Invoke(@{ level = "CommunitySupported" })

    Write-Host "Installing VIB ..."
    $installParams = @{ viburl = $vibPath; nosigcheck = $true }
    $result = $esxcli.software.vib.install.Invoke($installParams)

    Write-Host "✅ VIB installation result: $($result.Message)" -ForegroundColor Green
} catch {
    Write-Host "❌ EsxCLI operations failed on $VMName ($vmhost): $_" -ForegroundColor Red
    }

try {
     # Generate new certificate on the ESXi host
      $vmhost | Get-VMHostService | Where-Object {$_.Key -eq "TSM-SSH"} | Start-VMHostService
      $session = New-SSHSession -ComputerName $vmHost -Credential $ESXCreds -Force -AcceptKey:$true
      $GenerateCertCommand = "/sbin/generate-certificates"
      Invoke-SSHCommand -SSHSession $session -Command $GenerateCertCommand

      # vSAN Cluster Compliance # https://knowledge.broadcom.com/external/article/372309/workaround-to-reduce-impact-of-resync-tr.html
      # esxcfg-advcfg -s 1 /VSAN/DOMNetworkSchedulerThrottleComponent
      $vSANClusterCompliance = "esxcli system settings advanced set -i 1 -o /VSAN/DOMNetworkSchedulerThrottleComponent"
      Invoke-SSHCommand -SSHSession $session -Command $vSANClusterCompliance

      $restartCommand = "/etc/init.d/hostd restart && /etc/init.d/vpxa restart"
      Invoke-SSHCommand -SSHSession $session -Command $restartCommand
      $hostrestart="reboot"
      Invoke-SSHCommand -SSHSession $session -Command $hostrestart
      Remove-SSHSession -SSHSession $session
      Write-Host "✅ New Selfsigned Certificate is generated on $vmHost" -ForegroundColor Green
} catch {
    Write-Host "❌ Selfsigned Certificate is NOT generated on $vmHost" -ForegroundColor Red
    }

# Disconnect-ViCenter
Disconnect-VIServer * -Confirm:$false | Out-Null