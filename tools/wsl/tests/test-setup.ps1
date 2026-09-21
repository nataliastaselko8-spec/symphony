# Execute the real wizard/checkpoints with fake WSL endpoints, never a real distro.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../setup.ps1') -LibraryOnly
$root = Join-Path ([IO.Path]::GetTempPath()) ('symphony-setup-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$originalLocal = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $root
$global:setupCalls = New-Object 'Collections.Generic.List[string]'
$global:setupFail = 'worker-packages'
$global:setupInput = New-Object 'Collections.Generic.Queue[string]'
$global:importedCredential = $false
function Assert($Ok, [string]$Message) { if (-not $Ok) { throw $Message } }
function Ask { param($Prompt,$Default); return $global:setupInput.Dequeue() }
function Invoke-Native { param($File,$Arguments,$InputFile,$TimeoutSeconds); $global:setupCalls.Add('windows-status'); return 'WSL2' }
function Ensure-Distro { param($State,$Role,$Rootfs); $global:setupCalls.Add($Role + '-distribution') }
function Invoke-Provision {
    param($State,$Role,$Action,$Extra,$InputFile)
    $name = $Role + '-' + $Action
    $global:setupCalls.Add($name)
    if ($name -eq $global:setupFail) { throw 'fixture_network_failure' }
    switch ($Action) {
        'controller' { return [pscustomobject]@{public_key='ssh-ed25519 fixture'} }
        'credential-status' { return [pscustomobject]@{present=$global:importedCredential} }
        'credential' { $global:importedCredential=$true; return [pscustomobject]@{credential_imported=$true} }
        'smoke' { return [pscustomobject]@{isolation_smoke='PASS'; execution_started=$false} }
        default { return [pscustomobject]@{ok=$true} }
    }
}
function New-WorkerKeeper {
    $stdin = [pscustomobject]@{}
    $stdin | Add-Member ScriptMethod Close {}
    $keeper = [pscustomobject]@{StandardInput=$stdin}
    $keeper | Add-Member ScriptMethod Dispose {}
    return $keeper
}
function New-NativeProcess { return New-WorkerKeeper }
function global:wsl.exe {
    $nativeArgs=@($args); $lines=@($input); $global:LASTEXITCODE=0
    if ($nativeArgs[-1] -eq '-') {
        $match=[regex]::Match(($lines -join "`n"), "request=json.loads\(base64.b64decode\('([A-Za-z0-9+/=]+)'\)\)")
        Assert $match.Success 'Unknown WSL bootstrap'
        $r=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups[1].Value)) | ConvertFrom-Json
        $global:setupCalls.Add('operator-' + $r.action)
        switch ($r.action) {
            'host-start' { '{"ready":true}' }
            'setup' { '{"configured":true}' }
            'install-helper' { '{"script":"/fixture/operator.py","installation":"/fixture/install.json"}' }
            'host-stop' { '{"ownership":"managed","host_stopped":true}' }
            default { throw ('Unexpected helper ' + $r.action) }
        }
    } else {
        $idx=[Array]::IndexOf($nativeArgs,'--installation'); $action=$nativeArgs[$idx+2]
        $global:setupCalls.Add('operator-' + $action)
        if (('operator-' + $action) -eq $global:setupFail) { $global:LASTEXITCODE=9; return }
        switch ($action) {
            'inspect' { '{"project":"fixture","read_only":true}' }
            'check' { '{"inspection_ready":true,"controller_ready":true,"worker":{"ready":false}}' }
            'stop' { '{"stopped":true,"workspace_preserved":true}' }
            default { throw ('Unexpected operator ' + $action) }
        }
    }
}
try {
    $asset=Join-Path $root 'asset.bin'; [IO.File]::WriteAllText($asset,'fixture')
    $assets=@{}
    foreach ($name in @('rootfs','mise','worker_image','symphony','profile','runtime')) {
        $assets[$name]=@{file='asset.bin'; size=7; sha256=(Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    $helpers=@{}
    foreach ($name in @('symphony.ps1','setup.ps1','support.ps1','manager.ps1','operator.ps1','operator.py','provision.py')) {
        $raw=[Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $PSScriptRoot ('../'+$name))).Replace("`r`n","`n"))
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $helpers[$name]=([BitConverter]::ToString($sha.ComputeHash($raw))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    }
    $bundle=Join-Path $root 'bundle.json'
    Write-Json $bundle @{schema_version=1; architecture='x86_64'; runtime_contract=2; symphony_commit=('a'*40); profile_revision=('b'*40); worker_image=('sha256:'+'c'*64); toolchain=@{erlang='28.4'; elixir='1.19.5-otp-28'}; assets=$assets; installer=$helpers}
    $hash=(Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
    $pem=Join-Path $root 'fixture.pem'; [IO.File]::WriteAllText($pem,'not a real credential')
    foreach ($value in @('123','Ivfixture','456',$pem,'YES')) { $global:setupInput.Enqueue($value) }
    $base=Join-Path $root 'installations'
    try { Invoke-FullSetup -Bundle $bundle -BundleSha256 $hash -InstallRoot $base -SkipLogin; throw 'Expected package failure' }
    catch { Assert ($_.Exception.Message -match 'fixture_network_failure') 'Wrong failed stage' }
    $pointer=Read-Json (Join-Path $root 'Symphony/current.json')
    $state=Read-Json (Join-Path $pointer.home 'setup.json')
    Assert ($state.stage -eq 'worker-packages' -and $state.status -eq 'failed') 'Failure checkpoint missing'
    $identity=$state.id
    $global:setupFail='operator-check'
    try { Invoke-FullSetup -SkipLogin; throw 'Expected final check failure' }
    catch { Assert ($_.Exception.Message -match 'Check failed') 'Wrong late failed stage' }
    $before=[IO.File]::ReadAllText($pointer.installation)
    # Resume uses the imported credential, even when its original USB/file has
    # been removed. The exact fixture file is the only deletion here.
    [IO.File]::Delete($pem)
    $global:setupFail=''
    Invoke-FullSetup -SkipLogin
    Assert ([IO.File]::ReadAllText($pointer.installation) -ceq $before) 'Resume replaced the existing descriptor'
    $state=Read-Json (Join-Path $pointer.home 'setup.json')
    Assert ($state.id -eq $identity -and $state.stage -eq 'complete') 'Resume changed installation identity or did not complete'
    $installation=Read-Json $pointer.installation
    Assert ($installation.runtime_config.pilot_item_ids.Count -eq 0) 'Installer enabled a project task'
    Assert ($installation.github_app.installation_id -eq '456') 'App configuration lost'
    Assert (Test-Path -LiteralPath (Join-Path $pointer.home 'readiness-report.json')) 'Final report missing'
    Assert ($global:setupCalls.Contains('operator-inspect')) 'GitHub read check skipped'
    Assert (-not $global:setupCalls.Contains('operator-start')) 'Setup started task controller without request'
    $count=$global:setupCalls.Count
    Invoke-FullSetup -SkipLogin
    Assert ($global:setupCalls.Count -eq $count) 'Completed Setup reconfigured distributions'
    Assert ($global:setupInput.Count -eq 0) 'Wizard silently defaulted a required value'
    # A changed helper is refused before touching any existing installation.
    [IO.File]::AppendAllText((Join-Path $pointer.home 'installer/manager.ps1'), '# changed')
    try { Invoke-FullSetup -SkipLogin; throw 'Expected checksum failure' }
    catch { Assert ($_.Exception.Message -match 'checksum mismatch') 'Modified installed helper accepted' }
    Assert ($global:setupCalls.Count -eq $count) 'Checksum rejection occurred after a mutation'
    Write-Host 'PASS wizard interruption/resume, scope preservation, inspection-only setup and completed-installation guards'
} finally {
    $env:LOCALAPPDATA=$originalLocal
    Remove-Item Function:\wsl.exe -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -cne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($resolved) -notmatch '^symphony-setup-[0-9a-f]{32}$') { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
