# Demo launcher: pick a demo from a menu, come back to the menu when it ends.
# Run:  .\start-demos.ps1   (from the repo root, PowerShell 7)
# Inside a demo the usual keys apply: Enter runs a step, 's' skips, 'q' stops the demo.
# When a demo ends its output stays on screen until you press 'm' for the menu.
$demos = Join-Path $PSScriptRoot 'demos'

# One keypress. Falls back to a line of input when stdin is redirected (scripted test runs);
# $null there means the input ran out.
function Read-Choice {
    if ([Console]::IsInputRedirected) { return [Console]::In.ReadLine() }
    return [string][Console]::ReadKey($true).KeyChar
}

function Clear-Screen { if (-not [Console]::IsOutputRedirected) { Clear-Host } }

function Show-Menu {
    Clear-Screen
    Write-Host ''
    Write-Host '  Into the sandbox' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  1  Demo 1  Foundations              group, disk, create, exec, fs, port, stop/resume'
    Write-Host '  2  Demo 2  Hostile partner file     opens the API + WATCHER tabs if the API is down'
    Write-Host '  3  Demo 3  AI mapping agent         live model or recorded replay'
    Write-Host '  4  Demo 4  Express cold-start race  apps must have been idle 10+ min'
    Write-Host ''
    Write-Host '  q  Quit' -ForegroundColor DarkGray
    if ($env:DEMO_AUTO) {
        Write-Host ''
        Write-Host '  DEMO_AUTO is set: demos run without waiting for Enter. Remove-Item Env:DEMO_AUTO before presenting.' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '  Choice: ' -NoNewline -ForegroundColor Magenta
}

function Invoke-Demo([string]$Script, [hashtable]$Parameters = @{}) {
    Clear-Screen
    try { & (Join-Path $demos $Script) @Parameters }
    catch {
        # 'q' inside a demo throws 'stopped by presenter': that's a normal way out.
        if ($_.Exception.Message -ne 'stopped by presenter') { Write-Host "  ✗ $($_.Exception.Message)" -ForegroundColor Red }
    }
    # The screen stays as it is until 'm': an Enter out of habit (or one still in the input
    # buffer from the last step) must not clear what the room is looking at.
    if (-not [Console]::IsInputRedirected) { while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null } }
    Write-Host ''
    Write-Host '  Demo finished. Press m for the menu.' -ForegroundColor Yellow -NoNewline
    do { $key = Read-Choice } until ($key -eq 'm' -or $null -eq $key)
}

while ($true) {
    Show-Menu
    $choice = Read-Choice
    if ($null -eq $choice) { return }
    Write-Host $choice
    switch ($choice) {
        '1' { Invoke-Demo 'demo1-foundations\demo1.ps1' }
        '2' { Invoke-Demo 'demo2-hostile-file\demo2.ps1' }
        '3' {
            Write-Host ''
            Write-Host '  Demo 3:  l  live model (Foundry)   r  recorded replay (sandboxes stay live)   any other key: back' -ForegroundColor Magenta
            Write-Host '  Choice: ' -NoNewline -ForegroundColor Magenta
            $mode = Read-Choice
            Write-Host $mode
            if ($mode -eq 'l') { Invoke-Demo 'demo3-ai-agent\demo3.ps1' }
            elseif ($mode -eq 'r') { Invoke-Demo 'demo3-ai-agent\demo3.ps1' @{ Replay = $true } }
        }
        '4' { Invoke-Demo 'demo4-express\demo4.ps1' }
        'q' { return }
    }
}
