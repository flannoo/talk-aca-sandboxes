# Demo 4 pre-flight: the middleware image, then the SAME image deployed twice, scale-to-zero:
#   $env:EXPRESS_APP in the Express environment, $env:CLASSIC_APP in a regular Consumption one.
# Run it at least 10 minutes before Demo 4 and then DON'T TOUCH the apps: both scale to zero
# on their own (~6-8 min idle), which is what the cold-start race on stage needs.
# Uses `az acr build`, so no local Docker. Do NOT point ACR_NAME at a shared/production registry.
param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\shared\env.ps1')
$unset = 'EXPRESS_ENV', 'ACR_NAME', 'EXPRESS_IDENTITY', 'EXPRESS_APP', 'CLASSIC_ENV', 'CLASSIC_APP' |
    Where-Object { [Environment]::GetEnvironmentVariable($_) -eq '__set_me__' }
if ($unset) { throw "Demo 4: set $($unset -join ', ') in demos\shared\env.local.ps1 first (ACR_NAME is globally unique, e.g. acrtalk<initials>)." }
$rg = $env:ACA_RESOURCE_GROUP

function Assert-Az([string]$What) { if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE) — see the output above." } }

az extension add --name containerapp --upgrade -y; Assert-Az 'az extension add'
# The extension feed only offers versions compatible with the installed CLI core, so an
# old az silently gets a pre-Express extension. Express needs 1.3.0b4+. Fail here, not on stage.
$ext = az extension show --name containerapp --query version -o tsv
$m = [regex]::Match($ext, '^(\d+\.\d+\.\d+)(?:b(\d+))?$')
$tooOld = -not $m.Success -or [version]$m.Groups[1].Value -lt [version]'1.3.0' -or
    ($m.Groups[1].Value -eq '1.3.0' -and $m.Groups[2].Success -and [int]$m.Groups[2].Value -lt 4)
if ($tooOld) {
    throw "containerapp extension $ext is too old for Express (need 1.3.0b4+). Upgrade the Azure CLI (az upgrade, or winget upgrade Microsoft.AzureCLI), then re-run."
}

# --- Registry + pull identity --------------------------------------------------------------
az acr show --name $env:ACR_NAME -o none 2>$null
if ($LASTEXITCODE -ne 0) { az acr create --name $env:ACR_NAME --resource-group $rg --sku Basic -o none; Assert-Az 'az acr create' }

# Express can't pull with a system-assigned identity, so a user-assigned one with AcrPull
# (both apps use it). Done early: role assignments take minutes to propagate.
$idJson = az identity show --name $env:EXPRESS_IDENTITY --resource-group $rg -o json 2>$null
if ($LASTEXITCODE -ne 0) { $idJson = az identity create --name $env:EXPRESS_IDENTITY --resource-group $rg -o json; Assert-Az 'az identity create' }
$identity = $idJson | ConvertFrom-Json
$acrId = az acr show --name $env:ACR_NAME --query id -o tsv
$existing = az role assignment list --assignee $identity.principalId --scope $acrId --role AcrPull --query "[0].id" -o tsv
if (-not $existing) {
    az role assignment create --assignee-object-id $identity.principalId --assignee-principal-type ServicePrincipal `
        --role AcrPull --scope $acrId -o none
    Assert-Az 'AcrPull role assignment'
}

# --- Image ---------------------------------------------------------------------------------
$image = "$env:ACR_NAME.azurecr.io/middleware:v1"
if (-not $SkipBuild) {
    $demos = Resolve-Path (Join-Path $PSScriptRoot '..')
    az acr build --registry $env:ACR_NAME --image middleware:v1 `
        --file (Join-Path $demos 'demo2-hostile-file\Middleware\Dockerfile') $demos
    Assert-Az 'az acr build'
}

# --- Two environments, one image -----------------------------------------------------------
function Confirm-Env([string]$Name, [string[]]$Extra) {
    az containerapp env show --name $Name --resource-group $rg -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "creating environment $Name …" -ForegroundColor Cyan
        az containerapp env create --name $Name --resource-group $rg --location $env:ACA_REGION --logs-destination none @Extra -o none
        Assert-Az "env create $Name"
    }
}
Confirm-Env $env:EXPRESS_ENV @('--environment-mode', 'express')
Confirm-Env $env:CLASSIC_ENV @()

# Same size for both apps, so the race compares the platforms and nothing else. Left unset,
# each environment picks its own default (Express 0.25 vCPU / 0.5 GiB, classic 0.5 / 1 GiB).
$size = @('--cpu', '0.5', '--memory', '1.0Gi')

function Deploy-App([string]$Name, [string]$Environment) {
    az containerapp show --name $Name --resource-group $rg -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        az containerapp create --name $Name --resource-group $rg --environment $Environment --image $image `
            --registry-server "$env:ACR_NAME.azurecr.io" --registry-identity $identity.id `
            --target-port 8080 --ingress external --min-replicas 0 --max-replicas 10 @size -o none
        Assert-Az "create $Name"
    }
    else {
        # Same tag, new build: force a new revision that pulls it. Express rejects revision
        # suffixes (ExpressEnvironmentFeatureNotSupported), so there a changed env var does it.
        $stamp = Get-Date -Format 'MMddHHmm'
        $newRevision = if ($Environment -eq $env:EXPRESS_ENV) { '--set-env-vars', "DEPLOYED_AT=$stamp" }
                       else { '--revision-suffix', "r$stamp" }
        az containerapp update --name $Name --resource-group $rg --image $image @size `
            --min-replicas 0 @newRevision -o none
        Assert-Az "update $Name"
    }
    $fqdn = az containerapp show --name $Name --resource-group $rg --query properties.configuration.ingress.fqdn -o tsv
    Write-Host ("{0,-20} https://{1}" -f $Name, $fqdn) -ForegroundColor Cyan
}
Deploy-App $env:EXPRESS_APP $env:EXPRESS_ENV
Deploy-App $env:CLASSIC_APP $env:CLASSIC_ENV

Write-Host "`nReady. Leave both apps untouched for 10+ minutes so they scale to zero." -ForegroundColor Green
Write-Host "Check: .\demos\demo4-express\demo4.ps1 shows the replica count first." -ForegroundColor Green
