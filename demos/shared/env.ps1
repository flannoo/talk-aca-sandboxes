# Dot-source this in every terminal you present from:
#   . .\demos\shared\env.ps1
# All demos read these. Values marked '__set_me__' are yours to choose: set them in
# env.local.ps1 next to this file (git-ignored), not here. See the README.

# aca writes UTF-8 (box-drawing tables, ✓ marks). Without this, PowerShell decodes piped
# native output with the legacy console code page and the tables turn into mojibake.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

# --- Azure / ARM ---
# Looked up once per shell (~1.4 s); every later demo in the same window reuses it.
# Switched `az account`? Open a new window, or: Remove-Item Env:ACA_SUBSCRIPTION, then reload.
if (-not $env:ACA_SUBSCRIPTION) { $env:ACA_SUBSCRIPTION = (az account show --query id -o tsv) }
$env:ACA_RESOURCE_GROUP = '__set_me__'          # created by 00-setup.ps1 if it doesn't exist
$env:ACA_REGION         = 'westeurope'          # a region you have TESTED (snapshots + egress)

# --- Sandbox group (data plane) ---
$env:ACA_SANDBOX_GROUP  = '__set_me__'          # created by 00-setup.ps1 if it doesn't exist

# --- Disks and snapshots used across demos ---
# The public 'dotnet-10' disk is runtime-only (no SDK), so `dotnet run`/`build` fail on it.
# 00-setup.ps1 converts mcr.microsoft.com/dotnet/sdk:10.0 into this private disk instead.
$env:DEMO_DISK_NAME     = 'dotnet10-sdk'
$env:DEMO_SIZE_CPU      = '2000m'              # builds are CPU-bound; default is 1 vCPU
$env:DEMO_SIZE_MEMORY   = '4096Mi'
$env:PARSER_SNAPSHOT    = 'parser-warm'        # built by demo2-hostile-file\prepare.ps1
$env:AGENT_SNAPSHOT_PY  = 'agent-py'           # Demo 3 agent sandbox, built by demo3-ai-agent\prepare.ps1

# --- How the C# SandboxClient (Demo 2 API, Demo 3 agent) talks to sandboxes ---
# 'rest' (default): direct data-plane calls with one cached token. ~0.5 s forks, ~0.1 s calls.
# 'cli'           : shell out to `aca` for everything (~1.1 s per call). Use it if the REST
#                   path breaks after a service/api-version change. Restart the API after switching.
$env:SANDBOX_TRANSPORT   = 'rest'
$env:SANDBOX_API_VERSION = '2026-02-01-preview'   # what aca 1.0.0-preview.4 sends; service also offers 2026-09-01-preview

# --- Demo 2 middleware ---
$env:MIDDLEWARE_URL     = 'http://localhost:5099'

# --- Demo 3: local LLM (any OpenAI-compatible endpoint) ---
# Foundry Local : run `foundry service status` for the port, e.g. http://localhost:5273/v1
# Ollama        : http://localhost:11434/v1
$env:LLM_ENDPOINT       = 'http://localhost:11434/v1'
$env:LLM_MODEL          = 'hf.co/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF:Q4_K_M'   # pulled from Hugging Face by setup-local-llm.ps1
$env:LLM_API_KEY        = 'local'              # ignored by local runtimes

# --- Demo 4: Express (all created by demo4-express\prepare.ps1) ---
$env:EXPRESS_ENV        = '__set_me__'          # the Express environment
$env:ACR_NAME           = '__set_me__'          # ACR that holds the middleware image: globally unique, throwaway
$env:EXPRESS_IDENTITY   = '__set_me__'          # user-assigned MI with AcrPull (Express has no system-assigned MI)
$env:EXPRESS_APP        = '__set_me__'          # the Express app (same image as below)
$env:CLASSIC_ENV        = '__set_me__'          # regular Consumption environment, for the cold-start race
$env:CLASSIC_APP        = '__set_me__'          # same image, classic environment

$local = Join-Path $PSScriptRoot 'env.local.ps1'
if (Test-Path $local) { . $local }

# Fail fast instead of creating or calling resources named '__set_me__'. Demo 4's names are
# checked by its own scripts, so Demos 1-3 work without them.
$unset = @('ACA_RESOURCE_GROUP', 'ACA_SANDBOX_GROUP') |
    Where-Object { [Environment]::GetEnvironmentVariable($_) -eq '__set_me__' }
if ($unset) { throw "Set $($unset -join ', ') in demos\shared\env.local.ps1 first (see the README)." }

. (Join-Path $PSScriptRoot 'stage.ps1')

# Private disks are addressed by id (--disk-id); resolve it from the name once per shell.
if (-not $env:DEMO_DISK_ID) {
    try {
        $disk = @(Invoke-AcaJson sandboxgroup disk list) |
            Where-Object { $_.name -eq $env:DEMO_DISK_NAME -or $_.labels.name -eq $env:DEMO_DISK_NAME } |
            Select-Object -First 1
    } catch { $disk = $null }   # group may not exist yet on a first 00-setup run
    if ($disk) { $env:DEMO_DISK_ID = $disk.id }
    else { Write-Warning "disk '$env:DEMO_DISK_NAME' not found — run demos\shared\00-setup.ps1" }
}

Write-Host "env loaded (group=$env:ACA_SANDBOX_GROUP, region=$env:ACA_REGION)" -ForegroundColor DarkGray
