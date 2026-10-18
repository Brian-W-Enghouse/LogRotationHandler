# LogRotationHandler-Enhanced!

The Log Rotation Handler is a centrally maintained PowerShell script used to rotate syslog-related folders from Azure-hosted Windows virtual machines and upload staged files to Azure Blob Storage.

1	-	Stops syslog service/processes.
		If not stopped within 2 minutes, Force stops if not completely stopped.

2 	-	Moves active log files from configured source folders into a timestamped staging directory

        Folders Included are based on the Temp directory location (EG D or E respectively)
		"syslogd",
        "ReportedProblems",
        "CosmoDesigner",
        "CrashDumps",
        "IIS"
		
3 	-	Restarts syslog

4 	-   Compress only folders selected by switch -CompressFolders.
		If not supplied, no compression is performed.  Compression is done using 7zip and the 7zr.exe binary.

5 	-   Uploads the staged files to Azure Blob Storage using Managed Identity.

6   -   Deletes the local staging folder after successful compression and upload if -RemoveStagingAfterUpload is supplied.
		If not supplied, the local staging folder is retained for troubleshooting.
		
# Enhancements Completed! (So Far) - DONE READY FOR LIVE
*	Compression Enabled! - Framework uses a "Selector" method so all folders included in secondary list will compress and include in standard archiving process - **DONE**
*	Compression? - DesignerLogs - Installer adds "CosmoDesigner" for compression to task - **DONE**
*	Implement Task Scheduler Generator from Allans work - ** DONE**
*	Utilities/Install from single script eg setup in the software folder: AzCopy + 7zip - **DONE**
    
# USAGE+DEBUG
	~ To Install
		.\LogRotationHandler.ps1 -StorageAccountName "<storage-account-name>" -ContainerName "<container-name>" -Install
	~ To UnInstall
		.\LogRotationHandler.ps1 -StorageAccountName "<storage-account-name>" -ContainerName "<container-name>" -Uninstall
	~ Task Scheduled - EXAMPLE
		powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\software\LogRotationHandler.ps1" -StorageAccountName "<storage-account-name>" -ContainerName "<container-name>" -RemoveStagingAfterUpload -CompressFolders "CosmoDesigner"
    ~ Run local - EXAMPLE
		.\LogRotationHandler.ps1 -StorageAccountName "<storage-account-name>" -ContainerName "<container-name>" -RemoveStagingAfterUpload
    ~ Compress Folders - EXAMPLE - Only CosmoDesigner enabled by Default during install
        .\LogRotationHandler.ps1 -StorageAccountName "<storage-account-name>" -ContainerName "<container-name>" -RemoveStagingAfterUpload -CompressFolders "CosmoDesigner,IIS,ReportedProblems,CrashDumps"
	~ To Debug add to the CLI - EXAMPLE
		*> "C:\software\LogRotationHandler.log"
