# Demo 4 — Express: same image, two environments, one cold request each. [CUTTABLE]
# Run:  .\demos\demo4-express\demo4.ps1
# Prereq: env loaded; prepare.ps1 ran 10+ minutes ago and NOTHING has called the apps since,
#         so both have scaled to zero.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\shared\env.ps1')
if ($env:EXPRESS_APP -eq '__set_me__' -or $env:CLASSIC_APP -eq '__set_me__') {
    throw 'Demo 4: set EXPRESS_APP and CLASSIC_APP (and run demo4-express\prepare.ps1) first, see the README.'
}

# URL and replica count of both apps. Every `az containerapp` call takes 5–9 s, so all lookups
# run in parallel (~9 s instead of ~25 s one after the other). These reads go through the
# management API and do NOT wake the apps. Returns @{ <app> = { Fqdn; Replicas } }.
function global:Get-AppState([switch]$ReplicasOnly) {
    $rg = $env:ACA_RESOURCE_GROUP
    $work = foreach ($app in $env:EXPRESS_APP, $env:CLASSIC_APP) {
        [pscustomobject]@{ App = $app; Kind = 'Replicas' }
        if (-not $ReplicasOnly) { [pscustomobject]@{ App = $app; Kind = 'Fqdn' } }
    }
    $answers = $work | ForEach-Object -ThrottleLimit 4 -Parallel {
        $value = if ($_.Kind -eq 'Fqdn') {
            az containerapp show --name $_.App --resource-group $using:rg --query properties.configuration.ingress.fqdn -o tsv 2>$null
        } else {
            @(az containerapp replica list --name $_.App --resource-group $using:rg --query '[].name' -o tsv 2>$null | Where-Object { $_ }).Count
        }
        [pscustomobject]@{ App = $_.App; Kind = $_.Kind; Value = $value }
    }
    $state = @{}
    foreach ($app in $env:EXPRESS_APP, $env:CLASSIC_APP) {
        $mine = $answers | Where-Object App -eq $app
        $state[$app] = [pscustomobject]@{
            Fqdn     = ($mine | Where-Object Kind -eq 'Fqdn').Value
            Replicas = [int]($mine | Where-Object Kind -eq 'Replicas').Value
        }
    }
    $state
}

$apps = Get-AppState
$global:ExpressUrl = "https://$($apps[$env:EXPRESS_APP].Fqdn)/healthz"
$global:ClassicUrl = "https://$($apps[$env:CLASSIC_APP].Fqdn)/healthz"

# Replica count per app: 0 = scaled to zero, costing nothing.
function global:Show-Replicas {
    $state = Get-AppState -ReplicasOnly
    foreach ($app in $env:EXPRESS_APP, $env:CLASSIC_APP) {
        $n = $state[$app].Replicas
        Write-Host ("  {0,-20} replicas: {1}" -f $app, $n) -ForegroundColor $(if ($n -eq 0) { 'Cyan' } else { 'Yellow' })
    }
}

# Fire one request at each URL at the same moment; tick until both answer.
function global:Invoke-ColdRace {
    $racers = [ordered]@{ 'Express' = $ExpressUrl; 'Classic (Consumption)' = $ClassicUrl }
    $jobs = foreach ($name in $racers.Keys) {
        Start-ThreadJob -Name $name -ArgumentList $racers[$name] -ScriptBlock {
            param($url)
            curl.exe -s -o NUL --max-time 120 -w '%{http_code} %{time_total}' $url
        }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $done = @{}
    while ($done.Count -lt $jobs.Count) {
        foreach ($j in $jobs) {
            # Thread jobs start as NotStarted: only read a job once it has really finished.
            if (-not $done.ContainsKey($j.Name) -and $j.State -in 'Completed', 'Failed', 'Stopped') {
                $code, $secs = (Receive-Job $j) -split ' '
                $done[$j.Name] = $true
                Write-Host ("`r  {0,-22} HTTP {1} after {2:N2} s          " -f $j.Name, $code, [double]::Parse($secs, [Globalization.CultureInfo]::InvariantCulture)) -ForegroundColor Green
            }
        }
        if ($done.Count -lt $jobs.Count) {
            $waiting = ($jobs | Where-Object { -not $done.ContainsKey($_.Name) }).Name -join ', '
            Write-Host -NoNewline ("`r  … {0} still waiting: {1:N0} s" -f $waiting, $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
            Start-Sleep -Milliseconds 250
        }
    }
    $jobs | Remove-Job -Force
}

# Warm requests: what every request after the first costs.
function global:Invoke-Warm {
    foreach ($pair in @(('Express', $ExpressUrl), ('Classic (Consumption)', $ClassicUrl))) {
        $code, $secs = (curl.exe -s -o NUL -w '%{http_code} %{time_total}' $pair[1]) -split ' '
        Write-Host ("  {0,-22} HTTP {1} after {2:N2} s" -f $pair[0], $code, [double]::Parse($secs, [Globalization.CultureInfo]::InvariantCulture))
    }
}

# --- Presenter pre-check (before anything is on screen): are both apps really cold? ---
# Uses the counts fetched above, so no extra wait.
$warm = @($env:EXPRESS_APP, $env:CLASSIC_APP) | Where-Object { $apps[$_].Replicas -gt 0 }
if ($warm) {
    Write-Host "  (presenter: NOT cold yet: $($warm -join ', '). Something called them in the last ~8 min.)" -ForegroundColor DarkYellow
    if (Ask 'Wait here until both apps are at 0 replicas?') {
        while (@((Get-AppState -ReplicasOnly).Values | Where-Object { $_.Replicas -gt 0 }).Count -gt 0) {
            Write-Host -NoNewline "`r  (waiting for scale to zero… $(Get-Date -Format HH:mm:ss))" -ForegroundColor DarkGray
            Start-Sleep -Seconds 20
        }
        Write-Host "`r  (both at 0 replicas, ready)                    " -ForegroundColor DarkGray
    }
}

# --- 4.1 Same image, two environments, both idle ---
Say 'Same container image, deployed twice: once in an Express environment, once in a regular Consumption one.'
Say 'Nobody has called either for 10+ minutes. Both scaled to zero: no replicas, no compute cost.'
Step 'Show-Replicas'

# --- 4.2 The race ---
Say 'One request to each, at the same moment. A replica has to start before either can answer.'
Step 'Invoke-ColdRace'
Say 'Express starts it on the sandbox microVM layer: about two seconds. Classic does a container cold start.'

# --- 4.3 Warm, and the replicas that appeared ---
# Express is consistently ~0.5 s slower per warm request here (measured: not network, not CPU).
# Say it rather than hide it. Enter = run again; 'n' moves on. Not asked under DEMO_AUTO
# (the default yes would loop forever).
Say 'Now both are warm. Same request again.'
do {
    Step 'Invoke-Warm'
    $again = -not $env:DEMO_AUTO -and (Ask 'Run the warm requests again?' -DefaultYes)
} while ($again)
Say 'Busy API where every millisecond counts: standard, with a replica always on. Mostly idle: Express.'
Step 'Show-Replicas'
Say 'Two seconds ago these cost nothing. Scale from zero in two seconds instead of twenty.'

# After the talk:
#   az containerapp delete --name $env:EXPRESS_APP --resource-group $env:ACA_RESOURCE_GROUP --yes
#   az containerapp delete --name $env:CLASSIC_APP --resource-group $env:ACA_RESOURCE_GROUP --yes
#   az containerapp env delete --name $env:EXPRESS_ENV --resource-group $env:ACA_RESOURCE_GROUP --yes
#   az containerapp env delete --name $env:CLASSIC_ENV --resource-group $env:ACA_RESOURCE_GROUP --yes
