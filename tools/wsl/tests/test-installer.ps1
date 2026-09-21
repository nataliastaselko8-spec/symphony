# Actual Windows PowerShell 5.1 filesystem, native argv and binary pipe tests.
param([string]$WslDistro)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('symphony-installer-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$passed = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Rejects([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch { Assert ($_.Exception.Message -match $Pattern) ('Unexpected error: ' + $_.Exception.Message); return }
    throw ('Expected failure: ' + $Pattern)
}
try {
    $exe = Join-Path $root 'native fixture.exe'
    Add-Type -OutputAssembly $exe -OutputType ConsoleApplication -ReferencedAssemblies System.Web.Extensions -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Security.Cryptography;
using System.Web.Script.Serialization;
public class NativeFixture {
  public static int Main(string[] args) {
    Console.OutputEncoding = new UTF8Encoding(false);
    if (args.Length > 0 && args[0] == "wait") { System.Threading.Thread.Sleep(10000); return 0; }
    if (args.Length > 0 && args[0] == "fail") { Console.Error.WriteLine("secret must not escape"); return 7; }
    if (args.Length > 0 && args[0] == "logs") {
      byte[] log = new byte[1024 * 1024];
      for (int i = 0; i < 12; i++) { Console.OpenStandardOutput().Write(log, 0, log.Length); Console.OpenStandardError().Write(log, 0, log.Length); }
      return 0;
    }
    string hash;
    using (var sha = SHA256.Create()) { hash = BitConverter.ToString(sha.ComputeHash(Console.OpenStandardInput())).Replace("-", "").ToLowerInvariant(); }
    Console.WriteLine(new JavaScriptSerializer().Serialize(new { arguments = args, sha256 = hash }));
    return 0;
  }
}
'@
    $values = @('', 'spaces here', ('unicode ' + [char]0x044F), 'a"b', '\\server\path with spaces\', 'trailing\', '$() & ` > ^ !')
    $output = Invoke-Native $exe $values | ConvertFrom-Json
    Assert ($output.arguments.Count -eq $values.Count) 'Native argv count changed'
    for ($i = 0; $i -lt $values.Count; $i++) { Assert ($output.arguments[$i] -ceq $values[$i]) ('Native argv changed at ' + $i) }
    $passed++
    if ($WslDistro) {
        $actual = Invoke-Native (Wsl-Path) @('-d',$WslDistro,'--cd','/','--exec','/usr/bin/python3','-I','-B','-c','import json,sys;print(json.dumps(sys.argv[1:]))','spaces here','quote"value')
        $parsed = $actual | ConvertFrom-Json
        Assert ($parsed.Count -eq 2 -and $parsed[0] -ceq 'spaces here' -and $parsed[1] -ceq 'quote"value') 'WSL raw argument parsing changed'
        $passed++
    }
    $binary = Join-Path $root ('binary ' + [char]0x044F + '.bin')
    $bytes = New-Object byte[] (2MB)
    for ($i=0; $i -lt $bytes.Length; $i++) { $bytes[$i] = $i % 256 }
    [IO.File]::WriteAllBytes($binary, $bytes)
    $output = Invoke-Native $exe @('binary') -InputFile $binary | ConvertFrom-Json
    Assert ($output.sha256 -ieq (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash) 'Binary stdin was corrupted'
    $passed++
    Rejects { Invoke-Native $exe @('fail') } 'native_command_failed_.*_exit_7'
    $passed++
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Rejects { Invoke-Native $exe @('wait') -InputFile $binary -TimeoutSeconds 1 } 'timed out'
    Assert ($watch.Elapsed.TotalSeconds -lt 8) 'Blocked stdin ignored transfer deadline'
    $passed++
    $process = New-NativeProcess $exe @('logs') -Redirect
    try {
        $tasks = Start-LogDrain $process $root
        $process.StandardInput.Close()
        Assert ($process.WaitForExit(15000)) 'Log drain deadlocked'
        [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks, 5000) | Out-Null
        foreach ($name in @('controller.stdout.log','controller.stderr.log')) { Assert ((Get-Item -LiteralPath (Join-Path $root $name)).Length -le 8MB) 'Log grew beyond limit' }
    } finally { if (-not $process.HasExited) { $process.Kill() }; $process.Dispose() }
    $passed++
    $state = Join-Path $root 'checkpoint.json'
    Write-Json $state @{step=1}
    Write-Json $state @{step=2}
    Assert ((Read-Json $state).step -eq 2) 'Atomic checkpoint replacement failed'
    Assert (@(Get-ChildItem -LiteralPath $root -Filter '*.pending').Count -eq 0) 'Pending checkpoint leaked'
    $passed++
    $private = New-PrivateDirectory (Join-Path $root 'private')
    $acl = Get-Acl -LiteralPath $private
    Assert $acl.AreAccessRulesProtected 'Private installation inherits broad ACL'
    Assert ($acl.Access.Count -eq 2) 'Unexpected identities in private ACL'
    $passed++
    $id = [Guid]::NewGuid().ToString('N')
    $mutex = Enter-InstallationLock $id
    # Mutexes are recursive within a thread. A second runspace proves exclusion.
    $second = [PowerShell]::Create()
    try {
        $second.AddScript('param($support,$id) . $support; $m=Enter-InstallationLock $id; $m.ReleaseMutex(); $m.Dispose()').AddArgument((Join-Path $PSScriptRoot '../support.ps1')).AddArgument($id) | Out-Null
        try { $null = $second.Invoke() } catch { Assert ($_.Exception.Message -match 'owns this installation') 'Unexpected mutex error' }
        Assert $second.HadErrors 'Another manager/setup acquired installation lock'
    } finally { $second.Dispose(); $mutex.ReleaseMutex(); $mutex.Dispose() }
    $passed++
    # A real checksummed fixture bundle validates before any distro can be created.
    $assets = @{}
    foreach ($name in @('rootfs','mise','worker_image','symphony','profile','runtime')) {
        $assets[$name] = @{file=[IO.Path]::GetFileName($binary); size=$bytes.Length; sha256=(Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    $helpers = @{}
    foreach ($name in @('symphony.ps1','setup.ps1','support.ps1','manager.ps1','operator.ps1','operator.py','provision.py')) {
        $raw = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $PSScriptRoot ('../' + $name))).Replace("`r`n","`n"))
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $helpers[$name] = ([BitConverter]::ToString($sha.ComputeHash($raw))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    }
    # Manifest asset filenames deliberately permit only portable ASCII names.
    $portable = Join-Path $root 'asset.bin'
    [IO.File]::Copy($binary, $portable)
    foreach ($asset in $assets.Values) { $asset.file='asset.bin' }
    $manifest = @{schema_version=1; architecture='x86_64'; runtime_contract=2; symphony_commit=('a'*40); profile_revision=('b'*40); worker_image=('sha256:'+'c'*64); toolchain=@{erlang='28.4'; elixir='1.19.5-otp-28'}; assets=$assets; installer=$helpers}
    $bundle = Join-Path $root 'bundle.json'
    Write-Json $bundle $manifest
    $hash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
    $null = Read-Bundle $bundle $hash
    $passed++
    Rejects { Read-Bundle $bundle ('0'*64) } 'manifest checksum mismatch'
    [IO.File]::WriteAllText($portable, 'corrupt')
    Rejects { Read-Bundle $bundle $hash } 'Asset checksum mismatch'
    $passed++
    Write-Host ('PASS ' + $passed + ' installer/native transport scenarios (Windows PowerShell ' + $PSVersionTable.PSVersion + ')')
} finally {
    # Only the exact, resolved GUID fixture directory created above.
    $resolved = [IO.Path]::GetFullPath($root)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -cne $expectedParent -or [IO.Path]::GetFileName($resolved) -notmatch '^symphony-installer-[0-9a-f]{32}$') { throw 'Unsafe test cleanup target' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
