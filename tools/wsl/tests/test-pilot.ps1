# Actual public selection wrapper; only the Linux preparation boundary is a fixture.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../support.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('symphony-pilot-test-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
function Assert($Ok,$Message) { if (-not $Ok) { throw $Message } }
try {
    $installer=Join-Path $root 'installer'
    [IO.Directory]::CreateDirectory($installer) | Out-Null
    $names=@('symphony.ps1','setup.ps1','support.ps1','manager.ps1','operator.ps1','operator.py','provision.py')
    foreach ($name in $names) { [IO.File]::Copy((Join-Path $PSScriptRoot ('../'+$name)),(Join-Path $installer $name)) }
    $fake=@'
param($Action,$Installation,[int]$Issue)
$data=Get-Content -Raw -LiteralPath $Installation | ConvertFrom-Json
if ($Action -ne 'Select-Pilot' -or $Issue -notin @(132,200,201)) { throw 'unexpected_selection' }
$dir=Split-Path -Parent $Installation
if (Test-Path -LiteralPath (Join-Path $dir 'fail')) { throw 'fixture_prepare_failed' }
if ($data.runtime_config.pilot_item_ids.Count -eq 0 -or $data.pilot.issue -ne $Issue) {
    $source=$data.controller.config
    $sourcePilot=@{}
    if ($data.PSObject.Properties['pilot']) { $sourcePilot=$data.pilot }
    $history=@()
    if ($data.PSObject.Properties['pilot_history']) { $history=@($data.pilot_history) }
    $id='{0:x24}' -f $Issue
    $data.controller.config='/fixture/pilot-'+$Issue+'/local.json'
    $data.runtime_config.state_root='/fixture/state-'+$Issue
    $data.runtime_config.pilot_item_ids=@('PVTI_fixture_'+$Issue)
    $data | Add-Member -Force NoteProperty pilot ([pscustomobject]@{issue=$Issue; item_id=('PVTI_fixture_'+$Issue); repo='Example/app'; transition_id=$id})
    $history+=@{id=$id; source_pilot=$sourcePilot; source_config=$source; target_config=$data.controller.config; target_issue=$Issue; evidence=@{kind='completed'}}
    $data | Add-Member -Force NoteProperty pilot_history $history
}
@{installation=$data; execution_started=$false} | ConvertTo-Json -Depth 30
'@
    [IO.File]::WriteAllText((Join-Path $installer 'operator.ps1'),$fake)
    $helpers=@{}
    foreach ($name in $names) { $helpers[$name]=(Get-FileHash -LiteralPath (Join-Path $installer $name) -Algorithm SHA256).Hash.ToLowerInvariant() }
    $id=[Guid]::NewGuid().ToString('N')
    $data=@{installation_id=$id; install_home=$root; controller=@{config='/fixture/local.json'}; runtime_config=@{state_root='/fixture/state';dashboard_port=12345;pilot_item_ids=@()}}
    $descriptor=Join-Path $root 'installation.json'; Write-Json $descriptor $data
    Write-Json (Join-Path $root 'setup.json') @{id=$id; home=$root; helpers=$helpers; stage='complete'}
    $record=Join-Path $root 'manager.json'
    Write-Json $record @{installation_id=$id;pid=$PID;start='0';stopped=$false}
    $wrapper=Join-Path $installer 'symphony.ps1'
    $before=[IO.File]::ReadAllText($descriptor)
    $rejected=$false
    try { & $wrapper Select-Pilot -Issue 132 -Installation $descriptor } catch { $rejected=$_.Exception.Message -like '*Stop before*' }
    Assert $rejected 'Unconfirmed stop allowed selection'
    Write-Json $record @{installation_id=$id;pid=$PID;start='0';stopped=$true}
    [IO.File]::WriteAllText((Join-Path $root 'fail'),'failure')
    $rejected=$false
    try { & $wrapper Select-Pilot -Issue 132 -Installation $descriptor } catch { $rejected=$true }
    Assert $rejected 'Failed preparation was accepted'
    Assert ([IO.File]::ReadAllText($descriptor) -ceq $before) 'Failure changed descriptor'
    Assert (-not (Test-Path -LiteralPath (Join-Path $root 'installation.before-pilot.json'))) 'Failure published backup too early'
    [IO.File]::Delete((Join-Path $root 'fail'))
    & $wrapper Select-Pilot -Issue 132 -Installation $descriptor
    $saved=Read-Json $descriptor
    Assert ($saved.pilot.issue -eq 132 -and $saved.runtime_config.pilot_item_ids.Count -eq 1) 'Incorrect pilot descriptor'
    $backup=Read-Json (Join-Path $root 'installation.before-pilot.json')
    Assert ($backup.controller.config -ceq '/fixture/local.json' -and $backup.runtime_config.pilot_item_ids.Count -eq 0) 'Source backup changed'
    $selected=[IO.File]::ReadAllText($descriptor)
    & $wrapper Select-Pilot -Issue 132 -Installation $descriptor
    Assert ([IO.File]::ReadAllText($descriptor) -ceq $selected) 'Repeated selection changed descriptor'
    & $wrapper Select-Pilot -Issue 200 -Installation $descriptor
    $next=Read-Json $descriptor
    Assert ($next.pilot.issue -eq 200 -and @($next.pilot_history).Count -eq 2) 'Second pilot did not retain history'
    Assert (Same-Json (Read-Json (Join-Path $root 'installation.before-pilot.json')) $backup) 'Legacy backup was replaced'
    $history=Join-Path $root 'pilot-history'
    Assert (@(Get-ChildItem -LiteralPath $history -Filter '*.json').Count -eq 2) 'Transition history incomplete'
    $transition=Read-Json (Join-Path $history ($next.pilot.transition_id+'.json'))
    $pending=Join-Path $root 'pilot-selection.pending.json'
    # Crash before descriptor replacement: the same command must finish the prepared transition.
    Write-Json $descriptor $transition.before
    Write-Json $pending $transition
    $rejected=$false
    try { & $wrapper Select-Pilot -Issue 201 -Installation $descriptor } catch { $rejected=$_.Exception.Message -like '*pending*' }
    Assert $rejected 'A pending transition forked into a different issue'
    $rejected=$false
    try { & $wrapper Start -Execute -Installation $descriptor } catch { $rejected=$_.Exception.Message -like '*pending*' }
    Assert $rejected 'Start bypassed the pending transition'
    & $wrapper Select-Pilot -Issue 200 -Installation $descriptor
    Assert (Same-Json (Read-Json $descriptor) $next) 'Retry before descriptor replacement changed target'
    Assert (-not (Test-Path -LiteralPath $pending)) 'Pending transition was not completed'
    # Crash after descriptor replacement: repeat finishes bookkeeping without another profile.
    Write-Json $pending $transition
    & $wrapper Select-Pilot -Issue 200 -Installation $descriptor
    Assert (-not (Test-Path -LiteralPath $pending)) 'Retry after descriptor replacement remained pending'
    Assert (@(Get-ChildItem -LiteralPath $history -Filter '*.json').Count -eq 2) 'Retry duplicated history'
    $lock=Enter-InstallationLock $id
    try {
        $powershell=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $output=& { $ErrorActionPreference='Continue'; & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $wrapper Select-Pilot -Issue 201 -Installation $descriptor 2>&1; $script:selectionExit=$LASTEXITCODE }
        Assert ($selectionExit -ne 0) 'Concurrent process acquired the installation'
    } finally { $lock.ReleaseMutex(); $lock.Dispose() }
    Assert (Same-Json (Read-Json $descriptor) $next) 'Concurrent selection changed descriptor'
    $tampered=Read-Json $descriptor
    $tampered.runtime_config.dashboard_port=54321
    $rejected=$false
    try { Assert-PilotTransition $transition.before $tampered 200 } catch { $rejected=$true }
    Assert $rejected 'A selection changed unrelated runtime settings'
    Write-Host 'PASS sequential pilots, history, stop guard, pending recovery before/after commit, idempotency and concurrent exclusion'
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -cne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($resolved) -notmatch '^symphony-pilot-test-[0-9a-f]{32}$') { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
