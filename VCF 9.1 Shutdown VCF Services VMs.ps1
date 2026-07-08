# VCF Services shutdown by Ward Vissers

# Variables
switch ((get-host).Name) { 
    'Windows PowerShell ISE Host' { $vcf_folder = $psISE.CurrentFile.FullPath -replace ($psISE.CurrentFile.DisplayName,"") }
    'ConsoleHost' { $vcf_folder = $myInvocation.MyCommand.Path -replace ($myInvocation.MyCommand.Name,"")  }
    'Visual Studio Code Host'{ $vcf_folder = $psEditor.GetEditorContext().CurrentFile.Path | Split-Path  }
}

# Go to the Packer folder
Set-Location $vcf_folder

$Credential = Get-Credential -UserName "administrator@vsphere.local" -Message "vCenter Login Creds"

 # Shutdown Test Run
.\vcf_services_runtime_shutdown_v2.ps1 -DryRun -NodeIp <your_node_here>  -Credential $Credential
# Shutdown Run
.\vcf_services_runtime_shutdown_v2.ps1 -NodeIp <your_node_here> -Credential $Credential
