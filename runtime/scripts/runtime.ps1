param(
    [Parameter(Mandatory)][string]$Distro,
    [Parameter(Mandatory)][string]$LinuxUser,
    [Parameter(Mandatory)][string]$LinuxRuntime,
    [Parameter(Mandatory)][string]$LinuxConfig,
    [ValidateSet('configure', 'render', 'preflight', 'launch', 'status', 'stop')][string]$Action = 'preflight'
)
$ErrorActionPreference = 'Stop'
if (-not $LinuxRuntime.StartsWith('/') -or -not $LinuxConfig.StartsWith('/')) {
    throw 'LinuxRuntime and LinuxConfig must be absolute Linux paths.'
}
& wsl.exe --distribution $Distro --user $LinuxUser --cd / --exec python3 -I -B "$LinuxRuntime/scripts/runtime.py" $Action --config $LinuxConfig
exit $LASTEXITCODE
