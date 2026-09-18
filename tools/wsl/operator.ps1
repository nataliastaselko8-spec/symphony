[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('Setup', 'Start', 'Stop', 'Status', 'Check', 'Login', 'Models', 'Select-Model', 'Token', 'Open', 'Inspect', 'Catalog', 'Prime')]
    [string]$Action = 'Status',
    [string]$Installation = (Join-Path $PSScriptRoot '../../.runtime-local/installation.json'),
    [string]$Model,
    [string]$Effort,
    [switch]$Execute
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$installationData = Get-Content -Raw -Encoding UTF8 -LiteralPath $Installation | ConvertFrom-Json
if ($Execute -and $Action -ne 'Start') { throw '-Execute is only supported by Start.' }
if ($Action -eq 'Select-Model' -and (-not $Model -or -not $Effort)) { throw 'Select-Model requires both -Model and -Effort.' }
if (($Model -or $Effort) -and $Action -ne 'Select-Model') { throw 'Model and Effort are only supported by Select-Model.' }
$helperSource = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'operator.py')))

function Invoke-OperatorHelper([string]$HelperAction, [bool]$Root, $HostInfo = $null) {
    $request = @{ action = $HelperAction; installation = $installationData; source = $helperSource }
    if ($null -ne $HostInfo) { $request.host_info = $HostInfo }
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Depth 30 -Compress)))
    # ASCII stdin avoids PowerShell 5.1 native argument quoting and binary-pipeline conversion.
    $bootstrap = "import base64,json`nrequest=json.loads(base64.b64decode('$payload'))`nexec(compile(base64.b64decode(request['source']),'<symphony-operator>','exec'))`nentry(request)`n"
    if ($Root) { $distro = $installationData.worker.distro; $linuxUser = 'root' }
    else { $distro = $installationData.controller.distro; $linuxUser = $installationData.controller.user }
    $output = $bootstrap | & wsl.exe --distribution $distro --user $linuxUser --cd / --exec python3 -I -B -
    if ($LASTEXITCODE -ne 0) { throw "Symphony command failed: $HelperAction. See the diagnostic above." }
    return ($output -join "`n" | ConvertFrom-Json)
}

function Enter-LifecycleLock([int]$WaitMs = 0) {
    # Same host installation, even when two descriptor files or terminals are used.
    $scope = $installationData.worker.distro.ToLowerInvariant() + "`n" + $installationData.worker.config
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($scope)))).Replace('-', '') }
    finally { $hasher.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Global\SymphonyOperator-' + $hash))
    try {
        try { $acquired = $mutex.WaitOne($WaitMs) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another Symphony command is using this worker. Its services were not stopped.' }
        return $mutex
    }
    catch { $mutex.Dispose(); throw }
}

$lifecycle = $null
try {
# Start keeps this cooperative lock until its controller exits. Stop first asks
# that controller to exit, then takes the lock before touching the host service.
if ($Action -in @('Setup', 'Start', 'Login', 'Models', 'Select-Model', 'Prime')) {
    $lifecycle = Enter-LifecycleLock
}
if ($Action -eq 'Open') {
    Start-Process -FilePath ('http://localhost:' + $installationData.runtime_config.dashboard_port)
    return
}
if ($Action -eq 'Setup') {
    $hostInfo = Invoke-OperatorHelper 'host-start' $true
    Invoke-OperatorHelper 'setup' $false $hostInfo | ConvertTo-Json -Depth 10
    return
}
if ($Action -in @('Start', 'Login', 'Models', 'Prime')) {
    $hostInfo = Invoke-OperatorHelper 'host-start' $true
    Invoke-OperatorHelper 'sync' $false $hostInfo | Out-Null
}

$installed = Invoke-OperatorHelper 'install-helper' $false
if ($Action -eq 'Prime') { $installed | ConvertTo-Json; return }
$arguments = @('--installation', $installed.installation, $Action.ToLowerInvariant())
if ($Execute) { $arguments += '--execute' }
if ($Model) { $arguments += @('--model', $Model) }
if ($Effort) { $arguments += @('--effort', $Effort) }
if ($Action -eq 'Start') {
    Write-Host ('Dashboard: http://localhost:' + $installationData.runtime_config.dashboard_port)
    Write-Host 'Controller runs in this terminal. Use Stop from another terminal, or Ctrl+C.'
}
# Keep a real console for device login and local token display. Never capture their stdout.
& wsl.exe --distribution $installationData.controller.distro --user $installationData.controller.user --cd / --exec python3 -I -B $installed.script @arguments
$controllerExit = $LASTEXITCODE
if ($controllerExit -ne 0) { throw "Symphony $Action failed. Worker protection remains running; inspect the diagnostic." }
if ($Action -eq 'Stop') {
    $lifecycle = Enter-LifecycleLock 5000
    $outcome = Invoke-OperatorHelper 'host-stop' $true
    $outcome | ConvertTo-Json
    if ($outcome.ownership -eq 'external') {
        Write-Host 'The worker supervisor was started manually. After confirmed controller stop, press Ctrl+C in its original terminal.'
    }
    if ($outcome.host_stopped -ne $true) { throw 'Host stop was not confirmed; no external supervisor was stopped.' }
}
}
finally {
    if ($null -ne $lifecycle) { $lifecycle.ReleaseMutex(); $lifecycle.Dispose() }
}
