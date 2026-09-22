[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('Setup','Update','Rollback-Update','Start','Stop','Status','Doctor','Check','Login','Models','Select-Model','Select-Pilot','Token','Open')]
    [string]$Action = 'Status',
    [string]$Installation, [string]$Bundle, [string]$BundleSha256, [string]$InstallRoot,
    [string]$Model, [string]$Effort, [switch]$SkipLogin, [int]$Issue, [switch]$Execute
)
. (Join-Path $PSScriptRoot 'support.ps1')
if (($Model -or $Effort) -and $Action -ne 'Select-Model') { throw 'Model and Effort are only supported by Select-Model.' }
if ($Action -eq 'Select-Model' -and (-not $Model -or -not $Effort)) { throw 'Select-Model requires both -Model and -Effort.' }
if ($Execute -and $Action -ne 'Start') { throw '-Execute is only supported by Start.' }
if (($Action -eq 'Select-Pilot' -and $Issue -le 0) -or ($PSBoundParameters.ContainsKey('Issue') -and $Action -ne 'Select-Pilot')) { throw 'Select-Pilot requires a positive -Issue number; other commands do not accept Issue.' }
if ($Action -eq 'Setup') {
    & (Join-Path $PSScriptRoot 'setup.ps1') -Bundle $Bundle -BundleSha256 $BundleSha256 -InstallRoot $InstallRoot -SkipLogin:$SkipLogin
    return
}
if ($Action -in @('Update','Rollback-Update')) {
    if ($InstallRoot -or $SkipLogin) { throw 'InstallRoot and SkipLogin are only allowed with Setup.' }
    & (Join-Path $PSScriptRoot 'update.ps1') -Installation $Installation -Bundle $Bundle -BundleSha256 $BundleSha256 -Rollback:($Action -eq 'Rollback-Update')
    return
}
if ($Bundle -or $BundleSha256 -or $InstallRoot -or $SkipLogin) { throw 'Setup options are only allowed with Setup.' }
$Installation = Get-InstallationFile $Installation
$data = Read-Json $Installation
if ($data.installation_id -notmatch '^[0-9a-f]{32}$' -or [IO.Path]::GetFullPath($Installation) -ine (Join-Path $data.install_home 'installation.json')) {
    throw 'Run the full installer. Legacy machine descriptors are not imported.'
}
$state = Read-Json (Join-Path $data.install_home 'setup.json')
$operator = Join-Path (Get-HelperRoot $state) 'operator.ps1'
if ($state.id -cne $data.installation_id -or $state.home -ine $data.install_home) { throw 'Installation scope mismatch.' }
Verify-Helpers $state
if (($state.stage -eq 'update-pending' -or (Test-Path -LiteralPath (Join-Path $data.install_home 'update.pending.json')) -or (Test-Path -LiteralPath (Join-Path $data.install_home 'rollback.pending.json'))) -and $Action -notin @('Stop','Status','Doctor')) { throw 'Finish the pending Update before using this installation.' }
$manager = Get-Manager $data
$recordPath = Join-Path $data.install_home 'manager.json'
$url = 'http://localhost:' + $data.runtime_config.dashboard_port
if ($Action -eq 'Select-Pilot') {
    if ($state.stage -ne 'complete') { throw 'Finish Setup before selecting a pilot.' }
    $lockedId = $data.installation_id
    $lockedHome = $data.install_home
    $selectionLock = Enter-InstallationLock $data.installation_id
    try {
        # Read again under the same lock as manager; the descriptor may have changed before acquisition.
        $data = Read-Json $Installation
        if ($data.installation_id -cne $lockedId -or $data.install_home -ine $lockedHome) { throw 'Installation identity changed; retry selection.' }
        $manager = Get-Manager $data
        if ($null -ne $manager -or -not (Test-Path -LiteralPath $recordPath) -or (Read-Json $recordPath).stopped -ne $true) { throw 'Run Symphony.cmd Stop before selecting a pilot.' }
        $pending = Join-Path $data.install_home 'pilot-selection.pending.json'
        if (Test-Path -LiteralPath $pending) {
            $transition = Read-Json $pending
            if ($transition.after.pilot.issue -ne $Issue -or
                -not ((Same-Json $data $transition.before) -or (Same-Json $data $transition.after))) {
                throw 'Finish the pending Select-Pilot transition before selecting another issue.'
            }
        }
        $result = (& $operator Select-Pilot -Installation $Installation -Issue $Issue | Out-String) | ConvertFrom-Json
        $proposed = $result.installation
        if ($result.execution_started -ne $false -or $proposed.installation_id -cne $data.installation_id -or
            $proposed.install_home -ine $data.install_home -or @($proposed.runtime_config.pilot_item_ids).Count -ne 1 -or
            $proposed.pilot.issue -ne $Issue -or $proposed.runtime_config.pilot_item_ids[0] -cne $proposed.pilot.item_id) { throw 'Invalid pilot selection result; descriptor was preserved.' }
        Publish-PilotSelection $Installation $data $proposed $Issue
        Write-Host ('Pilot selected: ' + $proposed.pilot.repo + ' #' + $Issue)
        Write-Host 'No task started. Previous profile preserved. Run Symphony.cmd Start -Execute, then confirm the dev baseline in the dashboard.'
    } finally { $selectionLock.ReleaseMutex(); $selectionLock.Dispose() }
    return
}
if ($Action -in @('Start','Open')) {
    if (Test-Path -LiteralPath (Join-Path $data.install_home 'pilot-selection.pending.json')) { throw 'Finish the pending Select-Pilot command before Start.' }
    $startedManager = $null
    if ($state.stage -ne 'complete') { throw ('Finish Setup first. Last stage: ' + $state.stage) }
    if ($Action -eq 'Open' -and $null -eq $manager) { throw 'Dashboard is stopped. Use Symphony.cmd Start.' }
    if ($Action -eq 'Start' -and $null -eq $manager) {
        $selected = @($data.runtime_config.pilot_item_ids).Count
        if ($selected -gt 0 -and -not $Execute) { throw 'A pilot is selected. Use Symphony.cmd Start -Execute to allow this task.' }
        if ($Execute -and $selected -ne 1) { throw 'Select one pilot first: Symphony.cmd Select-Pilot -Issue NUMBER.' }
        if ((Test-Path -LiteralPath $recordPath) -and -not (Read-Json $recordPath).stopped) { throw 'The previous stop is unconfirmed. Run Stop to reconcile it, then Start.' }
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, [int]$data.runtime_config.dashboard_port)
        try { $listener.Start() } finally { $listener.Stop() }
        $file = Join-Path (Get-HelperRoot $state) 'manager.ps1'
        $powershell = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$file,'-Installation',$Installation)
        if ($Execute) { $arguments += '-Execute' }
        Write-Host 'Starting Symphony; waiting for the local dashboard...'
        $startedManager = Start-Process -FilePath $powershell -ArgumentList (@($arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' ') -WindowStyle Hidden -PassThru
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(100)
    do {
        $manager = Get-Manager $data
        if ($null -ne $manager -and $manager.phase -eq 'ready') { Start-Process -FilePath $url; Write-Host $url; return }
        if ($null -ne $manager -and $manager.phase -eq 'attention-required') { throw 'Startup requires attention. Run Symphony.cmd Doctor.' }
        # The previous failure record remains until the new process takes the
        # installation lock and writes its identity. Do not report it as a new failure.
        if ($null -eq $manager -and ($null -eq $startedManager -or $startedManager.HasExited) -and
            (Test-Path -LiteralPath $recordPath) -and (Read-Json $recordPath).phase -eq 'attention-required') { throw 'Startup failed. Run Symphony.cmd Doctor to inspect the saved reason.' }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Dashboard readiness was not confirmed. Run Symphony.cmd Doctor.'
}
if ($Action -eq 'Stop' -and $null -ne $manager) {
    Write-Json (Join-Path $data.install_home 'stop-request.json') @{installation_id=$data.installation_id; token=$manager.token}
    $deadline = [DateTime]::UtcNow.AddSeconds(300)
    do {
        $record = Read-Json (Join-Path $data.install_home 'manager.json')
        if ($record.token -cne $manager.token) { throw 'Manager identity changed during stop.' }
        if ($record.stopped -eq $true) { Write-Host 'Controller and worker stopped. Workspaces preserved.'; return }
        if ($record.phase -eq 'attention-required') { throw 'Stop is unconfirmed. Run Doctor; workspaces are preserved.' }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Stop deadline expired. Workspaces are preserved; run Doctor.'
}
if ($Action -in @('Doctor','Status')) {
    $last = $(if (Test-Path -LiteralPath $recordPath) { Read-Json $recordPath } else { $null })
    [pscustomobject]@{installation=$data.installation_id; setup_stage=$state.stage; setup_status=$state.status; manager=$manager; last_manager=$last; dashboard=$url} | ConvertTo-Json -Depth 8
    & $operator Status -Installation $Installation
    if ($Action -eq 'Doctor') { & $operator Check -Installation $Installation }
    return
}
if ($Action -eq 'Stop') {
    if ((Test-Path -LiteralPath $recordPath) -and (Read-Json $recordPath).stopped -eq $true) { Write-Host 'The previous shutdown was confirmed.'; return }
}
if ($null -ne $manager -and $Action -in @('Login','Models','Select-Model')) { throw 'Stop this installation before maintenance.' }
$extra = @{}
if ($Model) { $extra.Model = $Model }
if ($Effort) { $extra.Effort = $Effort }
$mutex = $null
$keeper = $null
try {
    if ($Action -in @('Login','Models','Select-Model','Stop')) {
        $mutex = Enter-InstallationLock $data.installation_id
        $keeper = New-WorkerKeeper $data
        if ($Action -in @('Stop','Select-Model')) { & $operator Prime -Installation $Installation | Out-Null }
    }
    & $operator $Action -Installation $Installation @extra
    if ($Action -in @('Login','Models','Select-Model')) { & $operator Stop -Installation $Installation }
    if ($Action -eq 'Stop' -and (Test-Path -LiteralPath $recordPath)) {
        $record = Read-Json $recordPath
        $record.stopped = $true
        $record.phase = 'stopped'
        Write-Json $recordPath $record
    }
} finally {
    if ($null -ne $keeper) { $keeper.StandardInput.Close(); $keeper.Dispose() }
    if ($null -ne $mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
