# LogRotationHandler-Enhanced!
The Log Rotation Handler is a centrally maintained PowerShell script used to rotate syslog-related folders from Azure-hosted Windows virtual machines and upload staged files to Azure Blob Storage.
1	-	Stops syslog service/processes. If not stopped within 2 minutes, Force stops if not completely stopped.
2 	-	Moves active log files from configured source folders into a timestamped staging directory
        Folders Included are based on the Temp directory location (EG D or E respectively)
		"syslogd",
        "ReportedProblems",
        "CosmoDesigner",
        "CrashDumps",
        "IIS"
3 	-	Restarts syslog
4 	-	Uploads the staged files to Azure Blob Storage using Managed Identity.

# Enhancements Requested (So Far)
*	Implement Task Scheduler Generator from Allans work
*	DesignerLogs - Add options for adding compression
*	If not installed it will install on setup in the software folder:
		AzCopy
		7zip
 	
# USAGE+DEBUG
	~ To Install
		.\LogRotationHandler.ps1 -StorageAccountName "<storage-account-name>" -ContainerName "<container-name>" -Install
	~ To UnInstall
		.\LogRotationHandler.ps1 -StorageAccountName "<storage-account-name>" -ContainerName "<container-name>" -Uninstall
	~ Task Scheduled - EXAMPLE
		powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\software\LogRotationHandler.ps1" -StorageAccountName "<storage-account-name>" -ContainerName "<container-name>" -RemoveStagingAfterUpload
    ~ Run local - EXAMPLE
		.\LogRotationHandler.ps1 -StorageAccountName "<storage-account-name>" -ContainerName "<container-name>" -RemoveStagingAfterUpload
	~ To Debug add to the CLI - EXAMPLE
		*> "C:\software\LogRotationHandler.log"
