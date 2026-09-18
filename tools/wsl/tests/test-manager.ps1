# Real hidden Windows manager/child processes; WSL/HTTP/stop proof are fixtures.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../support.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('symphony-manager-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$manager=$null
function Assert($Ok,$Message) { if (-not $Ok) { throw $Message } }
try {
    $exe=Join-Path $root 'process-fixture.exe'
    Add-Type -OutputAssembly $exe -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public class ProcessFixture {
  public static int Main(string[] args) {
    string root = args[0], role = args[1];
    File.WriteAllText(Path.Combine(root, role + ".pid"), System.Diagnostics.Process.GetCurrentProcess().Id.ToString());
    bool closed = false;
    var reader = new Thread(() => { while(Console.ReadLine() != null) {} closed = true; });
    reader.IsBackground = true; reader.Start();
    while (!closed && !(role == "controller" && File.Exists(Path.Combine(root,"stop-controller")))) Thread.Sleep(20);
    File.WriteAllText(Path.Combine(root,role + ".exited"),"yes");
    return 0;
  }
}
'@
    $installer=Join-Path $root 'installer'
    [IO.Directory]::CreateDirectory($installer) | Out-Null
    $names=@('symphony.ps1','setup.ps1','support.ps1','manager.ps1','operator.ps1','operator.py','provision.py')
    foreach ($name in $names) { [IO.File]::Copy((Join-Path $PSScriptRoot ('../'+$name)),(Join-Path $installer $name)) }
    # Replace only the fixture copy's external boundaries. The manager itself
    # runs unchanged, including its mutex, process identity, lease and journals.
    $fake=@'

$script:fixtureRoot=Split-Path -Parent $PSScriptRoot
$function:FixtureNative=${function:New-NativeProcess}
function New-NativeProcess {
    param($File,$Arguments,[switch]$Redirect)
    $role=if ($Arguments -contains '--supervised') { 'controller' } else { 'worker' }
    return FixtureNative (Join-Path $script:fixtureRoot 'process-fixture.exe') @($script:fixtureRoot,$role) -Redirect
}
function Invoke-Native {
    param($File,$Arguments,$InputFile,$TimeoutSeconds)
    if ($Arguments -contains 'Prime') { return '{"script":"/fixture.py","installation":"/fixture.json"}' }
    if ($Arguments -contains 'Stop') {
        [IO.File]::WriteAllText((Join-Path $script:fixtureRoot 'stop-controller'),'stop')
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath (Join-Path $script:fixtureRoot 'controller.exited'))) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'fixture_stop_unconfirmed' }
            Start-Sleep -Milliseconds 20
        }
        return '{"stopped":true}'
    }
    throw 'unexpected_fixture_native_command'
}
function Invoke-WebRequest { param([switch]$UseBasicParsing,$Uri,$TimeoutSec); return [pscustomobject]@{StatusCode=200} }
'@
    [IO.File]::AppendAllText((Join-Path $installer 'support.ps1'),$fake)
    $id=[Guid]::NewGuid().ToString('N')
    $data=@{installation_id=$id; install_home=$root; worker=@{distro='fixture-worker'}; controller=@{distro='fixture-controller'; user='fixture'}; runtime_config=@{worker_user='fixture'; dashboard_port=12345}}
    $descriptor=Join-Path $root 'installation.json'; Write-Json $descriptor $data
    $helpers=@{}
    foreach ($name in $names) { $helpers[$name]=(Get-FileHash -LiteralPath (Join-Path $installer $name) -Algorithm SHA256).Hash.ToLowerInvariant() }
    Write-Json (Join-Path $root 'setup.json') @{id=$id; home=$root; helpers=$helpers}
    $shell=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $argsList=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $installer 'manager.ps1'),'-Installation',$descriptor)
    $manager=Start-Process -FilePath $shell -ArgumentList (@($argsList | ForEach-Object { Quote-NativeArgument $_ }) -join ' ') -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $root 'manager-error.txt')
    $recordPath=Join-Path $root 'manager.json'
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 100
        if (Test-Path -LiteralPath $recordPath) { $record=Read-Json $recordPath; if ($record.phase -eq 'ready') { break } }
    } while (-not $manager.HasExited -and [DateTime]::UtcNow -lt $deadline)
    if ($manager.HasExited) {
        $details = $(if (Test-Path -LiteralPath $recordPath) { [IO.File]::ReadAllText($recordPath) } else { 'no record' })
        throw ('Manager exited before readiness: ' + $details + [IO.File]::ReadAllText((Join-Path $root 'manager-error.txt')))
    }
    Assert ($record.phase -eq 'ready') ('Manager not ready: '+($record | ConvertTo-Json -Compress))
    $identity=Get-Manager ([pscustomobject]$data)
    Assert ($identity.token -ceq $record.token) 'Manager process identity did not match'
    # An unrelated/stale request cannot stop this owner.
    Write-Json (Join-Path $root 'stop-request.json') @{installation_id=$id; token='stale'}
    Start-Sleep -Seconds 4
    Assert (-not $manager.HasExited -and (Read-Json $recordPath).phase -eq 'ready') 'Stale stop affected current owner'
    Write-Json (Join-Path $root 'stop-request.json') @{installation_id=$id; token=$record.token}
    Assert ($manager.WaitForExit(15000)) 'Manager did not finish confirmed stop'
    $record=Read-Json $recordPath
    Assert ($record.phase -eq 'stopped' -and $record.stopped) 'Manager published wrong stop outcome'
    Assert (Test-Path -LiteralPath (Join-Path $root 'controller.exited')) 'Controller survived stop'
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath (Join-Path $root 'worker.exited')) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    Assert (Test-Path -LiteralPath (Join-Path $root 'worker.exited')) 'Worker keepalive survived stop'
    Assert ($null -eq (Get-Manager ([pscustomobject]$data))) 'Dead manager still reported live'
    Write-Host 'PASS hidden manager readiness, retained child processes, stale stop rejection and confirmed shutdown'
} finally {
    if ($null -ne $manager) { if (-not $manager.HasExited) { $manager.Kill(); $manager.WaitForExit() }; $manager.Dispose() }
    foreach ($role in @('worker','controller')) {
        $pidFile=Join-Path $root ($role+'.pid')
        if (Test-Path -LiteralPath $pidFile) {
            $child=Get-Process -Id ([int][IO.File]::ReadAllText($pidFile)) -ErrorAction SilentlyContinue
            if ($null -ne $child -and $child.Path -ieq $exe) { $child.Kill(); $child.WaitForExit(); $child.Dispose() }
        }
    }
    $resolved=[IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -cne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($resolved) -notmatch '^symphony-manager-[0-9a-f]{32}$') { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
