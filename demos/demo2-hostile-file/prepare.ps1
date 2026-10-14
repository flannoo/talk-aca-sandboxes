# Demo 2 pre-flight: bake a warm "parser" snapshot so every /ingest boots with the
# parser already on disk and compiled. Run once, off stage (takes a minute or two).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\shared\env.ps1')

$old = @(Invoke-AcaJson sandboxgroup snapshot list) | Where-Object { $_.labels.name -eq $env:PARSER_SNAPSHOT }
if ($old) { aca sandboxgroup snapshot delete --selector "name=$env:PARSER_SNAPSHOT" }

$id = New-Sandbox --disk-id $env:DEMO_DISK_ID --cpu $env:DEMO_SIZE_CPU --memory $env:DEMO_SIZE_MEMORY --label name=parser-prep
try {
    aca sandbox fs write --id $id --path /app/parser.cs --file (Join-Path $PSScriptRoot 'parser\parser.cs')
    # First `dotnet run` compiles the file-based app; the build output lands on disk.
    aca sandbox exec --id $id -c 'dotnet run /app/parser.cs -- --warmup'
    aca sandbox fs write --id $id --path /in/probe.xml --file (Join-Path $PSScriptRoot 'samples\order-good.xml')
    aca sandbox exec --id $id -c 'dotnet run /app/parser.cs -- /in/probe.xml'
    aca sandbox snapshot --id $id --name $env:PARSER_SNAPSHOT
}
finally {
    aca sandbox delete --id $id --yes --no-wait
}

aca sandboxgroup snapshot list
Write-Host "Snapshot '$env:PARSER_SNAPSHOT' ready." -ForegroundColor Cyan
