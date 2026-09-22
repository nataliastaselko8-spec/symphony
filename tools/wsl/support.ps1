Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Json([string]$Path) {
    Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
}
function Write-Json([string]$Path, $Value) {
    $raw = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 40))
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.pending'
    $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($raw, 0, $raw.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    try {
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Canonical-Value($Value) {
    if ($Value -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object)) { $result[$key] = Canonical-Value $Value[$key] }
        return $result
    }
    if ($Value -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) { $result[$property.Name] = Canonical-Value $property.Value }
        return $result
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { Canonical-Value $_ }) }
    return $Value
}
function Same-Json($Left, $Right) {
    return (Canonical-Value $Left | ConvertTo-Json -Depth 40 -Compress) -ceq (Canonical-Value $Right | ConvertTo-Json -Depth 40 -Compress)
}
function Assert-PilotTransition($Before, $After, [int]$Issue) {
    if ($After.installation_id -cne $Before.installation_id -or $After.install_home -ine $Before.install_home -or
        @($After.runtime_config.pilot_item_ids).Count -ne 1 -or $After.pilot.issue -ne $Issue -or
        $After.runtime_config.pilot_item_ids[0] -cne $After.pilot.item_id -or $After.pilot.transition_id -cnotmatch '^[0-9a-f]{24}$') {
        throw 'Invalid pilot selection result; descriptor was preserved.'
    }
    # The helper may change only the selected profile and its appended history.
    $stable = Canonical-Value $Before
    $expected = Canonical-Value $After
    foreach ($key in @('controller','runtime_config','pilot','pilot_history')) { $stable.Remove($key); $expected.Remove($key) }
    if (-not (Same-Json $stable $expected)) { throw 'Pilot selection changed installation identity or credentials.' }
    foreach ($section in @('controller','runtime_config')) {
        $left = Canonical-Value $Before.$section
        $right = Canonical-Value $After.$section
        $mutable = if ($section -eq 'controller') { @('config') } else { @('pilot_item_ids','profile','state_root','workflow','manifest') }
        foreach ($key in $mutable) { $left.Remove($key); $right.Remove($key) }
        if (-not (Same-Json $left $right)) { throw 'Pilot selection changed runtime contract or controller host.' }
    }
    $history = @()
    if ($Before.PSObject.Properties['pilot_history']) { $history = @($Before.pilot_history) }
    $updated = @($After.pilot_history)
    if ($updated.Count -ne $history.Count + 1) { throw 'Pilot history must append one transition.' }
    for ($index = 0; $index -lt $history.Count; $index++) {
        if (-not (Same-Json $history[$index] $updated[$index])) { throw 'Previous pilot history changed.' }
    }
    $entry = $updated[-1]
    if ($entry.id -cne $After.pilot.transition_id -or $entry.source_config -cne $Before.controller.config -or
        $entry.target_config -cne $After.controller.config -or $entry.target_issue -ne $Issue -or
        $After.controller.config -ceq $Before.controller.config -or $After.runtime_config.state_root -ceq $Before.runtime_config.state_root) {
        throw 'Pilot transition does not match its profiles.'
    }
}
function Publish-PilotSelection([string]$Installation, $Before, $After, [int]$Issue) {
    $pending = Join-Path $Before.install_home 'pilot-selection.pending.json'
    $record = $null
    if (Test-Path -LiteralPath $pending) {
        $record = Read-Json $pending
        Assert-PilotTransition $record.before $record.after $Issue
        if ($record.schema_version -ne 1 -or -not (Same-Json $record.after $After) -or
            -not ((Same-Json $Before $record.before) -or (Same-Json $Before $record.after))) {
            throw 'Pending pilot selection differs; active descriptor was preserved.'
        }
    } elseif (Same-Json $Before $After) { return }
    else {
        Assert-PilotTransition $Before $After $Issue
        $record = @{schema_version=1; before=$Before; after=$After}
        Write-Json $pending $record
    }
    $directory = New-PrivateDirectory (Join-Path $Before.install_home 'pilot-history')
    $file = Join-Path $directory ($After.pilot.transition_id + '.json')
    if (Test-Path -LiteralPath $file) {
        if (-not (Same-Json (Read-Json $file) $record)) { throw 'Saved pilot transition differs.' }
    } else { Write-Json $file $record }
    $legacy = Join-Path $Before.install_home 'installation.before-pilot.json'
    if (-not (Test-Path -LiteralPath $legacy)) { Write-Json $legacy $record.before }
    if (-not (Same-Json $Before $After)) { Write-Json $Installation $After }
    [IO.File]::Delete($pending)
}
function New-PrivateDirectory([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $parent = New-Object IO.DirectoryInfo($full)
    while ($null -ne $parent) {
        if ($parent.Exists -and ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse-point installation paths are not supported.' }
        $parent = $parent.Parent
    }
    [IO.Directory]::CreateDirectory($full) | Out-Null
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $current = Get-Acl -LiteralPath $full
    $existing = @($current.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    if ($current.AreAccessRulesProtected -and $current.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq $sid.Value -and
        $existing.Count -eq 2 -and @($existing | Where-Object {
            $_.IdentityReference.Value -notin @($sid.Value,'S-1-5-18') -or $_.AccessControlType -ne 'Allow' -or
            $_.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
            $_.InheritanceFlags -ne ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit)
        }).Count -eq 0) { return $full }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($sid)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @($sid, (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $full -AclObject $acl
    return $full
}
function Quote-NativeArgument([string]$Value) {
    if ($Value -match "[\r\n\x00]") { throw 'Control characters in native arguments.' }
    # wsl.exe parses leading switches from the raw command line. Quoting a
    # switch such as "-d" turns it into a Linux command on current WSL.
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    # CommandLineToArgvW: double backslashes before a quote and before the closing quote.
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function New-NativeProcess([string]$File, [string[]]$Arguments, [switch]$Redirect) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $File
    $info.Arguments = (@($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = [bool]$Redirect
    $info.RedirectStandardError = [bool]$Redirect
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    # .NET Framework inherits Console.InputEncoding for the redirected writer.
    # Its UTF-8 preamble would be emitted before even a BaseStream binary copy.
    $encoding = New-Object Text.UTF8Encoding($false)
    if ($info.PSObject.Properties['StandardInputEncoding']) {
        $info.StandardInputEncoding = $encoding
        if (-not $process.Start()) { throw 'Process did not start.' }
    } else {
        $previousEncoding = [Console]::InputEncoding
        try {
            [Console]::InputEncoding = $encoding
            if (-not $process.Start()) { throw 'Process did not start.' }
        } finally { [Console]::InputEncoding = $previousEncoding }
    }
    return $process
}
function Invoke-Native([string]$File, [string[]]$Arguments, [string]$InputFile, [int]$TimeoutSeconds = 3600) {
    $process = New-NativeProcess $File $Arguments -Redirect
    $inputStream = $null
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($InputFile) {
            $inputStream = [IO.File]::OpenRead($InputFile)
            $copy = $inputStream.CopyToAsync($process.StandardInput.BaseStream)
            if (-not $copy.Wait($TimeoutSeconds * 1000)) { throw 'Input transfer timed out; Setup retains its checkpoint.' }
            $null = $copy.GetAwaiter().GetResult()
        }
        $process.StandardInput.Close()
        $remaining = [Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $process.WaitForExit([int]$remaining)) {
            # Only our process handle. Do not stop a distro or unknown descendants.
            $process.Kill()
            throw 'Command timed out. Run Setup again to verify and resume this stage.'
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $reason = 'native_command_failed_' + [IO.Path]::GetFileName($File) + '_exit_' + $process.ExitCode
            # Only a structured, bounded bootstrap error is safe to display.
            try { $diagnostic = $errors | ConvertFrom-Json; if ($diagnostic.error -match '^[a-zA-Z0-9_:-]{1,200}$') { $reason = $diagnostic.error } } catch {}
            throw $reason
        }
        return $output.Replace([string][char]0, '').Trim()
    } finally {
        if (-not $process.HasExited) { $process.Kill() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        $process.Dispose()
    }
}
function Wsl-Path {
    $path = Join-Path $env:WINDIR 'System32/wsl.exe'
    if (-not [Environment]::Is64BitProcess) { $path = Join-Path $env:WINDIR 'Sysnative/wsl.exe' }
    return $path
}
function Invoke-Provision($State, [string]$Role, [string]$Action, [hashtable]$Extra = @{}, [string]$InputFile) {
    $request = @{id=$State.id; role=$Role; action=$Action}
    if ($State.PSObject.Properties['release']) { $request.release = $State.release }
    foreach ($key in $Extra.Keys) { $request[$key] = $Extra[$key] }
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Depth 40 -Compress)))
    $memory = New-Object IO.MemoryStream
    $zip = New-Object IO.Compression.GZipStream($memory, [IO.Compression.CompressionMode]::Compress, $true)
    try {
        $raw = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'provision.py'))
        $zip.Write($raw, 0, $raw.Length)
    } finally { $zip.Dispose() }
    $source = [Convert]::ToBase64String($memory.ToArray())
    $memory.Dispose()
    $code = 'import base64,gzip,sys;exec(compile(gzip.decompress(base64.b64decode(sys.argv[1])),"<symphony-bootstrap>","exec"))'
    $arguments = @('-d', $State.distros.$Role, '-u', 'root', '--cd', '/', '--exec', 'python3', '-I', '-B', '-c', $code, $source, $payload)
    $result = Invoke-Native (Wsl-Path) $arguments -InputFile $InputFile -TimeoutSeconds 7200
    return ($result | ConvertFrom-Json)
}
function Read-Bundle([string]$Path, [string]$ExpectedHash) {
    $full = (Resolve-Path -LiteralPath $Path).Path
    if ($ExpectedHash -notmatch '^[0-9a-fA-F]{64}$' -or (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ine $ExpectedHash) { throw 'Bundle manifest checksum mismatch.' }
    $manifest = Read-Json $full
    if ($manifest.schema_version -ne 1 -or $manifest.runtime_contract -ne 2 -or $manifest.architecture -cne 'x86_64') { throw 'Unsupported bundle contract.' }
    foreach ($name in @('symphony_commit','profile_revision')) { if ($manifest.$name -notmatch '^[0-9a-f]{40}$') { throw 'Full source pins required.' } }
    if ($manifest.worker_image -notmatch '^sha256:[0-9a-f]{64}$') { throw 'Pinned image required.' }
    foreach ($name in @('erlang','elixir')) { if ($manifest.toolchain.$name -notmatch '^[0-9]+\.[0-9][0-9A-Za-z.+-]{0,48}$') { throw 'Exact toolchain pins required.' } }
    foreach ($name in @('rootfs','mise','worker_image','symphony','profile','runtime')) {
        $asset = $manifest.assets.$name
        if ($asset.file -notmatch '^[a-zA-Z0-9_.-]+$' -or $asset.file -in @('.','..') -or $asset.sha256 -notmatch '^[0-9a-f]{64}$' -or $asset.size -le 0 -or $asset.size -gt 32GB) { throw 'Invalid asset metadata.' }
        $file = Join-Path ([IO.Path]::GetDirectoryName($full)) $asset.file
        $item = Get-Item -LiteralPath $file
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.Length -ne $asset.size -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $asset.sha256) { throw ('Asset checksum mismatch: ' + $name) }
    }
    foreach ($name in (Get-HelperNames $manifest.installer)) {
        $raw = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $PSScriptRoot $name)).Replace("`r`n", "`n"))
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $actual = ([BitConverter]::ToString($hash.ComputeHash($raw))).Replace('-','').ToLowerInvariant() } finally { $hash.Dispose() }
        if ($actual -cne $manifest.installer.$name) { throw ('Installer does not match the accepted bundle: ' + $name) }
    }
    return $manifest
}
function Send-Asset($State, $Manifest, [string]$Role, [string]$Name) {
    $asset = $Manifest.assets.$Name
    $inputFile = Join-Path ([IO.Path]::GetDirectoryName($State.bundle)) $asset.file
    Invoke-Provision $State $Role 'receive' @{asset=$Name; size=$asset.size; sha256=$asset.sha256} $inputFile | Out-Null
}
function Get-RegisteredDistro([string]$Name) {
    $entries = @(Get-ChildItem -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue)
    foreach ($entry in $entries) {
        $value = Get-ItemProperty -LiteralPath $entry.PSPath
        if ($value.DistributionName -ieq $Name) { return $value }
    }
    return $null
}
function Get-WindowsVolume([string]$Path) {
    if (-not ('SymphonyWindowsVolumes' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class SymphonyWindowsVolumes {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool GetVolumePathName(string file, StringBuilder path, uint size);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool GetVolumeNameForVolumeMountPoint(string path, StringBuilder name, uint size);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool GetDiskFreeSpaceEx(string path, out ulong available, out ulong total, out ulong free);
}
'@
    }
    $mount = New-Object Text.StringBuilder 1024
    $volume = New-Object Text.StringBuilder 1024
    [UInt64]$available = 0; [UInt64]$total = 0; [UInt64]$free = 0
    if (-not [SymphonyWindowsVolumes]::GetVolumePathName($Path, $mount, 1024) -or
        -not [SymphonyWindowsVolumes]::GetVolumeNameForVolumeMountPoint($mount.ToString(), $volume, 1024) -or
        -not [SymphonyWindowsVolumes]::GetDiskFreeSpaceEx($mount.ToString(), [ref]$available, [ref]$total, [ref]$free)) {
        throw 'windows_volume_measurement_unavailable'
    }
    $match = [regex]::Match($volume.ToString(), '\{([0-9a-fA-F-]{36})\}')
    if (-not $match.Success -or $available -gt [Int64]::MaxValue) { throw 'windows_volume_identity_invalid' }
    return @{volume=('volume:' + $match.Groups[1].Value.ToLowerInvariant()); free_bytes=[Int64]$available}
}
function Get-WindowsStorageFrame($Data, [string]$ManagerToken) {
    if ($Data.installation_id -notmatch '^[0-9a-f]{32}$' -or $ManagerToken -notmatch '^[0-9a-f]{32}$') { throw 'windows_disk_identity_invalid' }
    $disks = @{}
    foreach ($role in @('controller','worker')) {
        $distro = $Data.$role.distro
        $disk = @{distro=$distro; volume=$null; free_bytes=$null; error='measurement_unavailable'}
        try {
            $registered = Get-RegisteredDistro $distro
            if ($null -eq $registered -or $registered.Version -ne 2) { throw 'windows_disk_registration_missing' }
            $basePath = [Environment]::ExpandEnvironmentVariables($registered.BasePath)
            $vhd = 'ext4.vhdx'
            if ($registered.PSObject.Properties.Name -contains 'VhdFileName' -and $registered.VhdFileName) { $vhd = $registered.VhdFileName }
            if ([IO.Path]::GetFileName($vhd) -cne $vhd -or $vhd -in @('.','..')) { throw 'windows_disk_filename_invalid' }
            $file = Join-Path $basePath $vhd
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw 'windows_disk_file_missing' }
            $measurement = Get-WindowsVolume $file
            $disk.volume = $measurement.volume; $disk.free_bytes = $measurement.free_bytes; $disk.error = $null
        } catch { }
        $disks[$role] = $disk
    }
    return @{schema_version=1; installation_id=$Data.installation_id; manager_token=$ManagerToken;
             measured_at_ms=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); disks=$disks}
}
function Ensure-Distro($State, [string]$Role, [string]$Rootfs) {
    $name = $State.distros.$Role
    $destination = Join-Path $State.home $Role
    $registered = Get-RegisteredDistro $name
    if ($null -eq $registered) {
        # New ID-derived name and location. Never unregister or overwrite anything.
        if (Test-Path -LiteralPath $destination) { throw 'Partial import directory exists; inspect it before retrying import.' }
        Invoke-Native (Wsl-Path) @('--import', $name, $destination, $Rootfs, '--version','2') | Out-Null
        $registered = Get-RegisteredDistro $name
    }
    if ($null -eq $registered) { throw 'WSL registration not found after import.' }
    $registeredPath = $registered.BasePath
    if ($registeredPath.StartsWith('\\?\')) { $registeredPath = $registeredPath.Substring(4) }
    if ([IO.Path]::GetFullPath($registeredPath).TrimEnd('\') -ine [IO.Path]::GetFullPath($destination).TrimEnd('\')) { throw 'Distro name belongs to another installation.' }
    # Minimal rootfs may lack Python. This is a fixed bootstrap in the verified
    # newly registered distro, not a shell fragment derived from configuration.
    Invoke-Native (Wsl-Path) @('-d',$name,'-u','root','--cd','/','--exec','/bin/sh','-ec','command -v python3 >/dev/null || { apt-get update && apt-get install -y python3; }') | Out-Null
    $claim = Invoke-Provision $State $Role 'claim'
    if ($claim.restart_required) {
        Invoke-Native (Wsl-Path) @('--terminate',$name) | Out-Null
        Invoke-Provision $State $Role 'identity' | Out-Null
    }
}
function Invoke-Stage($State, [string]$Name, [scriptblock]$Action) {
    Write-Host ('[' + $Name + '] Checking and configuring...')
    $State.stage = $Name
    $State.status = 'running'
    if (-not ($State.PSObject.Properties.Name -contains 'history')) { $State | Add-Member NoteProperty history @() }
    $State.history = @($State.history | Select-Object -Last 127) + @(@{stage=$Name; status='running'; at=[DateTime]::UtcNow.ToString('o')})
    Write-Json (Join-Path $State.home 'setup.json') $State
    try {
        & $Action
        $State.status = 'verified'
        $State.history[-1].status = 'verified'
        Write-Json (Join-Path $State.home 'setup.json') $State
    } catch {
        if ($State.status -ne 'needs-input') { $State.status = 'failed' }
        $State.history[-1].status = $State.status
        Write-Json (Join-Path $State.home 'setup.json') $State
        throw ('Setup stage ' + $Name + ' failed: ' + $_.Exception.Message + '. Repeat Setup to resume; existing data is retained.')
    }
}
function Enter-InstallationLock([string]$Id) {
    if ($Id -notmatch '^[0-9a-f]{32}$') { throw 'Invalid installation identity.' }
    $mutex = New-Object Threading.Mutex($false, ('Global\SymphonyInstall-' + $Id))
    try {
        try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another setup, manager or maintenance command owns this installation. Stop it first.' }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}
function Get-HelperNames($Helpers) {
    $names = @('symphony.ps1','setup.ps1','support.ps1','manager.ps1','operator.ps1','operator.py','provision.py')
    if ($Helpers.PSObject.Properties['update.ps1'] -or $Helpers.PSObject.Properties['update.py']) { $names += @('update.ps1','update.py') }
    if (@(Compare-Object ($names | Sort-Object) ($Helpers.PSObject.Properties.Name | Sort-Object)).Count) { throw 'Unknown or incomplete installer helper set.' }
    return $names
}
function Get-HelperRoot($State) {
    if (-not $State.PSObject.Properties['helper_root']) { return (Join-Path $State.home 'installer') }
    $root = [IO.Path]::GetFullPath($State.helper_root)
    $parent = Join-Path $State.home 'installer-releases'
    if ([IO.Path]::GetDirectoryName($root) -ine $parent -or [IO.Path]::GetFileName($root) -notmatch '^[0-9a-f]{24}$') { throw 'Invalid versioned helper directory.' }
    return $root
}
function Verify-Helpers($State) {
    foreach ($name in (Get-HelperNames $State.helpers)) {
        $target = Join-Path (Get-HelperRoot $State) $name
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $State.helpers.$name) { throw ('Installed helper checksum mismatch: ' + $name) }
    }
}
function New-WorkerKeeper($Data) {
    return New-NativeProcess (Wsl-Path) @('-d',$Data.worker.distro,'-u',$Data.runtime_config.worker_user,'--cd','/','--exec','python3','-I','-B','-c','import sys; sys.stdin.buffer.read()') -Redirect
}
function Get-InstallationFile([string]$Path) {
    if ($Path) { return (Resolve-Path -LiteralPath $Path).Path }
    $pointer = Join-Path $env:LOCALAPPDATA 'Symphony/current.json'
    if (-not (Test-Path -LiteralPath $pointer)) { throw 'Run Symphony.cmd Setup first.' }
    return (Read-Json $pointer).installation
}
function Get-Manager($Installation) {
    $file = Join-Path $Installation.install_home 'manager.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $record = Read-Json $file
    if ($record.installation_id -cne $Installation.installation_id) { throw 'Manager scope mismatch.' }
    $process = Get-Process -Id $record.pid -ErrorAction SilentlyContinue
    if ($null -eq $process -or $process.StartTime.ToUniversalTime().Ticks.ToString() -cne $record.start) { return $null }
    return $record
}

function Test-DashboardReady([int]$Port) {
    if ($Port -lt 1024 -or $Port -gt 65535) { throw 'Invalid dashboard port.' }
    # WSL publishes this listener on IPv4. Windows PowerShell 5.1 can spend the
    # entire probe timeout trying ::1 first when the URL contains localhost.
    # Keep the configured origin in Host for the operator authentication check.
    $request = [Net.HttpWebRequest]::Create(('http://127.0.0.1:' + $Port + '/operator/login'))
    $request.Host = 'localhost:' + $Port
    $request.Proxy = $null
    $request.AllowAutoRedirect = $false
    $request.Timeout = 2000
    $request.ReadWriteTimeout = 2000
    $response = $null
    try {
        $response = $request.GetResponse()
        return ([int]$response.StatusCode -eq 200)
    } catch [Net.WebException] {
        if ($null -ne $_.Exception.Response) { $_.Exception.Response.Close() }
        return $false
    } finally {
        if ($null -ne $response) { $response.Close() }
        $request.Abort()
    }
}

function Start-LogDrain($Process, [string]$Directory) {
    if (-not ('SymphonyBoundedLogs' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading.Tasks;
public static class SymphonyBoundedLogs {
  public static Task Drain(Stream input, string path) {
    return Task.Factory.StartNew(() => {
      byte[] buffer = new byte[8192];
      using (var output = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read)) {
        int n;
        while ((n = input.Read(buffer, 0, buffer.Length)) > 0) {
          if (output.Length + n > 8 * 1024 * 1024) { output.SetLength(0); output.Position = 0; }
          output.Write(buffer, 0, n); output.Flush();
        }
      }
    }, TaskCreationOptions.LongRunning);
  }
}
'@
    }
    return @([SymphonyBoundedLogs]::Drain($Process.StandardOutput.BaseStream, (Join-Path $Directory 'controller.stdout.log')),
             [SymphonyBoundedLogs]::Drain($Process.StandardError.BaseStream, (Join-Path $Directory 'controller.stderr.log')))
}
