# Location
switch ((get-host).Name) { 
    'Windows PowerShell ISE Host' { $folder = $psISE.CurrentFile.FullPath -replace ($psISE.CurrentFile.DisplayName,"") }
    'ConsoleHost' { $folder = $myInvocation.MyCommand.Path -replace ($myInvocation.MyCommand.Name,"")  }
    'Visual Studio Code Host'{ $folder = $psEditor.GetEditorContext().CurrentFile.Path | Split-Path  }
}

Set-Location $folder

.\Set-VcfSftpBackupLocation.ps1 -Component vCenter
.\Set-VcfSftpBackupLocation.ps1 -Component SddcManager
.\Set-VcfSftpBackupLocation.ps1 -Component SddcManagerBackupSchedule
.\Set-VcfSftpBackupLocation.ps1 -Component FleetLifecycle
.\Set-VcfSftpBackupLocation.ps1 -Component FleetBackupSchedule
.\Set-VcfSftpBackupLocation.ps1 -Component All

