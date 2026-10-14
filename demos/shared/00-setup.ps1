# ONE-TIME setup. Run in pre-flight, NOT on stage.
# Creates the sandbox group (if missing), grants you data-plane access, and gates on `aca doctor`.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')

# 1. Auth — gated, never unconditional.
az account show -o none 2>$null
if ($LASTEXITCODE -ne 0) { az login }
aca auth status *> $null
if ($LASTEXITCODE -ne 0) { aca auth login }

# 2. Resource group (ARM control plane). A fresh subscription isn't registered for Microsoft.App.
az provider register --namespace Microsoft.App --wait
az group create --name $env:ACA_RESOURCE_GROUP --location $env:ACA_REGION -o none

# 3. Sandbox group (ARM). --set-config persists group/sub/region into ~/.aca/config.json.
#    `create` already grants YOU "Container Apps SandboxGroup Data Owner".
aca sandboxgroup get --name $env:ACA_SANDBOX_GROUP *> $null
if ($LASTEXITCODE -ne 0) {
    aca sandboxgroup create --name $env:ACA_SANDBOX_GROUP --location $env:ACA_REGION --set-config
    # The new role assignment takes a few minutes to propagate: data-plane calls 403 until then.
    $deadline = (Get-Date).AddMinutes(10)
    while ($true) {
        aca sandboxgroup disk list *> $null
        if ($LASTEXITCODE -eq 0) { break }
        if ((Get-Date) -gt $deadline) { throw 'Data-plane access still denied after 10 min — check the role assignment.' }
        Write-Host 'waiting for the data-plane role to propagate…' -ForegroundColor DarkGray
        Start-Sleep -Seconds 20
    }
}

# 4. (Optional) grant ANOTHER principal, e.g. the middleware's managed identity:
# aca sandboxgroup role create --role "Container Apps SandboxGroup Data Owner" --principal-id <OBJECT_ID>

# 5. The .NET 10 SDK disk. The public 'dotnet-10' disk is runtime-only, so convert
#    Microsoft's SDK container image into a private disk (takes a few minutes).
$disks = @(Invoke-AcaJson sandboxgroup disk list)
if (-not ($disks | Where-Object { $_.name -eq $env:DEMO_DISK_NAME -or $_.labels.name -eq $env:DEMO_DISK_NAME })) {
    aca sandboxgroup disk create --image mcr.microsoft.com/dotnet/sdk:10.0 `
        --name $env:DEMO_DISK_NAME --label "name=$env:DEMO_DISK_NAME" --wait-timeout 1500
}
aca sandboxgroup disk list

# 6. Gate on green.
aca doctor
if ($LASTEXITCODE -ne 0) { throw 'aca doctor is not green — fix before presenting.' }

Write-Host "`nSetup complete. Next: demo2-hostile-file\prepare.ps1 and demo3-ai-agent\prepare.ps1" -ForegroundColor Cyan
