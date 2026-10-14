# Demo 2 — Hostile partner file, contained.
# Terminal 1 (API):     dotnet run --project .\demos\demo2-hostile-file\Middleware
# Terminal 2 (WATCHER): .\demos\demo2-hostile-file\watch-health.ps1
# Terminal 3 (DRIVER):  .\demos\demo2-hostile-file\demo2.ps1
# Prereq: env loaded in all three, prepare.ps1 has baked the parser snapshot.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\shared\env.ps1')
# Capture paths here: inside Step, $PSScriptRoot would point at shared\ (where Step lives).
$here = $PSScriptRoot
$samples = Join-Path $here 'samples'

# POST a file to the middleware, show the JSON whatever the status code.
function global:Send-PartnerFile([string]$File, [switch]$Keep) {
    $uri = "$env:MIDDLEWARE_URL/ingest" + $(if ($Keep) { '?keep=true' })
    $r = Invoke-WebRequest -Method Post -Uri $uri -InFile $File -ContentType 'application/xml' -SkipHttpErrorCheck
    Write-Host "HTTP $($r.StatusCode)" -ForegroundColor $(if ($r.StatusCode -lt 300) { 'Green' } else { 'Yellow' })
    $global:LAST = $r.Content | ConvertFrom-Json
    $LAST | Format-List
}

# POST the same file N times at once, keeping every sandbox so the room can see them in the
# portal: one row per request, each with its own sandbox id.
function global:Send-Burst([string]$File, [int]$Count = 8) {
    $uri = "$env:MIDDLEWARE_URL/ingest?keep=true"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $rows = 1..$Count | ForEach-Object -ThrottleLimit $Count -Parallel {
        $r = Invoke-WebRequest -Method Post -Uri $using:uri -InFile $using:File -ContentType 'application/xml' -SkipHttpErrorCheck
        $b = try { $r.Content | ConvertFrom-Json } catch { $null }
        [pscustomobject]@{ Request = $_; HTTP = $r.StatusCode; Sandbox = $b.sandboxId; BootMs = $b.bootMs; TotalMs = $b.totalMs }
    }
    $rows | Sort-Object Request | Format-Table -AutoSize | Out-Host
    $distinct = @($rows.Sandbox | Where-Object { $_ } | Sort-Object -Unique).Count
    Write-Host ("  {0} requests, {1} different sandboxes, all answered in {2:N1} s" -f $Count, $distinct, $sw.Elapsed.TotalSeconds) -ForegroundColor Cyan
}

# Set the auto-suspend idle timeout on every sandbox with one label: what
# `aca sandbox lifecycle set --id <id> --auto-suspend enable --idle-timeout-seconds N` does,
# as a direct REST call with the cached token. (`lifecycle set -l` refuses when more than one
# sandbox matches in 1.0.0-preview.4, and eight CLI calls cost ~9 s of token fetching.)
function global:Set-IdleTimeout([string]$Label = 'parsebox', [int]$Seconds = 10) {
    $headers = @{ Authorization = "Bearer $(Get-SandboxToken)" }
    $base = Get-SandboxApiBase
    $ids = @(Invoke-RestMethod -Uri "$($base)?api-version=$env:SANDBOX_API_VERSION" -Headers $headers |
        ForEach-Object { $_ } | Where-Object { $_.labels.name -eq $Label } | ForEach-Object id)
    # The body the CLI sends (aca --verbose). Mode is required when auto-suspend is enabled;
    # Memory = suspend with memory kept, like `aca sandbox stop`.
    $body = @{
        autoSuspendPolicy = @{ enabled = $true; interval = $Seconds; mode = 'Memory' }
        autoDeletePolicy  = @{ enabled = $false }
    } | ConvertTo-Json
    $done = 0
    foreach ($id in $ids) {
        try {
            Invoke-RestMethod -Method Post -Uri "$base/$id/lifecycle?api-version=$env:SANDBOX_API_VERSION" -Headers $headers `
                -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
            $done++
        }
        catch { Write-Host "  ✗ $id : $($_.Exception.Message)" -ForegroundColor Red }
    }
    Write-Host ("  auto-suspend after {0} s idle: set on {1} of {2} sandboxes (name={3})" -f $Seconds, $done, $ids.Count, $Label) -ForegroundColor Cyan
}

# Live counter of running vs stopped sandboxes with one label. Stops at the first suspended
# box (enough to show the idle timeout working; the rest follow on their own), or with -All
# once every box is stopped. Polls the REST list with the cached token (~0.2 s a call).
function global:Watch-Suspend([string]$Label = 'parsebox', [switch]$All, [int]$TimeoutSec = 120) {
    $headers = @{ Authorization = "Bearer $(Get-SandboxToken)" }
    $uri = "$(Get-SandboxApiBase)?api-version=$env:SANDBOX_API_VERSION"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        # The API returns a JSON array; Invoke-RestMethod hands it over as one object, so unroll it.
        $boxes = @(Invoke-RestMethod -Uri $uri -Headers $headers | ForEach-Object { $_ } | Where-Object { $_.labels.name -eq $Label })
        $running = @($boxes | Where-Object state -eq 'Running').Count
        $stopped = $boxes.Count - $running
        $line = "  {0,3:N0} s   running: {1}   stopped: {2}" -f $sw.Elapsed.TotalSeconds, $running, $stopped
        $done = if ($All) { $running -eq 0 } else { $stopped -ge 1 }
        if ($done -or $sw.Elapsed.TotalSeconds -gt $TimeoutSec) { Write-Host "`r$line   " -ForegroundColor Cyan; return }
        Write-Host -NoNewline "`r$line   " -ForegroundColor DarkGray
        Start-Sleep -Seconds 2
    }
}

# --- Pre-check: API up? If not, open the API + WATCHER tabs in Windows Terminal. ---
function Test-Api { try { (Invoke-WebRequest "$env:MIDDLEWARE_URL/healthz" -TimeoutSec 2).StatusCode -eq 200 } catch { $false } }
function Start-Tab([string]$Title, [string]$Command) {
    # -EncodedCommand sidesteps wt's own parsing of ';' and quotes.
    $script = ". '$PSScriptRoot\..\shared\env.ps1'; $Command"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    wt -w 0 new-tab --title $Title pwsh -NoExit -EncodedCommand $enc
}
if (-not (Test-Api)) {
    Write-Host "API not reachable at $env:MIDDLEWARE_URL — starting API and WATCHER tabs…" -ForegroundColor Yellow
    Start-Tab 'API' "dotnet run --project '$PSScriptRoot\Middleware'"
    Start-Tab 'WATCHER' "& '$PSScriptRoot\watch-health.ps1'"
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Test-Api)) {
        if ((Get-Date) -gt $deadline) { throw 'API did not come up in 90s — check the API tab.' }
        Start-Sleep -Seconds 2
    }
    Write-Host 'API healthy.' -ForegroundColor Green
}

# Off-screen warm-up: the first fork after the API starts is slower (~1.7 s vs ~0.5 s).
# One throwaway request now, so the audience sees the real number in 2.2.
Invoke-WebRequest -Method Post -Uri "$env:MIDDLEWARE_URL/ingest" -InFile "$samples\order-good.xml" -ContentType 'application/xml' -SkipHttpErrorCheck | Out-Null

# --- 2.1 The shape: the three sandbox calls in the handler ---
Say 'Middleware/Program.cs: create from snapshot -> fs write -> exec. Egress Deny from the first instruction.'
Step 'code -g "$here\Middleware\Program.cs:48"'

# --- 2.2 Happy path: a normal partner file ---
Say 'A normal order. Parsed in a fresh microVM, result back to the API.'
Step 'Get-Content "$samples\order-good.xml"'
Step 'Send-PartnerFile "$samples\order-good.xml"'
Say 'One sandbox per request, really. Eight partner files at once, and this time we keep the boxes so you can see them.'
Step 'Send-Burst "$samples\order-good.xml" -Count 8'
Say 'Eight requests, eight microVMs. Portal: containerapps.azure.com/sandbox-groups, label name=parsebox.'
Step 'aca sandbox list -l name=parsebox'
Say 'Their work is done. Default: a box suspends itself after 5 minutes idle. For these eight: 10 seconds.'
Say '  (per box, that is: aca sandbox lifecycle set --id <id> --auto-suspend enable --idle-timeout-seconds 10)'
Step 'Set-IdleTimeout parsebox 10'
Step 'Watch-Suspend parsebox'
Say 'There goes the first one: no compute, memory and disk kept. The rest follow on their own. Portal: Stopped.'
Say 'Normally each one is deleted the moment it has answered. Clean up:'
Step 'Remove-SandboxesByLabel name=parsebox'

# --- 2.3 The hostile file ---
Say 'Same endpoint. This file carries external entities: read a local file, then call out.'
Step 'Get-Content "$samples\xxe-exfil.xml"'
Say 'Our parser has the classic DTD misconfiguration. It WILL try.'
Step 'Send-PartnerFile "$samples\xxe-exfil.xml" -Keep'

# --- 2.4 The money shot: why it failed ---
Say 'The payload ran. It tried to phone home. Here is the verdict.'
Step 'Show-EgressDecisions $LAST.sandboxId'
Step 'aca sandbox egress show --id $LAST.sandboxId'
Say 'Watcher terminal: still green. Blast radius = one disposable microVM.'

# --- 2.5 Dispose ---
Step 'Remove-Sandbox $LAST.sandboxId'
