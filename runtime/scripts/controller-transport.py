#!/usr/bin/env python3
"""One framed request from the trusted controller. Never offered as an agent tool."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from symphony_runtime.client import accept_export, exchange
from symphony_runtime.common import Rejected, identifier, private_file, read_json, require, sha
from symphony_runtime.guardian import header, send_header


def main():
    require(len(sys.argv) == 3 and sys.argv[1] == "--config", "transport_configuration_required")
    config = read_json(private_file(sys.argv[2]))
    require(set(config) == {"ssh_config", "destination", "export_directory", "cycle", "branch", "interval", "generation"}, "invalid_transport_configuration")
    for key in ("cycle", "interval", "generation"):
        identifier(config[key])
    request = header(sys.stdin.buffer)
    require(request.get("interval") == config["interval"] and request.get("generation") == config["generation"], "transport_binding_mismatch")
    action = request.get("action")
    require(action in ("stop", "export"), "transport_operation_not_allowed")
    expected = {"action", "interval", "generation"} | ({"sha"} if action == "export" else set())
    require(set(request) == expected, "invalid_transport_fields")
    if action == "export":
        sha(request["sha"])
    proof, data = exchange(config["ssh_config"], config["destination"], request)
    require(all(proof.get(key) == config[key] for key in ("cycle", "branch", "interval", "generation")), "transport_scope_mismatch")
    if action == "stop":
        require(proof.get("phase") == "stopped" and proof.get("generation") == config["generation"] and proof.get("interval") == config["interval"], "stop_unconfirmed")
    else:
        require(proof.get("sha") == request["sha"], "export_sha_mismatch")
        proof = {"path": accept_export(config["export_directory"], config["generation"], proof, data),
                 "sha": request["sha"], **{key: config[key] for key in ("cycle", "branch", "interval", "generation")}}
    send_header(sys.stdout.buffer, {"ok": proof})


try:
    main()
except (Rejected, OSError, ValueError, KeyError):
    send_header(sys.stdout.buffer, {"error": "worker_transport_unconfirmed"})
    raise SystemExit(1)
