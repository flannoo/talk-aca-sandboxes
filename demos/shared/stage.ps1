# Stage helpers, loaded by env.ps1.

# Show a command in green, wait for a keypress, then run it.
# Enter (or any key) runs it, 's' skips the step, 'q' stops the script.
# $env:DEMO_AUTO = '1' runs every step without waiting (rehearsal / smoke test).
# $StepSeconds holds the last step's elapsed time ($null if it was skipped), for cue lines.
function Step {
    param([Parameter(Mandatory)][string]$Command)
    $global:StepSeconds = $null
    Write-Host ''
    Write-Host "PS> $Command" -ForegroundColor Green -NoNewline
    if ($env:DEMO_AUTO) { Write-Host '' }
    else {
        Write-Host '   [Enter]' -ForegroundColor DarkGray
        Clear-KeyBuffer
        $key = [Console]::ReadKey($true).KeyChar
        if ($key -eq 'q') { throw 'stopped by presenter' }
        if ($key -eq 's') { Write-Host '(skipped)' -ForegroundColor DarkGray; return }
        # Printed the moment the key lands, so a slow step never looks like a missed Enter.
        Write-Host '  ▸ running…' -ForegroundColor DarkGray
    }
    # Shown as `$X = ...` for readability; stored globally so later steps can use $X.
    $run = $Command -replace '^\$(\w+)\s*=', '$global:$1 ='
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # A failing step shows its error and the script carries on: never lose the stage to one call.
    try { Invoke-Expression $run | Out-Host }
    catch { Write-Host "  ✗ $($_.Exception.Message)" -ForegroundColor Red }
    $global:StepSeconds = $sw.Elapsed.TotalSeconds
    Write-Host ("  ({0:N1}s)" -f $StepSeconds) -ForegroundColor DarkGray
}

# Drop keys pressed while the previous step was still running (an impatient second Enter),
# so they can't run or skip the next step. Only keys pressed after the prompt count.
function Clear-KeyBuffer {
    if ([Console]::IsInputRedirected) { return }
    while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }
}

# Speaker cue on screen (yellow), no execution.
function Say {
    param([string]$Text)
    Write-Host ''
    Write-Host "# $Text" -ForegroundColor Yellow
}

# Yes/no question for the presenter (single keypress). Enter takes the default:
# no, unless -DefaultYes. Under $env:DEMO_AUTO it answers the default by itself.
function Ask {
    param([string]$Question, [switch]$DefaultYes)
    Write-Host ''
    Write-Host ("? $Question {0} " -f $(if ($DefaultYes) { '[Y/n]' } else { '[y/N]' })) -ForegroundColor Magenta -NoNewline
    if ($env:DEMO_AUTO) { Write-Host '(auto)'; return [bool]$DefaultYes }
    Clear-KeyBuffer
    $key = [string][Console]::ReadKey($true).KeyChar
    Write-Host $key
    if ($DefaultYes) { return $key -notin 'n', 'N' }
    return $key -in 'y', 'Y'
}

# `aca ... -o json` parsed into objects. Throws on non-zero exit.
# Some verbs (e.g. create) print progress lines like "Creating sandbox <id>..." before
# the JSON even with -o json, so parse from the first line that starts JSON.
function Invoke-AcaJson {
    $out = @(& aca @args -o json)
    if ($LASTEXITCODE -ne 0) { throw "aca $($args -join ' ') failed ($LASTEXITCODE)" }
    $start = [array]::FindIndex([string[]]$out, [Predicate[string]] { param($l) $l -match '^\s*[\[{]' })
    if ($start -lt 0) { return [pscustomobject]@{ raw = ($out -join "`n") } }
    ($out[$start..($out.Count - 1)] -join "`n") | ConvertFrom-Json
}

# Create a sandbox and return its id. Pass extra aca flags as-is.
function New-Sandbox {
    $r = Invoke-AcaJson sandbox create @args
    if ($r.id) { return $r.id }
    # No JSON body: take the id from the progress line.
    if ($r.raw -match '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}') { return $Matches[0] }
    throw "could not read a sandbox id from: $($r.raw)"
}

# --- Direct data-plane calls with ONE cached token (what the CLI can't show you) ---

function Get-SandboxToken {
    if ($global:SbxToken -and (Get-Date) -lt $global:SbxTokenExpires) { return $global:SbxToken }
    $t = az account get-access-token --resource https://dynamicsessions.io -o json | ConvertFrom-Json
    $global:SbxToken = $t.accessToken
    $global:SbxTokenExpires = [DateTimeOffset]::FromUnixTimeSeconds([long]$t.expires_on).LocalDateTime.AddMinutes(-5)
    $global:SbxToken
}

function Get-SandboxApiBase {
    "https://management.$env:ACA_REGION.azuredevcompute.io/subscriptions/$env:ACA_SUBSCRIPTION" +
    "/resourceGroups/$env:ACA_RESOURCE_GROUP/sandboxGroups/$env:ACA_SANDBOX_GROUP/sandboxes"
}

# Start a sandbox straight against the REST API and time ONLY the service call.
# The token is fetched (and cached) before the stopwatch starts.
#   Measure-Create -DiskId $env:DEMO_DISK_ID      # create: boot a disk image, cold
#   Measure-Fork -Snapshot parser-warm            # fork: a new microVM in a snapshot's saved memory + disk
function Measure-Create {
    # Defaults mirror `aca sandbox create` (1 vCPU / 2 GiB, no egress policy), so Demo 1
    # compares the CLI with the direct call and nothing else. -DenyEgress adds a Deny policy.
    param([Parameter(Mandatory)][string]$DiskId, [string]$Label = 'create',
          [string]$Cpu = '1000m', [string]$Memory = '2048Mi', [switch]$DenyEgress)
    $global:CREATED = Measure-SandboxStart -DiskId $DiskId -Label $Label -Cpu $Cpu -Memory $Memory -AllowEgress:(-not $DenyEgress)
}
function Measure-Fork {
    param([Parameter(Mandatory)][string]$Snapshot, [string]$Label = 'fork')
    $global:FORK = Measure-SandboxStart -Snapshot $Snapshot -Label $Label
}
# A data-plane URL fit for the projector: subscription masked, and when the line would wrap,
# only the parts that matter (data-plane host, sandbox group, api-version).
function Format-SandboxUrl([string]$Url, [int]$Width) {
    $Url = $Url -replace '(/subscriptions/[0-9a-f]{8})[0-9a-f-]+', '$1-…'
    if (-not $Width) { $Width = try { $Host.UI.RawUI.WindowSize.Width } catch { 0 } }
    if (-not $Width) { $Width = 120 }
    # 6 = the "  PUT " in front of it.
    if ($Url.Length + 6 -le $Width) { return $Url }
    $short = $Url -replace '/subscriptions/.+?/sandboxGroups/', '/…/sandboxGroups/'
    if ($short.Length + 6 -le $Width) { return $short }
    return $short -replace '\?.*$', ''
}
function Measure-SandboxStart {
    param([string]$DiskId, [string]$Snapshot, [string]$Label, [string]$Cpu, [string]$Memory, [switch]$AllowEgress)
    $headers = @{ Authorization = "Bearer $(Get-SandboxToken)" }
    $source = if ($Snapshot) {
        $snap = @(Invoke-AcaJson sandboxgroup snapshot list) | Where-Object { $_.labels.name -eq $Snapshot } | Select-Object -First 1
        if (-not $snap) { throw "snapshot '$Snapshot' not found" }
        @{ snapshot = @{ id = $snap.id } }
    } else { @{ diskImage = @{ id = $DiskId } } }
    $body = @{ labels = @{ name = $Label }; sourcesRef = $source }
    if (-not $AllowEgress) { $body.egressPolicy = @{ defaultAction = 'Deny' } }
    # A disk create must state its size (the CLI fills in a default); a snapshot carries its own.
    if (-not $Snapshot) { $body.resources = @{ cpu = $Cpu; memory = $Memory } }
    $body = $body | ConvertTo-Json -Depth 5
    $uri = "$(Get-SandboxApiBase)?api-version=$env:SANDBOX_API_VERSION"
    Write-Host "  PUT $(Format-SandboxUrl $uri)" -ForegroundColor DarkGray   # shown before the stopwatch starts

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -Body $body -ContentType 'application/json' -ErrorAction Stop
    $polls = 0
    while ($r.state -ne 'Running' -and $sw.Elapsed.TotalSeconds -lt 60) {
        $r = Invoke-RestMethod -Uri "$(Get-SandboxApiBase)/$($r.id)?api-version=$env:SANDBOX_API_VERSION" -Headers $headers -ErrorAction Stop
        $polls++
    }
    $ms = $sw.Elapsed.TotalMilliseconds
    $global:LastStartMs = $ms   # for cue lines
    $from = if ($Snapshot) { "forked from snapshot '$Snapshot'" } else { 'created from disk' }
    $calls = if ($polls) { "PUT + $polls status check$(if ($polls -gt 1) { 's' })" } else { 'one REST call' }
    Write-Host ("  sandbox {0} is {1} after {2:0} ms  ({3}, {4}, cached token)" -f $r.id, $r.state, $ms, $from, $calls) -ForegroundColor Cyan
    $r.id
}

# Egress decisions as a readable table, denied first.
function Show-EgressDecisions {
    param([Parameter(Mandatory)][string]$Id)
    $d = (Invoke-AcaJson sandbox egress decisions --id $Id).networkEgress
    $rows = @($d.denied | ForEach-Object { $_ | Add-Member -PassThru verdict 'DENIED' }) +
            @($d.allowed | ForEach-Object { $_ | Add-Member -PassThru verdict 'allowed' })
    if (-not $rows) { Write-Host '(no egress attempts recorded)' -ForegroundColor DarkGray; return }
    $rows | Sort-Object timestamp | Format-Table @{ n = 'time'; e = { ([datetime]$_.timestamp).ToLocalTime().ToString('HH:mm:ss') } },
        verdict, method, host, path -AutoSize | Out-Host
}

# Delete a sandbox in the background. Even `delete --no-wait` takes ~8 s to return,
# which is dead air on stage.
function Remove-Sandbox {
    param([Parameter(Mandatory)][string]$Id)
    # The service-side DELETE of a running sandbox itself blocks ~6 s (REST or CLI alike).
    # A delete that lands while the sandbox is suspending (auto-suspend) fails, so retry a few
    # times; nobody sees the background errors, and a missed delete leaves a box behind.
    $retry = "foreach (`$i in 1..6) { aca sandbox delete --id $Id --yes *> `$null; if (`$LASTEXITCODE -eq 0) { break }; Start-Sleep 5 }"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($retry))
    Start-Process pwsh -ArgumentList '-NoProfile', '-EncodedCommand', $enc -WindowStyle Hidden
    Write-Host "deleting $Id (background)" -ForegroundColor DarkGray
}

# Delete every sandbox with a label selector (selector delete only matches one).
function Remove-SandboxesByLabel {
    param([Parameter(Mandatory)][string]$Selector)
    foreach ($s in @(Invoke-AcaJson sandbox list -l $Selector)) { Remove-Sandbox $s.id }
}
