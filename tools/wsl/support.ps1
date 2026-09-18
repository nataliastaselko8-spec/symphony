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
        foreach ($name in @($Value.PSObject.Properties.Name | Sort-Object)) { $result[$name] = Canonical-Value $Value.$name }
        return $result
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { Canonical-Value $_ }) }
    return $Value
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
    if (-not $process.Start()) { throw 'Process did not start.' }
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
    foreach ($name in @('symphony.ps1','setup.ps1','support.ps1','manager.ps1','operator.ps1','operator.py','provision.py')) {
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
function Verify-Helpers($State) {
    foreach ($name in @('symphony.ps1','setup.ps1','support.ps1','manager.ps1','operator.ps1','operator.py','provision.py')) {
        $target = Join-Path $State.home ('installer/' + $name)
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
