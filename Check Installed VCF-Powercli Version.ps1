$installedVCFPowercli   = Get-InstalledModule VCF.PowerCLI -ErrorAction SilentlyContinue
$installedVMwarePowercli   = Get-InstalledModule VMware.PowerCLI -ErrorAction SilentlyContinue
$latestVCFPowercli    = Find-Module VCF.PowerCLI -ErrorAction SilentlyContinue
$latestVMwarePowercli =  Find-Module VMware.PowerCLI -ErrorAction SilentlyContinue
$OldModules = Get-InstalledModule VMware.* -ErrorAction SilentlyContinue
$OldModules += Get-InstalledModule VCF.* -ErrorAction SilentlyContinu | Where-Object {[version]$_.Version -lt $latestVCF.Version}

Function Uninstall-OldPowercliEditons {
$Total = $OldModules.Count
$Index = 0
foreach ($Module in $OldModules) {
    $Index++
    $Percent = ($Index / $Total) * 100

    Write-Progress `
        -Activity "Delete old PowerCLI version" `
        -Status "Uninstall version $($Module.Version) ($Index from $Total)" `
        -PercentComplete $Percent

    try {
        Uninstall-Module -Name $Module.name -AllVersions -Force  # -ErrorAction silentlycontinue -ErrorVariable +err
        Write-Host "🗑 Removed: PowerCLI $($Module.Name) with $($Module.Version)"
    }
    catch {
        Write-Error "❌ Error with deleting PowerCLI $($Module.Version): $_"
    }

    Start-Sleep -Seconds 1
  }
}

if (-not ($installedVMwarePowercli -or $installedVCFPowercli -or $OldModules )) {
    "❌ VCF.PowerCLI is not installed"
    Install-Module VCF.PowerCLI -AllowClobber  -Scope CurrentUser # -SkipPublisherCheck
}
elseif ([version]$installedVCFPowercli.Version -eq [version]$latestVCFPowercli.Version) {
    "✅ VCF PowerCLI is up-to-date ($($installed.Version))"
}
elseif ($installedVMwarePowercli) {
    "⬆ VMware Powercli is installed needed upgrade to VCF Powercli"
    Uninstall-OldPowercliEditons
    Write-Host "Uninstall is succes vol"  -ForegroundColor Yellow
    Install-Module VCF.PowerCLI -AllowClobber  -Scope CurrentUser # -SkipPublisherCheck
    Write-Host "Install VCF Powercli is succes" -ForegroundColor Green
}
else {
    "⬆ VCF Powercli Update beschikbaar $($latestVCFPowercli.Version)"
    Uninstall-OldPowercliEditons
    Write-Host "Uninstall is succes" -ForegroundColor Yellow
    Update-Module -Name VCF.PowerCLI -Force
    Write-Host "Update is succes vol" -ForegroundColor Green
}