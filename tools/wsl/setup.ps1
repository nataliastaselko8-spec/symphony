[CmdletBinding()]
param([string]$Bundle, [string]$BundleSha256, [string]$InstallRoot, [switch]$SkipLogin, [switch]$LibraryOnly)
. (Join-Path $PSScriptRoot 'support.ps1')

function Ask([string]$Prompt, [string]$Default = '') {
    $value = Read-Host ($Prompt + $(if ($Default) { ' [' + $Default + ']' } else { '' }))
    if (-not $value) { return $Default }
    return $value.Trim().Trim('"')
}
function Free-Port([int]$Preferred) {
    foreach ($port in $Preferred..($Preferred + 200)) {
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $port)
        try { $listener.Start(); return $port } catch {} finally { $listener.Stop() }
    }
    throw 'No free port in the requested range.'
}
function Save-Installation($State, $Manifest) {
    $controllerHome = '/home/symphony'
    $configHome = $controllerHome + '/.config/symphony/pilot'
    $runtime = [ordered]@{
        schema_version=2; role='controller'; profile='pilot'; runtime_kind='wsl2-podman'
        symphony_root=$controllerHome + '/symphony'; project_template=$controllerHome + '/profile/WORKFLOW.template.md'
        state_root=$controllerHome + '/.local/state/symphony/pilot'; workflow=$configHome + '/WORKFLOW.md'
        manifest=$configHome + '/deployment.json'; ssh_config=$controllerHome + '/.ssh/management_config'
        app_key=$controllerHome + '/.config/symphony/github-app/private-key.pem'
        operator_credential=$controllerHome + '/.config/symphony/operator/login-token'
        controller_distro=$State.distros.controller; controller_user='symphony'
        worker_distro=$State.distros.worker; worker_user='symphony-worker'
        worker_host='symphony-worker'; management_host='symphony-management'
        dashboard_port=$State.dashboard_port; pilot_item_ids=@(); retention_days=7
        disk_minimum_bytes=5368709120; disk_warning_bytes=10737418240
    }
    $value = [ordered]@{
        schema_version=1; installation_id=$State.id; install_home=$State.home
        controller=@{distro=$State.distros.controller; user='symphony'; config=$configHome + '/local.json'; mise=$controllerHome + '/.local/bin/mise'}
        worker=@{distro=$State.distros.worker; config='/etc/symphony/host.json'}
        github_app=$State.github_app
        pins=@{symphony_commit=$Manifest.symphony_commit; profile_revision=$Manifest.profile_revision; worker_image=$Manifest.worker_image}
        ssh=@{identity=$controllerHome + '/.ssh/management_ed25519'; known_hosts=$controllerHome + '/.ssh/management_known_hosts'}
        runtime_config=$runtime
    }
    $file = Join-Path $State.home 'installation.json'
    if (Test-Path -LiteralPath $file) {
        $old = Read-Json $file
        if ((Canonical-Value $old | ConvertTo-Json -Depth 30 -Compress) -cne ((Canonical-Value $value | ConvertTo-Json -Depth 30 -Compress))) { throw 'Existing installation descriptor differs; it will not be reset.' }
    } else { Write-Json $file $value }
    return $file
}

function Invoke-FullSetup {
param([string]$Bundle, [string]$BundleSha256, [string]$InstallRoot, [switch]$SkipLogin)
if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -notin @('AMD64','x86') -or [Environment]::OSVersion.Version.Build -lt 22000) {
    throw 'This installer supports Windows 11 x64. Other systems require separate acceptance.'
}
$registryHome = Join-Path $env:LOCALAPPDATA 'Symphony'
$pointer = Join-Path $registryHome 'current.json'
$state = $null
if ($InstallRoot -and (Test-Path -LiteralPath (Join-Path $InstallRoot 'setup.json'))) { $state = Read-Json (Join-Path $InstallRoot 'setup.json') }
elseif (-not $InstallRoot -and (Test-Path -LiteralPath $pointer)) { $state = Read-Json (Join-Path (Read-Json $pointer).home 'setup.json') }
if ($null -eq $state) {
    if (-not $Bundle) { $Bundle = Ask 'Path to the trusted bundle.json provided by the project owner' }
    if (-not $BundleSha256) { $BundleSha256 = Ask 'SHA256 of bundle.json from the trusted project source' }
    $manifest = Read-Bundle $Bundle $BundleSha256
    if (-not $InstallRoot) { $InstallRoot = Ask 'Folder for Symphony installations' (Join-Path $registryHome 'installations') }
    $id = [Guid]::NewGuid().ToString('N')
    $destination = Join-Path ([IO.Path]::GetFullPath($InstallRoot)) $id
    $app = @{app_id=(Ask 'GitHub App ID'); client_id=(Ask 'GitHub App Client ID'); installation_id=(Ask 'GitHub App installation ID')}
    if ($app.app_id -notmatch '^[1-9][0-9]*$' -or $app.installation_id -notmatch '^[1-9][0-9]*$' -or $app.client_id -notmatch '^[A-Za-z0-9_]+$') { throw 'Invalid GitHub App identifiers.' }
    $pem = (Resolve-Path -LiteralPath (Ask 'Path to the GitHub App PEM file (contents will not be displayed)')).Path
    $state = [pscustomobject]@{
        schema_version=1; id=$id; home=$destination; bundle=(Resolve-Path -LiteralPath $Bundle).Path
        bundle_sha256=$BundleSha256.ToLowerInvariant(); stage='plan'; status='pending'; github_app=$app; pem_source=$pem
        helpers=$manifest.installer
        distros=@{controller=('Symphony-Controller-' + $id.Substring(0,8)); worker=('Symphony-Worker-' + $id.Substring(0,8))}
        dashboard_port=(Free-Port 4080); management_port=(Free-Port 2240)
    }
    Write-Host ('Create two NEW WSL2 distributions: ' + $state.distros.controller + ', ' + $state.distros.worker)
    Write-Host ('Storage: ' + $destination)
    Write-Host ('Symphony: ' + $manifest.symphony_commit + '; profile: ' + $manifest.profile_revision)
    Write-Host 'Existing Ubuntu distributions, Docker Desktop, and old configurations will not be adopted or removed.'
    if ((Ask 'Proceed with this installation? Type YES') -cne 'YES') { return }
    $null = New-PrivateDirectory $registryHome
    $null = New-PrivateDirectory $destination
    Write-Json (Join-Path $destination 'setup.json') $state
    Write-Json $pointer @{home=$destination; installation=(Join-Path $destination 'installation.json')}
} else {
    if ($state.schema_version -ne 1 -or $state.id -notmatch '^[0-9a-f]{32}$') { throw 'Invalid installer checkpoint.' }
    if ($state.stage -eq 'complete') {
        Verify-Helpers $state
        Write-Host 'Already installed. Setup does not reconfigure an existing installation. Use Start, Doctor or Login.'
        return
    }
    if ($Bundle -and (Resolve-Path -LiteralPath $Bundle).Path -ine $state.bundle) { throw 'Resume must use the original accepted bundle.' }
    $manifest = Read-Bundle $state.bundle $state.bundle_sha256
    Write-Host ('Resuming installation ' + $state.id + ' at ' + $state.stage)
}
$mutex = Enter-InstallationLock $state.id
$acquired = $false
$keeper = $null
try {
    $acquired = $true
    Invoke-Stage $state 'windows-wsl' {
        $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($state.home))
        if ($drive.AvailableFreeSpace -lt 20GB) { throw 'At least 20 GiB of free installation disk space is required.' }
        try { Invoke-Native (Wsl-Path) @('--status') | Out-Null }
        catch {
            $state.status = 'needs-input'
            Write-Json (Join-Path $state.home 'setup.json') $state
            Write-Host 'WSL needs installation or repair. Windows may ask for administrator approval.'
            $process = Start-Process -FilePath (Wsl-Path) -ArgumentList '--install --no-distribution' -Verb RunAs -WindowStyle Hidden -PassThru
            $process.WaitForExit()
            throw 'Complete the Windows restart if requested, then run Symphony.cmd Setup again.'
        }
    }
    $rootfs = Join-Path ([IO.Path]::GetDirectoryName($state.bundle)) $manifest.assets.rootfs.file
    foreach ($role in @('controller','worker')) {
        Invoke-Stage $state ($role + '-distribution') { Ensure-Distro $state $role $rootfs }
        Invoke-Stage $state ($role + '-packages') { Invoke-Provision $state $role 'packages' | Out-Null }
    }
    $installerHome = New-PrivateDirectory (Join-Path $state.home 'installer')
    foreach ($name in $manifest.installer.PSObject.Properties.Name) {
        $target = Join-Path $installerHome $name
        if (-not (Test-Path -LiteralPath $target)) { [IO.File]::WriteAllText($target, [IO.File]::ReadAllText((Join-Path $PSScriptRoot $name)).Replace("`r`n","`n"), (New-Object Text.UTF8Encoding($false))) }
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $manifest.installer.$name) { throw 'Installed helper changed. Refusing to replace it.' }
    }
    Invoke-Stage $state 'controller-source-and-build' {
        foreach ($asset in @('mise','symphony','profile')) { Send-Asset $state $manifest 'controller' $asset }
        $script:controllerInfo = Invoke-Provision $state 'controller' 'controller' @{manifest=$manifest}
    }
    Invoke-Stage $state 'worker-image-and-host' {
        foreach ($asset in @('runtime','worker_image')) { Send-Asset $state $manifest 'worker' $asset }
        Invoke-Provision $state 'worker' 'worker' @{manifest=$manifest; public_key=$script:controllerInfo.public_key; port=$state.management_port} | Out-Null
    }
    Invoke-Stage $state 'isolation-smoke' {
        # A valid, inert Windows probe is copied as test input, never mounted.
        # The container must reject it even if another WSL distro enables interop.
        $canary = Get-Item -LiteralPath (Join-Path $env:WINDIR 'System32/cmd.exe')
        $canaryHash = (Get-FileHash -LiteralPath $canary.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        Invoke-Provision $state 'worker' 'receive' @{asset='windows_canary'; size=$canary.Length; sha256=$canaryHash} $canary.FullName | Out-Null
        # Exercise both distro systemd trees together, as in normal operation.
        $controllerKeeper = New-NativeProcess (Wsl-Path) @('-d',$state.distros.controller,'-u','symphony','--cd','/','--exec','python3','-I','-c','import sys;sys.stdin.buffer.read()') -Redirect
        try { $report = Invoke-Provision $state 'worker' 'smoke' }
        finally { $controllerKeeper.StandardInput.Close(); $controllerKeeper.Dispose() }
        if ($report.isolation_smoke -cne 'PASS') { throw 'Isolation smoke was not confirmed.' }
        Write-Json (Join-Path $state.home 'isolation-report.json') $report
    }
    Invoke-Stage $state 'github-credential' {
        if (-not (Invoke-Provision $state 'controller' 'credential-status').present) {
            $pemFile = Get-Item -LiteralPath $state.pem_source
            $hash = (Get-FileHash -LiteralPath $pemFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            Invoke-Provision $state 'controller' 'receive' @{asset='pem'; size=$pemFile.Length; sha256=$hash} $pemFile.FullName | Out-Null
            Invoke-Provision $state 'controller' 'credential' | Out-Null
        }
    }
    $installation = Save-Installation $state $manifest
    $operator = Join-Path $installerHome 'operator.ps1'
    # Retain the worker distro while the interactive wizard configures/login uses it.
    $keeper = New-WorkerKeeper (Read-Json $installation)
    Invoke-Stage $state 'local-configuration' { & $operator Setup -Installation $installation }
    Invoke-Stage $state 'github-read-access' { & $operator Inspect -Installation $installation }
    if (-not $SkipLogin -and (Ask 'Sign in to Codex and choose a model now? y/n' 'y') -ieq 'y') {
        Invoke-Stage $state 'codex-login' { & $operator Login -Installation $installation }
        $catalog = (& $operator Catalog -Installation $installation) -join "`n" | ConvertFrom-Json
        foreach ($item in $catalog.models) { Write-Host ($item.model + ': ' + ($item.efforts -join ', ')) }
        $model = Ask 'Choose a model from the list'
        $effort = Ask 'Choose its reasoning effort from the list'
        Invoke-Stage $state 'model-selection' { & $operator Select-Model -Installation $installation -Model $model -Effort $effort }
    }
    Invoke-Stage $state 'final-check' {
        $report = (& $operator Check -Installation $installation) -join "`n" | ConvertFrom-Json
        Write-Json (Join-Path $state.home 'readiness-report.json') $report
        if (-not $report.inspection_ready -or -not $report.controller_ready) { throw 'Controller readiness was not confirmed.' }
        if (-not $report.worker.ready) { Write-Host 'Dashboard is available; worker authorization/model readiness still requires attention. See Doctor.' }
    }
    Invoke-Stage $state 'confirmed-stop' { & $operator Stop -Installation $installation }
    $state.stage = 'complete'
    $state.status = 'installed-inspection'
    Write-Json (Join-Path $state.home 'setup.json') $state
    Write-Host 'Installation complete. No project task has started. Use Symphony.cmd Start to open the dashboard.'
    Write-Host ('Local descriptor: ' + $installation)
} finally {
    if ($null -ne $keeper) { $keeper.StandardInput.Close(); $keeper.Dispose() }
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
}
if (-not $LibraryOnly) { Invoke-FullSetup -Bundle $Bundle -BundleSha256 $BundleSha256 -InstallRoot $InstallRoot -SkipLogin:$SkipLogin }
