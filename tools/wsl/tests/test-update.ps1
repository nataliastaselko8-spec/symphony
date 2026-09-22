# Real Windows publication/recovery journals; WSL operations are explicit fixtures.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../setup.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot '../update.ps1') -LibraryOnly
$root = Join-Path ([IO.Path]::GetTempPath()) ('symphony-update-' + [Guid]::NewGuid().ToString('N'))
$null = New-PrivateDirectory $root
$global:updateCalls = New-Object 'Collections.Generic.List[string]'
$global:updateChecked = $false
$global:updateUsed = $false
$global:updateCrash = ''
$savedWriter = ${function:Write-Json}
function Assert($Ok, [string]$Message) { if (-not $Ok) { throw $Message } }
function Rejects([scriptblock]$Action, [string]$Expected) {
    try { & $Action | Out-Null } catch { Assert ($_.Exception.Message -match $Expected) $_.Exception.Message; return }
    throw ('Expected rejection: ' + $Expected)
}
function Write-Json($Path,$Value) {
    & $savedWriter $Path $Value
    if ($global:updateCrash -eq 'switch' -and [IO.Path]::GetFileName($Path) -eq 'installation.json' -and $Value.pins.symphony_commit -eq ('a'*40)) {
        $global:updateCrash=''; throw 'fixture_crash_after_switch'
    }
    if ($global:updateCrash -eq 'rollback' -and [IO.Path]::GetFileName($Path) -eq 'installation.json' -and $Value.pins.symphony_commit -eq ('d'*40)) {
        $global:updateCrash=''; throw 'fixture_crash_during_rollback'
    }
}
function Invoke-Provision($State,$Role,$Action,$Extra,$InputFile) {
    $global:updateCalls.Add($Role + '-' + $Action)
    if ($Action -eq 'controller') { return [pscustomobject]@{public_key='fixture'; source_home=('/home/symphony/releases/'+$State.release); mise='/home/symphony/bin/mise'} }
    if ($Action -eq 'smoke') { return [pscustomobject]@{isolation_smoke='PASS'} }
    return [pscustomobject]@{ok=$true}
}
function Invoke-UpdateHelper($Before,$After,$Release,$Action) {
    $global:updateCalls.Add('update-' + $Action)
    if ($Action -eq 'checkpoint-status') { return [pscustomobject]@{checked=$global:updateChecked} }
    if ($Action -eq 'checkpoint') { $global:updateChecked=$true }
    if ($Action -eq 'rollback-check' -and $global:updateUsed) { throw 'rollback_after_start_forbidden' }
    return [pscustomobject]@{prepared=$true; rollback_allowed=$true; execution_started=$false}
}
function New-WorkerKeeper {
    $stdin = [pscustomobject]@{}; $stdin | Add-Member ScriptMethod Close {}
    $keeper = [pscustomobject]@{StandardInput=$stdin}; $keeper | Add-Member ScriptMethod Dispose {}
    return $keeper
}
function global:wsl.exe {
    $nativeArgs=@($args); $lines=@($input); $global:LASTEXITCODE=0
    if ($nativeArgs[-1] -eq '-') {
        $match=[regex]::Match(($lines -join "`n"), "request=json.loads\(base64.b64decode\('([A-Za-z0-9+/=]+)'\)\)")
        Assert $match.Success 'Unknown bootstrap'
        $r=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups[1].Value)) | ConvertFrom-Json
        $action=$r.action
        $global:updateCalls.Add('operator-' + $action)
        switch ($action) {
            'host-start' { '{"ready":true}' }
            'sync' { '{"ssh_ready":true}' }
            'install-helper' { '{"script":"/fixture/operator.py","installation":"/fixture/install.json"}' }
            'host-stop' { '{"ownership":"managed","host_stopped":true}' }
            default { throw ('Unexpected helper ' + $action) }
        }
    } else {
        $index=[Array]::IndexOf($nativeArgs,'--installation'); $action=$nativeArgs[$index+2]
        $global:updateCalls.Add('operator-' + $action)
        Assert ($action -in @('stop','models','inspect')) ('Unexpected operator action: '+$action)
        '{"stopped":true,"execution_started":false}'
    }
}
try {
    $asset=Join-Path $root 'asset.bin'; [IO.File]::WriteAllText($asset,'fixture')
    $assets=@{}
    foreach ($name in @('rootfs','mise','worker_image','symphony','profile','runtime')) { $assets[$name]=@{file='asset.bin'; size=7; sha256=(Get-FileHash $asset).Hash.ToLowerInvariant()} }
    $helpers=@{}
    $installer=New-PrivateDirectory (Join-Path $root 'installer')
    foreach ($name in @('symphony.ps1','setup.ps1','support.ps1','manager.ps1','operator.ps1','operator.py','provision.py','update.ps1','update.py')) {
        $target=Join-Path $installer $name
        [IO.File]::WriteAllText($target,[IO.File]::ReadAllText((Join-Path $PSScriptRoot ('../'+$name))).Replace("`r`n","`n"),(New-Object Text.UTF8Encoding($false)))
        $helpers[$name]=(Get-FileHash $target).Hash.ToLowerInvariant()
    }
    $bundle=Join-Path $root 'bundle.json'
    Write-Json $bundle @{schema_version=1; architecture='x86_64'; runtime_contract=2; symphony_commit=('a'*40); profile_revision=('b'*40); worker_image=('sha256:'+'c'*64); toolchain=@{erlang='28.5'; elixir='1.19.5-otp-28'}; assets=$assets; installer=$helpers}
    $manifest=Read-Json $bundle
    $hash=(Get-FileHash $bundle).Hash.ToLowerInvariant()
    $id=[Guid]::NewGuid().ToString('N')
    $state=[pscustomobject]@{id=$id; schema_version=1; home=$root; stage='complete'; status='installed'; helpers=($helpers | ConvertTo-Json | ConvertFrom-Json); distros=@{controller='Fixture-Controller';worker='Fixture-Worker'}; github_app=@{app_id='123';client_id='fixture';installation_id='456'}; dashboard_port=4030;management_port=2240;bundle=$bundle;bundle_sha256=$hash}
    $oldManifest=$manifest | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $oldManifest.symphony_commit='d'*40
    $installation=Save-Installation $state $oldManifest
    $original=Read-Json $installation
    Write-Json (Join-Path $root 'setup.json') $state
    $global:updateCrash='switch'
    Rejects { Invoke-ReleaseUpdate -Installation $installation -Bundle $bundle -BundleSha256 $hash } 'fixture_crash_after_switch'
    Assert ((Read-Json (Join-Path $root 'setup.json')).stage -eq 'update-pending') 'Crash reopened Start'
    Assert (Test-Path (Join-Path $root 'update.pending.json')) 'Update journal missing'
    $count=@($global:updateCalls | Where-Object { $_ -eq 'operator-models' }).Count
    Invoke-ReleaseUpdate -Installation $installation -Bundle $bundle -BundleSha256 $hash
    Assert (@($global:updateCalls | Where-Object { $_ -eq 'operator-models' }).Count -eq $count) 'Resume reran completed model maintenance'
    Assert (-not (Test-Path (Join-Path $root 'update.pending.json'))) 'Pending journal remains'
    Assert ((Read-Json $installation).runtime_config.windows_installation_id -eq $id) 'Windows identity lost'
    Assert (-not $global:updateCalls.Contains('operator-start')) 'Update started a task'
    $global:updateUsed=$true
    Rejects { Invoke-ReleaseUpdate -Installation $installation -Rollback } 'rollback_after_start_forbidden'
    Assert ((Read-Json $installation).pins.symphony_commit -eq ('a'*40)) 'Rejected rollback changed descriptor'
    $global:updateUsed=$false
    $global:updateCrash='rollback'
    Rejects { Invoke-ReleaseUpdate -Installation $installation -Rollback } 'fixture_crash_during_rollback'
    Invoke-ReleaseUpdate -Installation $installation -Rollback
    Assert (Same-Json (Read-Json $installation) $original) 'Rollback failed to restore the exact descriptor'
    Assert ((Read-Json (Join-Path $root 'setup.json')).stage -eq 'complete') 'Rollback left a pending stage'
    Write-Host 'PASS verified update, interruption after switch, resume without repeated maintenance, guarded rollback and rollback interruption'
} finally {
    Remove-Item Function:\wsl.exe -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -cne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($resolved) -notmatch '^symphony-update-[0-9a-f]{32}$') { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
