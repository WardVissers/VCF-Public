function ConvertTo-DecimalIP {
    param ([string]$ip)
    $parts = $ip.Split('.') | ForEach-Object { [int]$_ }
    return ($parts[0] -shl 24) + ($parts[1] -shl 16) + ($parts[2] -shl 8) + $parts[3]
}

function ConvertTo-DottedIP {
    param ([int]$intIP)
    $part1 = ($intIP -shr 24) -band 0xFF
    $part2 = ($intIP -shr 16) -band 0xFF
    $part3 = ($intIP -shr 8) -band 0xFF
    $part4 = $intIP -band 0xFF
    return "$part1.$part2.$part3.$part4"
}

$zone = "testlab.nl"
$startip = "192.168.200.10"


$dnsrecords = "vcf-m01-cb01","vcf-m01-sddcm01","vcf-m01-esx01","vcf-m01-esx02","vcf-m01-esx03","vcf-m01-esx04","vcf-w01-esx02","vcf-w01-esx03","vcf-w01-esx04","vcf-w01-esx04","vcf-m01-nsx01a","vcf-m01-nsx01b","vcf-m01-nsx01c","vcf-m01-nsx01","vcf-w01-nsx01a","vcf-w01-nsx01b","vcf-w01-nsx01c","vcf-w01-nsx01","vcf-m01-vc01","vcf-w01-vc01"
$count = $dnsrecords.count
# Convert start IP to decimal
$decimalIP = ConvertTo-DecimalIP $startIP
$i = 0

# Loop and print incremented IPs
foreach ($dnsrecord in $dnsrecords) {
  $i -lt 
  $count; 
  $i++
  $currentDecimalIP = $decimalIP + $i
  $currentIP = ConvertTo-DottedIP $currentDecimalIP
  Add-DnsServerResourceRecordA -Name $dnsrecord -ZoneName $zone -AllowUpdateAny -IPv4Address $currentIP -CreatePtr  
  Write-Output "DNS record $dnsrecord in $zone with $currentIP is created" -ForegroundColor Green
}
