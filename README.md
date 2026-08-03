# LogRotationHandler
The Log Rotation Handler is a centrally maintained PowerShell script used to rotate syslog-related folders from Azure-hosted Windows virtual machines and upload staged files to Azure Blob Storage.

1	-	Stops syslog service/processes.

			If not stopped within 2 minutes, Force stops if not completely stopped.
			
2 	-	Moves active log files from configured source folders into a timestamped staging directory

3 	-	Restarts syslog

4 	-	Uploads the staged files to Azure Blob Storage using Managed Identity.
