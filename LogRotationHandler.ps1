<#
.DESCRIPTION
	Brians Log Rotation Handler Script - Version 0.9
	Process Overview
	1	-	Stops syslog service/processes.
			If not stopped within 2 minutes, Force stops if not completely stopped.
	2 	-	Moves active log files from configured source folders into a timestamped staging directory
	3 	-	Restarts syslog
	4 	-	Uploads the staged files to Azure Blob Storage using Managed Identity.

.REQUIREMENTS
    ~ AzCopy installed and available in PATH, or configure $AzCopyPath.
	~ Powershell 7
	~ AZ CLI installed (Future proofing)
    ~ VM has system-assigned or user-assigned Managed Identity enabled.
    ~ Managed Identity has Storage Blob Data Contributor on target storage account/container.
    ~ Script should run elevated if stopping services/processes requires admin rights.
	
.NOTES
	~ Designed for minimum 1 hour rotation with variation as the timestamp folder is rounded down to nearest 30-minute interval.
	~ No credentials, secrets, SAS tokens, or storage account keys are stored in this script.
	~ Authentication is handled using Managed Identity.
	~ Source folder structures are preserved.
	~ Local staging is removed only when -RemoveStagingAfterUpload is supplied and upload succeeds.

.USAGE+DEBUG
	~ Task Scheduled - EXAMPLE
		powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\software\LogRotationHandler.ps1" -StorageAccountName "<storage-account-name>" -ContainerName "<container-name>" -RemoveStagingAfterUpload
    ~ Run local - EXAMPLE
		.\LogRotationHandler.ps1 -StorageAccountName "<storage-account-name>" -ContainerName "<container-name>" -RemoveStagingAfterUpload
	~ To Debug add to the CLI - EXAMPLE
		*> "C:\software\LogRotationHandler.log"
#>

[CmdletBinding()]
param(
    [string]$StorageAccountName = "<storage-account-name>",
    [string]$ContainerName      = "<container-name>",
    [string]$ManagedIdentityClientId = "",
    [string]$StagingRoot = "D:\LogRotationStaging",
    [string[]]$SyslogServiceNames = @(
        "CCLsyslog"
    ),
    [string[]]$SyslogProcessNames = @(
        "syslogd.exe"
    ),
    [string[]]$SourceFolders = @(
        "D:\syslogd",
        "D:\ReportedProblems",
		"D:\DesignerLogs",
        "D:\CrashDumps",
		"D:\IIS"
    ),
    [string]$AzCopyPath = "azcopy.exe",
    [switch]$RemoveStagingAfterUpload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
}

function Get-RoundedTimestamp {
    $now = Get-Date

    if ($now.Minute -lt 30) {
        $rounded = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $now.Hour -Minute 0 -Second 0
    }
    else {
        $rounded = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $now.Hour -Minute 30 -Second 0
    }

    return $rounded.ToString("yyyyMMdd-HHmm")
}

function Stop-Syslog {
    Write-Log "Stopping syslog services/processes where possible."

    foreach ($serviceName in $SyslogServiceNames) {
        try {
            $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

            if ($null -ne $svc) {
                if ($svc.Status -ne "Stopped") {
                    Write-Log "Stopping service: $serviceName"
                    Stop-Service -Name $serviceName -Force -ErrorAction Stop
                    $svc.WaitForStatus("Stopped", "00:01:00")
                    Write-Log "Service stopped: $serviceName"
                }
                else {
                    Write-Log "Service already stopped: $serviceName"
                }
            }
            else {
                Write-Log "Service not found: $serviceName" "WARN"
            }
        }
        catch {
            Write-Log "Failed to stop service $serviceName. $($_.Exception.Message)" "WARN"
        }
    }

    foreach ($processName in $SyslogProcessNames) {
        try {
            $procs = Get-Process -Name $processName -ErrorAction SilentlyContinue

            if ($null -ne $procs) {
                foreach ($proc in $procs) {
                    Write-Log "Stopping process: $($proc.ProcessName) PID $($proc.Id)"
                    Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                }
            }
            else {
                Write-Log "Process not found/running: $processName"
            }
        }
        catch {
            Write-Log "Failed to stop process $processName. $($_.Exception.Message)" "WARN"
        }
    }
}

function Start-Syslog {
    Write-Log "Starting syslog services."

    foreach ($serviceName in $SyslogServiceNames) {
        try {
            $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

            if ($null -ne $svc) {
                if ($svc.Status -ne "Running") {
                    Write-Log "Starting service: $serviceName"
                    Start-Service -Name $serviceName -ErrorAction Stop
                    $svc.WaitForStatus("Running", "00:02:00")
                    Write-Log "Service running: $serviceName"
                }
                else {
                    Write-Log "Service already running: $serviceName"
                }
            }
            else {
                Write-Log "Service not found, cannot start: $serviceName" "WARN"
            }
        }
        catch {
            Write-Log "Failed to start service $serviceName. $($_.Exception.Message)" "ERROR"
            throw
        }
    }
}

function Move-SourceFoldersToStaging {
    param(
        [Parameter(Mandatory)]
        [string]$DestinationRoot
    )

    foreach ($source in $SourceFolders) {
        if (-not (Test-Path -LiteralPath $source)) {
            Write-Log "Source folder does not exist, skipping: $source" "WARN"
            continue
        }

        $folderName = Split-Path -Path $source -Leaf
        $destination = Join-Path $DestinationRoot $folderName

        Write-Log "Moving files from source folder: $source"
        Write-Log "Destination: $destination"
        Write-Log "Source folder structure will remain in place."

        New-Item -Path $destination -ItemType Directory -Force | Out-Null

        $robocopyArgs = @(
            $source,
            $destination,
            "/E",
            "/MOV",
            "/COPY:DAT",
            "/DCOPY:DAT",
            "/R:2",
            "/W:5",
            "/NP",
            "/MT:8"
        )

        & robocopy @robocopyArgs
        $rc = $LASTEXITCODE

        # Robocopy exit codes 0-7 are success/warning states.
        if ($rc -gt 7) {
            throw "Robocopy move failed for source '$source' with exit code $rc."
        }

        Write-Log "Robocopy move completed for $source with exit code $rc."
    }
}

function Invoke-AzCopyLoginManagedIdentity {
    Write-Log "Authenticating AzCopy using Managed Identity."

    if (-not $ManagedIdentityClientId) {
        & $AzCopyPath login --identity
    }
    else {
        & $AzCopyPath login --identity --identity-client-id $ManagedIdentityClientId
    }

    if ($LASTEXITCODE -ne 0) {
        throw "AzCopy managed identity login failed with exit code $LASTEXITCODE."
    }

    Write-Log "AzCopy Managed Identity authentication complete."
}

function Upload-StagingToBlob {
    param(
        [Parameter(Mandatory)]
        [string]$StagingPath,

        [Parameter(Mandatory)]
        [string]$TimestampFolder
    )

    $hostname = $env:COMPUTERNAME
    $blobUrl = "https://$StorageAccountName.blob.core.windows.net/$ContainerName/$hostname/$TimestampFolder"

    Write-Log "Uploading staged logs to: $blobUrl"

    $azcopyArgs = @(
        "copy",
        "$StagingPath\*",
        $blobUrl,
        "--recursive=true",
        "--overwrite=false",
        "--from-to=LocalBlob"
    )

    & $AzCopyPath @azcopyArgs

    if ($LASTEXITCODE -ne 0) {
        throw "AzCopy upload failed with exit code $LASTEXITCODE."
    }

    Write-Log "Upload completed successfully."
}

try {
    $timestampFolder = Get-RoundedTimestamp
    $hostname = $env:COMPUTERNAME
    $stagingPath = Join-Path $StagingRoot $timestampFolder

    Write-Log "Starting log rotation."
    Write-Log "Hostname: $hostname"
    Write-Log "Timestamp folder: $timestampFolder"
    Write-Log "Staging path: $stagingPath"

    New-Item -Path $stagingPath -ItemType Directory -Force | Out-Null

    Stop-Syslog

    try {
        Move-SourceFoldersToStaging -DestinationRoot $stagingPath
    }
    finally {
        # Critical: bring syslog back even if copy partially fails.
        Start-Syslog
    }

    Invoke-AzCopyLoginManagedIdentity
    Upload-StagingToBlob -StagingPath $stagingPath -TimestampFolder $timestampFolder

    if ($RemoveStagingAfterUpload) {
        Write-Log "Removing local staging folder: $stagingPath"
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }

    Write-Log "Log rotation completed successfully."
    exit 0
}
catch {
    Write-Log $_.Exception.Message "ERROR"

    try {
        Start-Syslog
    }
    catch {
        Write-Log "Syslog restart attempt after failure also failed. $($_.Exception.Message)" "ERROR"
    }

    exit 1
}