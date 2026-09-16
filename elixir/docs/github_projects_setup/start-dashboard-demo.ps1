$ErrorActionPreference = 'Stop'
try {
    Write-Host 'Starting Symphony demo dashboard (empty queue)...'
    $launchCode = @"
import json
import pathlib
import socket
import subprocess
import time
import urllib.request

url = 'http://127.0.0.1:4080'
root = pathlib.Path('/home/nataselko/.local/state/symphony-dashboard-demo')
workflow = root / 'WORKFLOW.md'

def ready():
    try:
        with urllib.request.urlopen(url + '/api/v1/state', timeout=1) as response:
            state = json.load(response)
        with urllib.request.urlopen(url, timeout=1) as response:
            page = response.read().decode()
        return 'Symphony' in page and all(key in state for key in ('counts', 'running', 'retrying'))
    except Exception:
        return False

if ready():
    print('Dashboard is already running.')
    raise SystemExit(0)

if not workflow.is_file():
    raise SystemExit('Demo workflow missing: ' + str(workflow))
with socket.socket() as probe:
    try:
        probe.bind(('127.0.0.1', 4080))
    except OSError:
        raise SystemExit('Port 4080 is busy. Stop the other application and try again.')

with (root / 'server.log').open('ab') as log:
    process = subprocess.Popen([
        '/home/nataselko/.local/bin/mise', 'exec', '--', './bin/symphony',
        '--i-understand-that-this-will-be-running-without-the-usual-guardrails',
        '--logs-root', str(root / 'logs'), str(workflow)
    ], cwd='/mnt/d/symphony/elixir', stdin=subprocess.DEVNULL,
       stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
(root / 'server.pid').write_text(str(process.pid))
for attempt in range(30):
    if ready():
        print('Dashboard is ready: http://localhost:4080')
        break
    if process.poll() is not None:
        raise SystemExit('Startup failed. See ' + str(root / 'server.log'))
    time.sleep(1)
else:
    raise SystemExit('Startup timed out. See ' + str(root / 'server.log'))
"@
    $launchCode | wsl.exe -d Ubuntu -u nataselko --cd / --exec python3 -I -
    if ($LASTEXITCODE -ne 0) { throw 'Symphony could not start. See the message above.' }
    Start-Process 'http://localhost:4080'
} catch {
    Write-Host $_ -ForegroundColor Red
    Read-Host 'Press Enter to close'
    exit 1
}
