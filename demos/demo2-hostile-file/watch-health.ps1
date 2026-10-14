# WATCHER terminal for Demo 2: polls the middleware's /healthz once a second.
# The line stays green the whole time a hostile file is being handled.
. (Join-Path $PSScriptRoot '..\shared\env.ps1')
while ($true) {
    $t = Get-Date -Format 'HH:mm:ss'
    try {
        $r = Invoke-WebRequest "$env:MIDDLEWARE_URL/healthz" -TimeoutSec 2
        Write-Host "$t  $($r.StatusCode) healthy" -ForegroundColor Green
    }
    catch {
        Write-Host "$t  DOWN  $($_.Exception.Message)" -ForegroundColor Red
    }
    Start-Sleep -Seconds 1
}
