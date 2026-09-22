$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support.ps1')
function Assert($Ok, $Message) { if (-not $Ok) { throw $Message } }
$root = Join-Path ([IO.Path]::GetTempPath()) ('symphony-disk-' + [Guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($root) | Out-Null
    # A real native volume query, without allocating or filling the disk.
    $native = Get-WindowsVolume $root
    Assert ($native.volume -match '^volume:[0-9a-f-]{36}$' -and $native.free_bytes -ge 0) 'Native Windows measurement failed'
    $data = [pscustomobject]@{installation_id=('a'*32); controller=@{distro='controller'}; worker=@{distro='worker'}}
    foreach ($role in @('controller','worker')) {
        $directory = Join-Path $root $role
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $directory 'custom-disk.vhdx'), [byte[]]@())
    }
    function Get-RegisteredDistro($Name) { return [pscustomobject]@{Version=2; BasePath=(Join-Path $root $Name); VhdFileName='custom-disk.vhdx'} }
    $script:shared = $true
    function Get-WindowsVolume($Path) {
        $id = if ($script:shared -or $Path -like '*controller*') { 'volume:12345678-1234-1234-1234-123456789abc' } else { 'volume:abcdefab-1234-1234-1234-123456789abc' }
        return @{volume=$id; free_bytes=[Int64]8589934592}
    }
    $frame = Get-WindowsStorageFrame $data ('b'*32)
    Assert ($frame.disks.controller.volume -ceq $frame.disks.worker.volume) 'Shared volume identity was lost'
    Assert ($frame.installation_id -ceq $data.installation_id -and $frame.manager_token -ceq ('b'*32)) 'Frame binding mismatch'
    Assert ($frame.disks.worker.free_bytes -eq 8589934592 -and $null -eq $frame.disks.worker.error) 'Capacity was not measured'
    Assert ($frame.measured_at_ms -le [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) 'Bad measurement time'
    $script:shared = $false
    $frame = Get-WindowsStorageFrame $data ('b'*32)
    Assert ($frame.disks.controller.volume -cne $frame.disks.worker.volume) 'Distinct volumes collapsed'
    function Get-WindowsVolume($Path) { throw 'fixture_measurement_failure' }
    $frame = Get-WindowsStorageFrame $data ('b'*32)
    Assert ($frame.disks.worker.error -ceq 'measurement_unavailable' -and $null -eq $frame.disks.worker.free_bytes) 'Unavailable must not become zero or success'
    function Get-RegisteredDistro($Name) { return $null }
    $frame = Get-WindowsStorageFrame $data ('b'*32)
    Assert ($frame.disks.controller.error -ceq 'measurement_unavailable') 'Missing registration was accepted'
    Write-Host 'PASS native Windows volume query, custom VHD path, shared/distinct volumes, unavailable and frame binding'
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -cne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notmatch '^symphony-disk-[0-9a-f]{32}$') { throw 'Unsafe fixture cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
