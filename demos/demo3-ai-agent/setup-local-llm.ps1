# Local model for Demo 3 — no Azure OpenAI needed. Pick ONE runtime.
# Both expose an OpenAI-compatible /v1/chat/completions endpoint the agent talks to.
#
#   .\setup-local-llm.ps1 -Runtime ollama    (default: pulls a GGUF straight from Hugging Face)
#   .\setup-local-llm.ps1 -Runtime foundry   (Foundry Local: Microsoft's on-device runtime)
#
# Then set LLM_ENDPOINT / LLM_MODEL in demos\shared\env.local.ps1 to what this prints.
param(
    [ValidateSet('ollama', 'foundry')] [string]$Runtime = 'ollama',
    # Qwen2.5-Coder 7B is a good fit for C# on a laptop (~4.7 GB at Q4). Try 14B if you have the GPU.
    [string]$HfModel = 'hf.co/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF:Q4_K_M',
    [string]$FoundryModel = 'qwen2.5-coder-7b'
)
$ErrorActionPreference = 'Stop'

if ($Runtime -eq 'ollama') {
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        winget install --id Ollama.Ollama -e --accept-package-agreements
        Write-Host 'Ollama installed — open a NEW terminal so it is on PATH, then re-run this script.' -ForegroundColor Yellow
        return
    }
    # Needs a SINGLE-FILE GGUF: Ollama can't pull sharded ones (the official Qwen repo's
    # Q4_K_M is sharded, hence bartowski's build of the same model).
    ollama pull $HfModel
    if ($LASTEXITCODE -ne 0) { throw "ollama pull failed for $HfModel" }

    # Smoke-test the exact endpoint the agent uses (OpenAI-compatible chat completions).
    $body = @{ model = $HfModel; messages = @(@{ role = 'user'; content = 'Reply with the single word: ready' }) } | ConvertTo-Json -Depth 4
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Method Post -Uri 'http://localhost:11434/v1/chat/completions' -Body $body -ContentType 'application/json'
    Write-Host ("model says: {0}  ({1:N1}s incl. loading into GPU memory)" -f $r.choices[0].message.content.Trim(), $sw.Elapsed.TotalSeconds) -ForegroundColor Green

    if ($HfModel -ne $env:LLM_MODEL -and $env:LLM_MODEL) {
        Write-Host "`nAdd to demos\shared\env.local.ps1:" -ForegroundColor Cyan
        Write-Host "`$env:LLM_MODEL = '$HfModel'"
    }
    else { Write-Host 'env.ps1 already points at this model and endpoint.' -ForegroundColor Cyan }
}
else {
    if (-not (Get-Command foundry -ErrorAction SilentlyContinue)) {
        winget install --id Microsoft.FoundryLocal -e --accept-package-agreements
        Write-Host 'Foundry Local installed — open a NEW terminal, then re-run this script.' -ForegroundColor Yellow
        return
    }
    foundry model list
    foundry model run $FoundryModel --prompt 'Reply with the single word: ready'
    foundry service status   # prints the local endpoint (the port is chosen at start)
    Write-Host "`nAdd to env.local.ps1 (use the port from 'service status' above):" -ForegroundColor Cyan
    Write-Host "`$env:LLM_ENDPOINT = 'http://localhost:<port>/v1'"
    Write-Host "`$env:LLM_MODEL    = '<model id from: foundry model list>'"
}
