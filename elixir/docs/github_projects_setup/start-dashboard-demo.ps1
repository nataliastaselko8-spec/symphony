param(
    [Parameter(Mandatory)][string]$Distro,
    [Parameter(Mandatory)][string]$LinuxUser,
    [Parameter(Mandatory)][string]$LinuxRuntime,
    [Parameter(Mandatory)][string]$LinuxConfig
)
# PR11 supplies finite inspection; live dashboard startup is PR13.
$launcher = Join-Path $PSScriptRoot '../../../runtime/scripts/runtime.ps1'
& $launcher -Distro $Distro -LinuxUser $LinuxUser -LinuxRuntime $LinuxRuntime -LinuxConfig $LinuxConfig -Action launch
exit $LASTEXITCODE
