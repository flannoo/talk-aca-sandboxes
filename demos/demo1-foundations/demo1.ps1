# Demo 1 — Foundations: the vocabulary demo.
# Run:  .\demos\demo1-foundations\demo1.ps1   (Enter runs the next step; 's' skips, 'q' quits)
# Prereq: . .\demos\shared\env.ps1 and a green `aca doctor`.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\shared\env.ps1')
$here = $PSScriptRoot

# GET a URL, retrying while the app inside the sandbox is still starting (first run compiles).
function global:Wait-Url([string]$Url, [int]$TimeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        try { return Invoke-RestMethod $Url -TimeoutSec 10 }
        catch {
            if ((Get-Date) -gt $deadline) { throw }
            Write-Host -NoNewline '.' -ForegroundColor DarkGray
            Start-Sleep -Seconds 2
        }
    }
}

# --- 1.1 The group already exists (ARM control plane) ---
Say 'The group is the management boundary — like a Container Apps environment.'
Step 'aca sandboxgroup list'
Step 'aca sandboxgroup get --name $env:ACA_SANDBOX_GROUP'

# --- 1.2 Disks: public ones, or your own converted from a container image ---
Say 'Disks are what sandboxes boot from. Microsoft publishes some...'
Step 'aca sandboxgroup disk list-public'
Say '...but dotnet-10 is runtime-only. So I converted the official SDK container image into my own disk:'
Say '  aca sandboxgroup disk create --image mcr.microsoft.com/dotnet/sdk:10.0 --name dotnet10-sdk'
Step 'aca sandboxgroup disk list'
Step '$SBX = New-Sandbox --disk-id $env:DEMO_DISK_ID --label name=demo1; $SBX'

# --- 1.2b The CLI hides the service's speed: every call starts up and fetches a token. ---
$cliSeconds = $StepSeconds
$took = if ($cliSeconds) { '{0:N1} s' -f $cliSeconds } else { 'A second or two' }
Say "$took. Much of that is the CLI itself: it starts up and fetches a fresh token on every call. Same create, straight at the API:"
Get-SandboxToken | Out-Null   # fetch + cache the token off-screen, before the stopwatch
# Collect what the two direct creates measured (a skipped step adds nothing).
$direct = foreach ($i in 1..2) {
    $global:LastStartMs = $null
    Step 'Measure-Create -DiskId $env:DEMO_DISK_ID'
    if ($LastStartMs) { $LastStartMs / 1000 }
}
if ($direct) {
    $m = $direct | Measure-Object -Minimum -Maximum
    $lo, $hi = $m.Minimum, $m.Maximum
    $api = if (('{0:N1}' -f $lo) -eq ('{0:N1}' -f $hi)) { '{0:N1} s' -f $lo } else { '{0:N1}–{1:N1} s' -f $lo, $hi }
    $vs = if ($cliSeconds) { (' vs {0:N1} s through the CLI' -f $cliSeconds) } else { '' }
    Say "$api straight at the API$vs, from a prewarmed pool. That is the number a service sees. Forking from a snapshot is faster still: Demo 2."
}
else { Say 'Straight at the API, from a prewarmed pool: that is the number a service sees. Forking from a snapshot is faster still: Demo 2.' }
Step 'Remove-SandboxesByLabel name=create'
Step 'aca sandbox exec --id $SBX -c "uname -a && nproc && free -m && dotnet --version"'

# --- 1.3 Files in and out: no SSH, no SCP ---
Say 'No SSH daemon. File transport is a data-plane verb.'
Step 'aca sandbox fs write --id $SBX --path /work/hello.cs --file "$here\hello.cs"'
Step 'aca sandbox fs cat --id $SBX --path /work/hello.cs'

# --- 1.4 Expose a port: a .NET 10 single-file web app ---
Say 'dotnet run on a single .cs file — .NET 10 file-based apps.'
Step 'aca sandbox exec --id $SBX --working-directory /work -c "nohup dotnet run hello.cs > /tmp/web.log 2>&1 &"'
Step '$URL = (Invoke-AcaJson sandbox port add --id $SBX --port 8080 --anonymous).url; $URL'
Say 'First run compiles the app, so it waits until the app answers.'
Step 'Wait-Url $URL | Format-List'
Say '--anonymous = anyone with the URL. Real work: --email <you@contoso.com>.'
Step 'aca sandbox port remove --id $SBX --port 8080'

# --- 1.5 Suspend and resume: memory AND disk survive ---
Say 'Stop keeps memory and disk. Suspended = storage cost only.'
Step 'aca sandbox stop --id $SBX'
Step 'aca sandbox get --id $SBX'
Step 'aca sandbox resume --id $SBX'
Step 'aca sandbox exec --id $SBX -c "ls -la /work && pgrep -a dotnet"'

# --- 1.6 Portal (alt-tab): https://containerapps.azure.com/sandbox-groups ---
Say 'Portal for eyeballing, CLI for anything you automate.'

# Leave demo1 running for the portal; clean up in the wrap:
#   aca sandbox delete -l name=demo1 --yes
