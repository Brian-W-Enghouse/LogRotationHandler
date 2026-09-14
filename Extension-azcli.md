## SINGLE INSTALL
$ResourceGroup = "<resource-group-name>"
$VmName = "<vm-name>"
az vm extension set --resource-group $ResourceGroup --vm-name $VmName --name CustomScriptExtension --publisher Microsoft.Compute --version 1.10 --settings '{"commandToExecute":"powershell.exe -ExecutionPolicy Bypass -Command Invoke-WebRequest -Uri https://raw.githubusercontent.com/Brian-W-Enghouse/LogRotationHandler/refs/heads/main/LogRotationHandler.ps1 -OutFile C:\\software\\LogRotationHandler.ps1 -UseBasicParsing"}'

## Install all!
$ResourceGroup = "<RESOURCE GROUP>"
$Vms = az vm list --resource-group $ResourceGroup --query "[].name" -o tsv
foreach ($VmName in $Vms) {
    Write-Host "Deploying to $VmName"
    az vm extension set --resource-group $ResourceGroup --vm-name $VmName --name CustomScriptExtension --publisher Microsoft.Compute --version 1.10 --settings '{"commandToExecute":"powershell.exe -ExecutionPolicy Bypass -Command Invoke-WebRequest -Uri https://raw.githubusercontent.com/Brian-W-Enghouse/LogRotationHandler/refs/heads/main/LogRotationHandler.ps1 -OutFile C:\\software\\LogRotationHandler.ps1 -UseBasicParsing"}'
}