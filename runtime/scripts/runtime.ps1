param(
    [Parameter(Mandatory)][string]$Distro,
    [Parameter(Mandatory)][string]$LinuxUser,
    [Parameter(Mandatory)][string]$LinuxRuntime,
    [Parameter(Mandatory)][string]$LinuxConfig,
    [ValidateSet('configure', 'render', 'preflight', 'launch', 'status', 'stop', 'login', 'cleanup', 'models', 'select-model')][string]$Action = 'preflight',
    [string]$Model,
    [string]$Effort,
    [switch]$Execute,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
if (-not $LinuxRuntime.StartsWith('/') -or -not $LinuxConfig.StartsWith('/')) {
    throw 'LinuxRuntime and LinuxConfig must be absolute Linux paths.'
}
$runtimeArgs = @($Action, '--config', $LinuxConfig)
if ($Execute) { $runtimeArgs += '--execute' }
if ($Apply) { $runtimeArgs += '--apply' }
if ($Model) { $runtimeArgs += @('--model', $Model) }
if ($Effort) { $runtimeArgs += @('--effort', $Effort) }
& wsl.exe --distribution $Distro --user $LinuxUser --cd / --exec python3 -I -B "$LinuxRuntime/scripts/runtime.py" @runtimeArgs
exit $LASTEXITCODE
