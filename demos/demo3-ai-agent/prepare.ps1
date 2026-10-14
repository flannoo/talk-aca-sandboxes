# Demo 3 pre-flight: bake the snapshot the mapping agent forks from. A snapshot keeps
# memory AND disk, so every sandbox forked from it starts warm. Run once, off stage.
#   agent-py: python-3.12 disk, stdlib imports warmed, /work ready.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\shared\env.ps1')
$name = $env:AGENT_SNAPSHOT_PY

$old = @(Invoke-AcaJson sandboxgroup snapshot list) | Where-Object { $_.labels.name -eq $name }
if ($old) { aca sandboxgroup snapshot delete --selector "name=$name" }
$id = New-Sandbox --disk python-3.12 --cpu $env:DEMO_SIZE_CPU --memory $env:DEMO_SIZE_MEMORY --label "name=$name-prep"
try {
    # Import everything the system prompt allows, so the first run pays nothing extra.
    aca sandbox exec --id $id -c 'mkdir -p /work && python3 -c "import csv, json, datetime, decimal, urllib.request, sys; print(sys.version)"'
    if ($LASTEXITCODE -ne 0) { throw "warm-up for $name failed" }
    aca sandbox snapshot --id $id --name $name
}
finally { aca sandbox delete --id $id --yes --no-wait }
Write-Host "Snapshot '$name' ready." -ForegroundColor Cyan
aca sandboxgroup snapshot list
