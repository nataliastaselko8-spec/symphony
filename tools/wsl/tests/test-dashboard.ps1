# Actual Windows PowerShell HTTP stack, IPv4-only fixture and hostile default proxy.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support.ps1')
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public sealed class DashboardFixture : IDisposable {
  public readonly TcpListener Listener;
  public readonly int Port;
  public readonly Task Worker;
  public string Request;
  public DashboardFixture(int status, int delay) {
    Listener = new TcpListener(IPAddress.Loopback, 0); Listener.Start();
    Port = ((IPEndPoint)Listener.LocalEndpoint).Port;
    Worker = Task.Factory.StartNew(() => {
      try {
        using (var client = Listener.AcceptTcpClient()) {
          client.ReceiveTimeout = 4000;
          var stream = client.GetStream();
          var reader = new StreamReader(stream, Encoding.ASCII);
          var headers = new StringBuilder(); string line;
          while (!String.IsNullOrEmpty(line = reader.ReadLine())) headers.AppendLine(line);
          Request = headers.ToString(); Thread.Sleep(delay);
          var bytes = Encoding.ASCII.GetBytes("HTTP/1.1 " + status + " Fixture\r\nContent-Length: 0\r\nConnection: close\r\nLocation: http://localhost:1/\r\n\r\n");
          stream.Write(bytes, 0, bytes.Length);
        }
      } catch (IOException) {} catch (SocketException) {}
    }, TaskCreationOptions.LongRunning);
  }
  public void Dispose() { Listener.Stop(); Worker.Wait(5000); }
}
'@
$originalProxy = [Net.WebRequest]::DefaultWebProxy
try {
    [Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy('http://127.0.0.1:1', $false)
    foreach ($case in @(@(200,0,$true), @(302,0,$false), @(503,0,$false), @(200,2500,$false))) {
        $fixture = New-Object DashboardFixture($case[0],$case[1])
        try {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $result = Test-DashboardReady $fixture.Port
            if ($result -ne $case[2]) { throw ('Unexpected readiness for status '+$case[0]+' delay '+$case[1]) }
            if ($watch.ElapsedMilliseconds -gt 4500) { throw 'HTTP probe exceeded bounded timeout' }
            if (-not $fixture.Request.Contains('Host: localhost:'+$fixture.Port)) { throw 'Operator origin was not preserved' }
            if (-not $fixture.Request.StartsWith('GET /operator/login HTTP/1.1')) { throw 'Wrong readiness path' }
        } finally { $fixture.Dispose() }
    }
    Write-Host 'PASS IPv4-only readiness, preserved Host, proxy bypass, redirect/error rejection and timeout'
} finally { [Net.WebRequest]::DefaultWebProxy = $originalProxy }
