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
if ($Action -ne 'Select-Pilot' -or $Issue -ne 132) { throw 'unexpected_selection' }
$dir=Split-Path -Parent $Installation
if (Test-Path -LiteralPath (Join-Path $dir 'fail')) { throw 'fixture_prepare_failed' }
if ($data.runtime_config.pilot_item_ids.Count -eq 0) {
    $data.controller.config='/fixture/pilot/local.json'
    $data.runtime_config.pilot_item_ids=@('PVTI_fixture')
    $data | Add-Member NoteProperty pilot ([pscustomobject]@{issue=132; item_id='PVTI_fixture'; repo='Example/app'})
}
@{installation=$data; execution_started=$false} | ConvertTo-Json -Depth 30
'@
    [IO.File]::WriteAllText((Join-Path $installer 'operator.ps1'),$fake)
    $helpers=@{}
    foreach ($name in $names) { $helpers[$name]=(Get-FileHash -LiteralPath (Join-Path $installer $name) -Algorithm SHA256).Hash.ToLowerInvariant() }
    $id=[Guid]::NewGuid().ToString('N')
    $data=@{installation_id=$id; install_home=$root; controller=@{config='/fixture/local.json'}; runtime_config=@{dashboard_port=12345;pilot_item_ids=@()}}
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
    Write-Host 'PASS public pilot selection, stop guard, preparation failure, preserved backup and idempotent commit'
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -cne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($resolved) -notmatch '^symphony-pilot-test-[0-9a-f]{32}$') { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
