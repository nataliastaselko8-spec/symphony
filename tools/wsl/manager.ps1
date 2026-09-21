param([Parameter(Mandatory=$true)][string]$Installation, [switch]$Execute)
. (Join-Path $PSScriptRoot 'support.ps1')
$data = Read-Json $Installation
if ($data.installation_id -notmatch '^[0-9a-f]{32}$') { throw 'Invalid installation identity.' }
$mutex = $null
$locked = $false
$controller = $null
$keeper = $null
$recordPath = Join-Path $data.install_home 'manager.json'
$stopPath = Join-Path $data.install_home 'stop-request.json'
$record = [ordered]@{
    installation_id=$data.installation_id; pid=$PID; start=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks.ToString()
    token=[Guid]::NewGuid().ToString('N'); phase='starting'; stopped=$false; reason=$null
}
try {
    $mutex = Enter-InstallationLock $data.installation_id
    $locked = $true
    Verify-Helpers (Read-Json (Join-Path $data.install_home 'setup.json'))
    $selected = @($data.runtime_config.pilot_item_ids).Count
    if (($selected -gt 0 -and -not $Execute) -or ($Execute -and $selected -ne 1)) { throw 'explicit_single_pilot_execution_required' }
    Write-Json $recordPath $record
    $keeper = New-WorkerKeeper $data
    $powershell = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $operator = Join-Path $PSScriptRoot 'operator.ps1'
    $baseArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$operator)
    $prime = Invoke-Native $powershell ($baseArgs + @('Prime','-Installation',$Installation)) | ConvertFrom-Json
    $arguments = @('-d',$data.controller.distro,'-u',$data.controller.user,'--cd','/','--exec','python3','-I','-B',
                   $prime.script,'--installation',$prime.installation,'start','--supervised')
    if ($Execute) { $arguments += '--execute' }
    $controller = New-NativeProcess (Wsl-Path) $arguments -Redirect
    $drains = Start-LogDrain $controller $data.install_home
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    while (-not $controller.HasExited) {
        if ($keeper.HasExited) { throw 'worker_keepalive_lost' }
        $controller.StandardInput.Write("ALIVE`n")
        $controller.StandardInput.Flush()
        if (Test-Path -LiteralPath $stopPath) {
            $request = Read-Json $stopPath
            if ($request.token -ceq $record.token -and $request.installation_id -ceq $data.installation_id) { break }
        }
        if ($record.phase -eq 'starting') {
            try {
                if ((Test-DashboardReady $data.runtime_config.dashboard_port) -and -not $controller.HasExited) {
                    $record.phase = 'ready'
                    Write-Json $recordPath $record
                }
            } catch {}
            if ($record.phase -eq 'starting' -and [DateTime]::UtcNow -gt $deadline) { throw 'dashboard_start_timeout' }
        }
        Start-Sleep -Seconds 3
    }
    $record.phase = 'stopping'
    Write-Json $recordPath $record
    Invoke-Native $powershell ($baseArgs + @('Stop','-Installation',$Installation)) -TimeoutSeconds 300 | Out-Null
    $record.phase = 'stopped'
    $record.stopped = $true
} catch {
    if ($locked) {
        $record.phase = 'attention-required'
        $message = $_.Exception.Message
        $record.reason = $(if ($message -match '^[a-zA-Z0-9_:-]{1,200}$') { $message } else { 'manager_failed_check_private_logs_and_run_Doctor' })
    }
} finally {
    if ($null -ne $controller) {
        # EOF requests a graceful runtime shutdown even if the manager failed.
        try { $controller.StandardInput.Close() } catch {}
        if (-not $record.stopped) {
            try { $null = $controller.WaitForExit(125000) } catch {}
        }
        $controller.Dispose()
    }
    if ($locked -and $null -ne $keeper -and -not $record.stopped) {
        # Keep the worker distro alive through the stop proof after a failed
        # startup. A failure remains visible even if cleanup was confirmed.
        try {
            Invoke-Native $powershell ($baseArgs + @('Stop','-Installation',$Installation)) -TimeoutSeconds 300 | Out-Null
            $record.stopped = $true
        } catch {}
    }
    if ($null -ne $keeper) { try { $keeper.StandardInput.Close() } catch {}; $keeper.Dispose() }
    if ($locked) { Write-Json $recordPath $record; $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
