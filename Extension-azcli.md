$ResourceGroup = "<resource-group-name>"
$VmName = "<vm-name>"
$ScriptUrl = "https://raw.githubusercontent.com/Brian-W-Enghouse/LogRotationHandler/refs/heads/main/LogRotationHandler.ps1"
$Command = "powershell.exe -ExecutionPolicy Bypass -Command `"New-Item -Path 'C:\software' -ItemType Directory -Force | Out-Null; Invoke-WebRequest -Uri '$ScriptUrl' -OutFile 'C:\software\LogRotationHandler.ps1' -UseBasicParsing`""

az vm extension set --resource-group $ResourceGroup --vm-name $VmName --name CustomScriptExtension --publisher Microsoft.Compute --version 1.10 --settings "{ `"commandToExecute`": `"$Command`" }"