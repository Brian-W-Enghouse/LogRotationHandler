<#
.DESCRIPTION
	Brians Log Rotation Handler Script - Version 1.2.0-RC
	Process Overview
	1	-	Stops syslog service/processes.
			If not stopped within 2 minutes, Force stops if not completely stopped.
	2 	-	Moves active log files from configured source folders into a timestamped staging directory
	3 	-	Restarts syslog
    4   -   Compress only folders selected by switch -CompressFolders.
            If not supplied, no compression is performed.  Compression is done using 7zip and the 7zr.exe binary.
    5   -   Uploads the staged files to Azure Blob Storage using Managed Identity.
    6   -   Deletes the local staging folder after successful compression and upload if -RemoveStagingAfterUpload is supplied.
            If not supplied, the local staging folder is retained for troubleshooting.

.REQUIREMENTS
	~ Powershell 7 - Installed
	~ AZ CLI installed (Future proofing) - Installed
    ~ VM has system-assigned or user-assigned Managed Identity enabled.
    ~ Managed Identity has Storage Blob Data Contributor on target storage account/container.
    ~ Script HAS TO run elevated if stopping services/processes requires admin rights (eg service account).
	~ If not installed it will install on setup in the software folder:
		AzCopy
		7zip
	
.NOTES
	~ Designed for minimum 1 hour rotation with variation as the timestamp folder is rounded down to nearest 30-minute interval.
	~ No credentials, secrets, SAS tokens, or storage account keys are stored in this script.
	~ Authentication is handled using Managed Identity.
	~ Source folder structures are preserved.
	~ Local staging is removed only when -RemoveStagingAfterUpload is supplied and upload succeeds.

.USAGE+DEBUG
	~ To Install
		.\LogRotationHandler.ps1 -StorageAccountName "<storage-account-name>" -ContainerName "<container-name>" -Install
	~ To UnInstall
		.\LogRotationHandler.ps1 -StorageAccountName "<storage-account-name>" -ContainerName "<container-name>" -Uninstall
	~ Task Scheduled - EXAMPLE
		powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\software\LogRotationHandler.ps1" -StorageAccountName "<storage-account-name>" -ContainerName "<container-name>" -RemoveStagingAfterUpload -CompressFolders "CosmoDesigner"
    ~ Run local - EXAMPLE
		.\LogRotationHandler.ps1 -StorageAccountName "<storage-account-name>" -ContainerName "<container-name>" -RemoveStagingAfterUpload
    ~ Compress Folders - EXAMPLE - Only CosmoDesigner enabled by Default during install
        .\LogRotationHandler.ps1 -StorageAccountName "<storage-account-name>" -ContainerName "<container-name>" -RemoveStagingAfterUpload -CompressFolders "CosmoDesigner","IIS","ReportedProblems","CrashDumps"
	~ To Debug add to the CLI - EXAMPLE
		*> "C:\software\LogRotationHandler.log"
#>


[CmdletBinding()]
param(
    [string]$StorageAccountName = "<storage-account-name>",
    [string]$ContainerName      = "<container-name>",
    [string]$ManagedIdentityClientId = "",
    [string]$StagingRoot = (Join-Path ([System.IO.Path]::GetTempPath()) "LogRotationStaging"),
    [string[]]$SyslogServiceNames = @(
        "CCLsyslog"
    ),
    [string[]]$SyslogProcessNames = @(
        "syslogd"
    ),
    [string[]]$SourceFolderNames = @(
        "syslogd",
        "ReportedProblems",
        "CosmoDesigner",
        "CrashDumps",
        "IIS"
    ),
    [string[]]$SourceFolders = @(),
    [string[]]$CompressFolders = @(),
    [string]$AzCopyPath = "C:\Software\azcopy.exe",
    [string]$SevenZipPath = "C:\Software\7zr.exe",
	[switch]$Install,
	[switch]$Uninstall,
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


function Install-LogRotationTask {
    $taskName = "LogRotationHandler"
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
		Write-Log "Installing scheduled task as: $currentUser"
    $credential = Get-Credential -UserName $currentUser -Message "Enter the password for the service account"
    $actionArguments = '-NoProfile -ExecutionPolicy Bypass -File "C:\Software\LogRotationHandler.ps1" -StorageAccountName "' + $StorageAccountName + '" -ContainerName "' + $ContainerName + '" -CompressFolders "CosmoDesigner" -RemoveStagingAfterUpload'
    $action = New-ScheduledTaskAction -Execute "C:\Program Files\PowerShell\7\pwsh.exe" -Argument $actionArguments
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddHours(1) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)
		Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -User $credential.UserName -Password ($credential.GetNetworkCredential().Password) -RunLevel Highest -Force
		Write-Log "Scheduled task installed successfully as $($credential.UserName)"
		Write-Log "Default scheduled compression folder: CosmoDesigner"
}

function Uninstall-LogRotationTask {
	Unregister-ScheduledTask -TaskName "LogRotationHandler" -Confirm:$false
	Write-Log "Scheduled task removed."
}

function Get-TempDriveRoot {
    if (-not $env:TEMP) {
        throw "TEMP environment variable is not defined."
    }

    $tempDriveRoot = [System.IO.Path]::GetPathRoot($env:TEMP)

    if (-not $tempDriveRoot) {
        throw "Unable to determine drive root from TEMP path: $env:TEMP"
    }

    return $tempDriveRoot
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
                    $svc.WaitForStatus("Stopped", "00:02:00")
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

function Resolve-CompressFolders {
    if ($CompressFolders.Count -eq 0) {
        return @()
    }

    $resolvedFolders = foreach ($compressFolderEntry in $CompressFolders) {
        foreach ($folderName in ($compressFolderEntry -split ",")) {
            $cleanFolderName = $folderName.Trim().Trim('"').Trim("'")

            if ($cleanFolderName) {
                $cleanFolderName
            }
        }
    }

    return @(
        $resolvedFolders | Sort-Object -Unique
    )
}

$CompressFolders = @(Resolve-CompressFolders)

function Compress-StagingFolders {
    param(
        [Parameter(Mandatory)]
        [string]$StagingPath
    )

    if ($CompressFolders.Count -eq 0) {
        Write-Log "No compression folders supplied. Compression will be skipped."
        return
    }

    if (-not (Test-Path -LiteralPath $SevenZipPath -PathType Leaf)) {
        throw "7-Zip executable was not found: $SevenZipPath"
    }

    foreach ($folderName in $CompressFolders) {
        $sourceFolder = Join-Path $StagingPath $folderName
        if (-not (Test-Path -LiteralPath $sourceFolder -PathType Container)) {
			Write-Log "Compression folder does not exist in staging, skipping: $sourceFolder" "WARN"
            continue
        }
        $firstFile = Get-ChildItem -LiteralPath $sourceFolder -File -Recurse -Force | Select-Object -First 1
        if ($null -eq $firstFile) {
            Write-Log "Compression folder contains no files, skipping: $sourceFolder"
            continue
        }
        Write-Log "Compression triggered by file: $($firstFile.FullName)"
        Write-Log "Compression trigger file size: $($firstFile.Length) bytes"
        $archivePath = Join-Path $StagingPath "$folderName.7z"
        Write-Log "Compressing staging folder: $sourceFolder"
        Write-Log "Archive destination: $archivePath"
        $sevenZipArgs = @(
            "a",
            "-t7z",
            "-mx=5",
            "-y",
            $archivePath,
            "$sourceFolder\*"
        )
        & $SevenZipPath @sevenZipArgs
        $sevenZipExitCode = $LASTEXITCODE

        if ($sevenZipExitCode -ne 0) {
            throw "7-Zip compression failed for '$sourceFolder' with exit code $sevenZipExitCode."
        }
        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
            throw "7-Zip reported success, but the archive was not created: $archivePath"
        }
        Write-Log "Compression completed successfully: $archivePath"
        Write-Log "Removing compressed source folder: $sourceFolder"
        Remove-Item -LiteralPath $sourceFolder -Recurse -Force
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

if ($Install) {
    if (-not (Test-Path -LiteralPath $SevenZipPath)) {
        Write-Log "7zr.exe not found. Downloading."
        Invoke-WebRequest -Uri "https://www.7-zip.org/a/7zr.exe" -OutFile $SevenZipPath
        Write-Log "7zr.exe downloaded successfully."
        }
        else {
            Write-Log "7zr.exe already present."
        }
    if (-not (Test-Path -LiteralPath $AzCopyPath)) {
        $azCopyZip = "C:\azcopy.zip"
        Invoke-WebRequest -Uri "https://aka.ms/downloadazcopy-v10-windows" -OutFile $azCopyZip
        Expand-Archive -Path $azCopyZip -DestinationPath "C:\Software" -Force
        $azCopyExe = Get-ChildItem -Path "C:\Software" -Recurse -Filter "azcopy.exe" | Select-Object -First 1
        if (-not $azCopyExe) {
            throw "Failed to locate azcopy.exe in downloaded package."
        }
        Copy-Item -LiteralPath $azCopyExe.FullName -Destination $AzCopyPath -Force
        Write-Log "AzCopy extracted successfully."
        }
        else {
             Write-Log "AzCopy already present."
    }    
        Install-LogRotationTask
    exit 0
}

if ($Uninstall) {
    Uninstall-LogRotationTask
    exit 0
}


if ($SourceFolders.Count -eq 0) {
    $driveRoot = Get-TempDriveRoot
    $SourceFolders = $SourceFolderNames | ForEach-Object {
    Join-Path $driveRoot $_
    }
}

try {
    $timestampFolder = Get-RoundedTimestamp
    $hostname = $env:COMPUTERNAME
    $stagingPath = Join-Path $StagingRoot $timestampFolder
    Write-Log "Starting log rotation."
    Write-Log "Hostname: $hostname"
    Write-Log "Timestamp folder: $timestampFolder"
    Write-Log "Staging path: $stagingPath"
    Write-Log "TEMP path: $env:TEMP"
    Write-Log "Source folders resolved from TEMP drive:"

    foreach ($sourceFolder in $SourceFolders) {
        Write-Log " - $sourceFolder"
    }

    if ($CompressFolders.Count -gt 0) {
        Write-Log "Folders selected for compression:"

        foreach ($compressFolder in $CompressFolders) {
            Write-Log " - $compressFolder"
        }
        }
        else {
            Write-Log "No folders selected for compression."
    }

    New-Item -Path $stagingPath -ItemType Directory -Force | Out-Null

    Stop-Syslog

    try {
        Move-SourceFoldersToStaging -DestinationRoot $stagingPath
    }
    finally {
        # Critical: bring syslog back even if move partially fails.
        Start-Syslog
    }
    Compress-StagingFolders -StagingPath $stagingPath
    Invoke-AzCopyLoginManagedIdentity
    Upload-StagingToBlob -StagingPath $stagingPath -TimestampFolder $timestampFolder

    if ($RemoveStagingAfterUpload) {
        Write-Log "Removing local staging folder: $stagingPath"
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }
    else {
        Write-Log "Local staging retained: $stagingPath"
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