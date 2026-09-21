# Test the actual PowerShell 5.1 entry point without invoking WSL or a service.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$wrapper = Join-Path $PSScriptRoot '../operator.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('symphony-operator-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$descriptor = Join-Path $fixtureRoot 'installation with spaces.json'
$data = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot '../installation.example.json') | ConvertFrom-Json
$data.worker.config = '/etc/symphony/test-' + [Guid]::NewGuid().ToString('N') + '.json'
$data.controller.distro = 'Controller with spaces'
$data.runtime_config.controller_distro = $data.controller.distro
$data.controller.config = '/home/user/path ' + [char]0x0442 + [char]0x0435 + [char]0x0441 + [char]0x0442 + '/local.json'
[IO.File]::WriteAllText($descriptor, ($data | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
$global:operatorCalls = New-Object 'Collections.Generic.List[object]'
$global:operatorFailure = ''
$passed = 0

function Assert-That($condition, [string]$message) { if (-not $condition) { throw $message } }
function Assert-Actions([string[]]$expected) {
    $actual = @($global:operatorCalls | ForEach-Object { $_.action })
    Assert-That (($actual -join ',') -ceq ($expected -join ',')) ('Unexpected actions: ' + ($actual -join ','))
}
function global:wsl.exe {
    $nativeArgs = @($args)
    $payloadLines = @($input)
    $global:LASTEXITCODE = 0
    if ($nativeArgs[-1] -eq '-') {
        $bootstrap = $payloadLines -join "`n"
        $match = [regex]::Match($bootstrap, "request=json.loads\(base64.b64decode\('([A-Za-z0-9+/=]+)'\)\)")
        if (-not $match.Success) { throw 'Invalid stdin bootstrap' }
        $request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups[1].Value)) | ConvertFrom-Json
        $global:operatorCalls.Add($request)
        if ($request.action -eq $global:operatorFailure) { $global:LASTEXITCODE = 9; return }
        switch ($request.action) {
            'host-start' { '{"ready":true,"public_key":"fixture"}' }
            'setup' { '{"configured":true,"execution_started":false}' }
            'sync' { '{"ssh_ready":true}' }
            'install-helper' { '{"script":"/home/user/config with spaces/operator.py","installation":"/home/user/config with spaces/install.json"}' }
            'host-stop' { '{"host_stopped":true,"ownership":"managed"}' }
            'select-pilot' {
                Assert-That ($request.issue -eq 132) 'Issue number did not reach the selector'
                '{"selected":{"issue":132},"execution_started":false}'
            }
            default { throw ('Unexpected helper: ' + $request.action) }
        }
    } else {
        $index = [Array]::IndexOf($nativeArgs, '--installation')
        Assert-That ($index -gt 0) 'Missing installation argument'
        Assert-That ($nativeArgs[$index - 1] -ceq '/home/user/config with spaces/operator.py') 'Script path split'
        Assert-That ($nativeArgs[$index + 1] -ceq '/home/user/config with spaces/install.json') 'Descriptor path split'
        Assert-That ($payloadLines.Count -eq 0) 'Interactive command was piped'
        $action = $nativeArgs[$index + 2]
        $global:operatorCalls.Add([pscustomobject]@{ action = $action; arguments = $nativeArgs })
        if ($action -eq $global:operatorFailure) { $global:LASTEXITCODE = 9 }
    }
}

try {
    foreach ($action in @('Setup', 'Start', 'Login', 'Models', 'Status', 'Check', 'Stop', 'Token', 'Select-Model', 'Select-Pilot')) {
        $global:operatorCalls.Clear()
        $extra = @{}
        if ($action -eq 'Select-Model') { $extra = @{ Model = 'test-model'; Effort = 'high' } }
        if ($action -eq 'Select-Pilot') { $extra = @{ Issue = 132 } }
        & $wrapper $action -Installation $descriptor @extra | Out-Null
        switch ($action) {
            'Setup' { Assert-Actions @('host-start', 'setup') }
            { $_ -in @('Start', 'Login', 'Models') } { Assert-Actions @('host-start', 'sync', 'install-helper', $action.ToLowerInvariant()) }
            'Stop' { Assert-Actions @('install-helper', 'stop', 'host-stop') }
            'Select-Pilot' { Assert-Actions @('select-pilot') }
            default { Assert-Actions @('install-helper', $action.ToLowerInvariant()) }
        }
        $first = $global:operatorCalls[0]
        Assert-That ($first.installation.controller.config -ceq $data.controller.config) 'Unicode descriptor changed'
        Assert-That ($first.source.Length -gt 0) 'Missing helper source'
        $passed++
    }
    foreach ($fail in @('host-start', 'sync', 'install-helper', 'stop')) {
        $global:operatorCalls.Clear()
        $global:operatorFailure = $fail
        $action = if ($fail -eq 'stop') { 'Stop' } else { 'Start' }
        $rejected = $false
        try { & $wrapper $action -Installation $descriptor | Out-Null }
        catch { $rejected = $true }
        Assert-That $rejected ('Failure was ignored: ' + $fail)
        Assert-That (@($global:operatorCalls | Where-Object { $_.action -eq 'host-stop' }).Count -eq 0) 'Failed command stopped host'
        $passed++
    }
    $global:operatorFailure = ''
    foreach ($invalid in @(@{ Action='Select-Model'; Model='test-model' }, @{ Action='Stop'; Execute=$true }, @{ Action='Start'; Effort='high' },
                          @{ Action='Select-Pilot' }, @{ Action='Select-Pilot'; Issue=-1 }, @{ Action='Start'; Issue=132 })) {
        $global:operatorCalls.Clear()
        $rejected = $false
        try { & $wrapper -Installation $descriptor @invalid | Out-Null }
        catch { $rejected = $true }
        Assert-That $rejected 'Invalid flags were accepted'
        Assert-That ($global:operatorCalls.Count -eq 0) 'Invalid flags invoked WSL'
        $passed++
    }
    $global:operatorCalls.Clear()
    & $wrapper Start -Execute -Installation $descriptor | Out-Null
    Assert-That ($global:operatorCalls[-1].arguments -contains '--execute') 'Explicit Execute was lost'
    $passed++

    # Hold the actual Windows mutex from a different runspace (same-thread mutex
    # acquisition is reentrant and would not test two simultaneous terminals).
    $scope = $data.worker.distro.ToLowerInvariant() + "`n" + $data.worker.config
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($scope)))).Replace('-', '') }
    finally { $hasher.Dispose() }
    $ready = New-Object Threading.ManualResetEvent($false)
    $release = New-Object Threading.ManualResetEvent($false)
    $holder = [PowerShell]::Create()
    $null = $holder.AddScript({
        param($name, $ready, $release)
        $mutex = New-Object Threading.Mutex($false, $name)
        $null = $mutex.WaitOne()
        try { $null = $ready.Set(); $null = $release.WaitOne() }
        finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
    }).AddArgument('Global\SymphonyOperator-' + $hash).AddArgument($ready).AddArgument($release)
    $pending = $holder.BeginInvoke()
    try {
        Assert-That ($ready.WaitOne(5000)) 'Concurrent fixture did not acquire lock'
        foreach ($action in @('Setup', 'Stop')) {
            $global:operatorCalls.Clear()
            $rejected = $false
            try { & $wrapper $action -Installation $descriptor | Out-Null }
            catch { $rejected = $_.Exception.Message -like 'Another Symphony command*' }
            Assert-That $rejected ('Concurrent command was not rejected: ' + $action)
            Assert-That (@($global:operatorCalls | Where-Object { $_.action -in @('host-start','host-stop') }).Count -eq 0) 'Concurrent command changed host'
            $passed++
        }
    }
    finally {
        $null = $release.Set()
        $holder.EndInvoke($pending) | Out-Null
        $holder.Dispose(); $ready.Dispose(); $release.Dispose()
    }
    Write-Output "PASS $passed PowerShell command scenarios (WSL mocked)"
}
finally {
    Remove-Item Function:\wsl.exe
    # Only the exact generated fixture file and empty directory, no recursive deletion.
    [IO.File]::Delete($descriptor)
    [IO.Directory]::Delete($fixtureRoot)
    Remove-Variable operatorCalls, operatorFailure -Scope Global
}
