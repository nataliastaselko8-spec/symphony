[CmdletBinding()]
param([string]$Installation, [string]$Bundle, [string]$BundleSha256, [switch]$Rollback, [switch]$LibraryOnly)
. (Join-Path $PSScriptRoot 'support.ps1')

function Invoke-UpdateHelper($Before, $After, [string]$Release, [string]$Action) {
    $request = @{before=$Before; after=$After; release=$Release; action=$Action}
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Depth 80 -Compress)))
    $operatorSource = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'operator.py')))
    $updateSource = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'update.py')))
    $bootstrap = @"
import base64,json,types
operator=types.ModuleType('symphony_operator')
exec(compile(base64.b64decode('$operatorSource'),'<operator>','exec'),operator.__dict__)
updater=types.ModuleType('symphony_update')
exec(compile(base64.b64decode('$updateSource'),'<update>','exec'),updater.__dict__)
try:
    result=updater.entry(json.loads(base64.b64decode('$payload')),operator)
    print(json.dumps(result))
except Exception as error:
    reason=str(error) if isinstance(error,(ValueError,operator.Refused)) else 'update_io_or_configuration_error'
    if not __import__('re').fullmatch('[a-zA-Z0-9_:-]{1,200}',reason): reason='update_validation_failed'
    print(json.dumps({'error':reason}),file=__import__('sys').stderr)
    raise SystemExit(1)
"@
    $output = $bootstrap | & wsl.exe -d $After.controller.distro -u $After.controller.user --cd / --exec python3 -I -B -
    if ($LASTEXITCODE -ne 0) { throw ('Update operation failed: ' + $Action + '. Original release and workspaces are retained.') }
    return ($output -join "`n" | ConvertFrom-Json)
}

function New-UpdateDescriptor($Before, $Manifest, [string]$Release, $ControllerInfo) {
    $after = $Before | ConvertTo-Json -Depth 80 | ConvertFrom-Json
    $base = '/home/' + $Before.controller.user
    $config = $base + '/.config/symphony/update-' + $Release
    $after.controller.config = $config + '/local.json'
    $after.controller.mise = $ControllerInfo.mise
    $after.worker.config = '/etc/symphony/releases/' + $Release + '.json'
    $after.pins = $Manifest | Select-Object symphony_commit,profile_revision,worker_image
    $after.runtime_config.symphony_root = $ControllerInfo.source_home + '/symphony'
    $after.runtime_config.project_template = $ControllerInfo.source_home + '/profile/WORKFLOW.template.md'
    $after.runtime_config.state_root = $base + '/.local/state/symphony/update-' + $Release
    $after.runtime_config.workflow = $config + '/WORKFLOW.md'
    $after.runtime_config.manifest = $config + '/deployment.json'
    $after.runtime_config | Add-Member -Force NoteProperty windows_installation_id $Before.installation_id
    return $after
}

function Invoke-ReleaseUpdate {
param([string]$Installation, [string]$Bundle, [string]$BundleSha256, [switch]$Rollback)
    $Installation = Get-InstallationFile $Installation
    $before = Read-Json $Installation
    if ($before.installation_id -notmatch '^[0-9a-f]{32}$' -or [IO.Path]::GetFullPath($Installation) -ine (Join-Path $before.install_home 'installation.json')) { throw 'Full installation descriptor required.' }
    $mutex = Enter-InstallationLock $before.installation_id
    $keeper = $null
    try {
        if (-not (Same-Json $before (Read-Json $Installation))) { throw 'Installation changed; retry Update.' }
        if ($null -ne (Get-Manager $before)) { throw 'Run Symphony.cmd Stop before Update.' }
        $setupFile = Join-Path $before.install_home 'setup.json'
        $state = Read-Json $setupFile
        if ($state.id -cne $before.installation_id -or $state.home -ine $before.install_home) { throw 'Installation scope mismatch.' }
        Verify-Helpers $state
        $pendingFile = Join-Path $state.home 'update.pending.json'
        $receiptFile = Join-Path $state.home 'update.json'
        $rollbackFile = Join-Path $state.home 'rollback.pending.json'
        if ($Rollback) {
            if ($Bundle -or $BundleSha256) { throw 'Rollback-Update does not accept a bundle.' }
            if (Test-Path -LiteralPath $pendingFile) { throw 'Finish the pending Update before rollback.' }
            $receipt = Read-Json $receiptFile
            if (Test-Path -LiteralPath $rollbackFile) {
                if (-not (Same-Json (Read-Json $rollbackFile) $receipt) -or -not ((Same-Json $before $receipt.after) -or (Same-Json $before $receipt.before))) { throw 'Rollback journal or active descriptor changed.' }
            } elseif (-not (Same-Json $before $receipt.after)) { throw 'Active descriptor changed; rollback refused.' }
            Invoke-UpdateHelper $receipt.before $receipt.after $receipt.release 'rollback-check' | Out-Null
            Verify-Helpers $receipt.before_state
            # The old state is never overwritten with a snapshot: only the selected release changes.
            Write-Json $rollbackFile $receipt
            $state.stage = 'update-pending'
            Write-Json $setupFile $state
            Write-Json $Installation $receipt.before
            Write-Json $setupFile $receipt.before_state
            Remove-Item -LiteralPath $rollbackFile
            Write-Host 'Previous release selected. No state was restored over newer work. Run Doctor before Start.'
            return
        }
        if (Test-Path -LiteralPath $rollbackFile) { throw 'Resume Rollback-Update first.' }
        if (-not $Bundle -or -not $BundleSha256) { throw 'Update requires -Bundle and its trusted -BundleSha256.' }
        $manifest = Read-Bundle $Bundle $BundleSha256
        if (-not $manifest.installer.PSObject.Properties['update.ps1']) { throw 'Bundle has no supported update contract.' }
        $release = $BundleSha256.ToLowerInvariant().Substring(0,24)
        if (Test-Path -LiteralPath $pendingFile) {
            $pending = Read-Json $pendingFile
            if ($pending.release -cne $release -or $pending.bundle_sha256 -ine $BundleSha256 -or
                -not ((Same-Json $before $pending.before) -or ($pending.after -and (Same-Json $before $pending.after)))) { throw 'Resume the pending Update with the same bundle.' }
            $before = $pending.before
        } else {
            if ($state.stage -ne 'complete') { throw 'Finish Setup before Update.' }
            if (Test-Path -LiteralPath (Join-Path $state.home 'pilot-selection.pending.json')) { throw 'Finish Select-Pilot before Update.' }
            if ((Same-Json $before.pins ($manifest | Select-Object symphony_commit,profile_revision,worker_image))) { throw 'This release is already selected.' }
            # Fresh Stop using the new helper also records the old configuration/worker identity.
            $keeper = New-WorkerKeeper $before
            & (Join-Path $PSScriptRoot 'operator.ps1') Prime -Installation $Installation | Out-Null
            & (Join-Path $PSScriptRoot 'operator.ps1') Stop -Installation $Installation | Out-Null
            $pending = [pscustomobject]@{schema_version=1; release=$release; bundle_sha256=$BundleSha256.ToLowerInvariant(); before=$before; before_state=$state; after=$null}
            Write-Json $pendingFile $pending
        }
        $working = $pending.before_state | ConvertTo-Json -Depth 80 | ConvertFrom-Json
        $working.stage = 'update-pending'
        $working.status = 'update-pending'
        Write-Json $setupFile $working
        $working.bundle = (Resolve-Path -LiteralPath $Bundle).Path
        $working.bundle_sha256 = $BundleSha256.ToLowerInvariant()
        $working | Add-Member -Force NoteProperty release $release
        foreach ($name in @('mise','symphony','profile')) { Send-Asset $working $manifest 'controller' $name }
        $info = Invoke-Provision $working 'controller' 'controller' @{manifest=$manifest}
        foreach ($name in @('runtime','worker_image')) { Send-Asset $working $manifest 'worker' $name }
        Invoke-Provision $working 'worker' 'worker' @{manifest=$manifest; public_key=$info.public_key; port=$working.management_port} | Out-Null
        $after = New-UpdateDescriptor $before $manifest $release $info
        if ($pending.after -and -not (Same-Json $pending.after $after)) { throw 'Prepared update descriptor changed.' }
        $pending.after = $after
        Write-Json $pendingFile $pending
        Invoke-UpdateHelper $before $after $release 'prepare' | Out-Null
        $helpers = New-PrivateDirectory (Join-Path $working.home ('installer-releases/' + $release))
        $working | Add-Member -Force NoteProperty helper_root $helpers
        $working.helpers = $manifest.installer
        foreach ($name in (Get-HelperNames $manifest.installer)) {
            $target = Join-Path $helpers $name
            if (-not (Test-Path -LiteralPath $target)) { [IO.File]::WriteAllText($target, [IO.File]::ReadAllText((Join-Path $PSScriptRoot $name)).Replace("`r`n","`n"), (New-Object Text.UTF8Encoding($false))) }
        }
        Verify-Helpers $working
        $candidateFile = Join-Path $working.home ('update-' + $release + '.json')
        Write-Json $candidateFile $after
        if ($null -eq $keeper) { $keeper = New-WorkerKeeper $after }
        $operator = Join-Path $helpers 'operator.ps1'
        $checked = Invoke-UpdateHelper $before $after $release 'checkpoint-status'
        if (-not $checked.checked) {
        $canary = Get-Item -LiteralPath (Join-Path $env:WINDIR 'System32/cmd.exe')
        Invoke-Provision $working 'worker' 'receive' @{asset='windows_canary'; size=$canary.Length; sha256=(Get-FileHash -LiteralPath $canary.FullName -Algorithm SHA256).Hash.ToLowerInvariant()} $canary.FullName | Out-Null
        # A retry may follow interrupted maintenance. Stop that owned host before isolation tests.
        & $operator Prime -Installation $candidateFile | Out-Null
        & $operator Stop -Installation $candidateFile | Out-Null
        $smoke = Invoke-Provision $working 'worker' 'smoke'
        if ($smoke.isolation_smoke -cne 'PASS') { throw 'Updated isolation smoke was not confirmed.' }
        Write-Json (Join-Path $helpers 'isolation-report.json') $smoke
        try {
            & $operator Models -Installation $candidateFile | Out-Null
            & $operator Inspect -Installation $candidateFile | Out-Null
        } finally { & $operator Stop -Installation $candidateFile | Out-Null }
        Invoke-UpdateHelper $before $after $release 'checkpoint' | Out-Null
        }
        $working.stage = 'complete'
        $working.status = 'updated-stopped'
        $receipt = [pscustomobject]@{schema_version=1; release=$release; before=$before; after=$after; before_state=$pending.before_state; after_state=$working}
        Write-Json $receiptFile $receipt
        Write-Json $Installation $after
        Write-Json $setupFile $working
        Remove-Item -LiteralPath $pendingFile
        Write-Host 'Update verified and selected. Credentials, model choice, history and workspaces retained. No task started.'
        Write-Host 'Run Doctor. A new pilot still requires Select-Pilot and Start -Execute.'
    } finally {
        if ($null -ne $keeper) { $keeper.StandardInput.Close(); $keeper.Dispose() }
        $mutex.ReleaseMutex(); $mutex.Dispose()
    }
}
if (-not $LibraryOnly) { Invoke-ReleaseUpdate -Installation $Installation -Bundle $Bundle -BundleSha256 $BundleSha256 -Rollback:$Rollback }
