"""Opt-in acceptance of a real Linux escript and management SSH endpoint; no live credentials or task."""
import argparse
import html
import http.cookiejar
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from symphony_runtime import cli, config
from symphony_runtime.common import private_file, require


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, help="Dedicated private fixture configuration, never a real installation")
    args = parser.parse_args()
    value = config.load(args.config)
    require(not value["pilot_item_ids"] and value["role"] == "controller", "empty_fixture_controller_required")
    require(private_file(value["app_key"]).read_bytes() == b"PR13_INVALID_KEY_FIXTURE\n", "invalid_fixture_key_required")
    root = Path(value["state_root"])
    require(not (root / "delivery.json").exists() and not (root / "worker.json").exists(), "fresh_fixture_state_required")
    entry = str(Path(value["symphony_root"]) / "runtime/scripts/runtime.py")
    argv = [sys.executable, "-I", "-B", entry]
    env = {"HOME": str(Path.home()), "PATH": os.environ["PATH"], "LANG": "C.UTF-8",
           "SYMPHONY_GITHUB_APP_ID": "1", "SYMPHONY_GITHUB_APP_CLIENT_ID": "fixture", "SYMPHONY_GITHUB_INSTALLATION_ID": "1"}
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    origin = "http://localhost:" + str(value["dashboard_port"])

    def page(path, body=None):
        data = urllib.parse.urlencode(body).encode() if body is not None else None
        request = urllib.request.Request(origin + path, data=data, headers={"Origin": origin})
        with opener.open(request, timeout=5) as response:
            return response.read(2 * 1024**2).decode()

    with (root / "packaged-smoke.log").open("wb") as log:
        process = subprocess.Popen([*argv, "launch", "--execute", "--config", args.config], env=env, cwd="/tmp",
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 45
            login = None
            while time.monotonic() < deadline and process.poll() is None:
                try:
                    login = page("/operator/login")
                    break
                except (OSError, urllib.error.URLError):
                    time.sleep(0.2)
            require(login and "Вход оператора" in login, "packaged_dashboard_unavailable")
            print("PASS PACKAGED_LOGIN_PAGE", flush=True)
            csrf = html.unescape(re.search(r'name="_csrf_token" value="([^"]+)"', login)[1])
            dashboard = page("/operator/login", {"_csrf_token": csrf, "credential": private_file(value["operator_credential"]).read_text().strip()})
            require("Symphony" in dashboard and "Вход оператора" not in dashboard, "operator_login_failed")
            state = json.loads(page("/api/v1/state"))
            require(isinstance(state, dict), "dashboard_state_missing")
            (root / "packaged-dashboard.html").write_text(dashboard)
            (root / "packaged-state.json").write_text(json.dumps(state, sort_keys=True))
            report = cli.status_report(value)
            require(report["running"] and report["execution_enabled"] and not report["worker"]["ready"], "worker_admission_not_closed")
            require("model_selection_required" in report["worker"]["reasons"], "model_selection_not_enforced")
            require(report["task"] is None, "unexpected_fixture_task")
            print("PASS PACKAGED_OPERATOR_DASHBOARD_AND_BLOCKED_WORKER", flush=True)
            second = subprocess.run([*argv, "launch", "--execute", "--config", args.config], env=env, cwd="/tmp", capture_output=True, timeout=30)
            require(second.returncode != 0 and b"already_running" in second.stderr, "second_launcher_not_rejected")
            print("PASS SECOND_LAUNCHER_REJECTED", flush=True)
            stopped = cli.stop_inspection(value)
            require(stopped["stopped"] and process.wait(timeout=15) == 0, "packaged_shutdown_unconfirmed")
            require((root / "shutdown.ack").exists() and not cli.status(value)["running"], "shutdown_ack_missing")
            require(not (root / "attempts").exists() or not list((root / "attempts").iterdir()), "unexpected_worker_attempt")
            print("PASS PACKAGED_CONFIRMED_SHUTDOWN; SUMMARY PASS", flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=120)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    main()
