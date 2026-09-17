"""Fixed read-only bootstrap program, sent via SSH stdin into the empty worker."""
import json
import selectors
import subprocess
import time


def query():
    subprocess.run(["codex", "login", "status"], check=True, timeout=10,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    proc = subprocess.Popen(["codex", "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, bufsize=0)
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    buffer = b""
    deadline = time.monotonic() + 60
    sequence = 0
    def rpc(method, params):
        nonlocal buffer, sequence
        sequence += 1
        proc.stdin.write((json.dumps({"id": sequence, "method": method, "params": params}) + "\n").encode())
        while time.monotonic() < deadline:
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                value = json.loads(line)
                if value.get("id") == sequence:
                    if "error" in value:
                        raise ValueError("catalog_rpc_failed")
                    return value["result"]
            if selector.select(max(0, deadline - time.monotonic())):
                chunk = proc.stdout.read(65536)
                if not chunk:
                    raise ValueError("catalog_closed")
                buffer += chunk
                if len(buffer) > 1048576:
                    raise ValueError("catalog_too_large")
        raise ValueError("catalog_timeout")
    try:
        rpc("initialize", {"clientInfo": {"name": "symphony-model-catalog", "version": "1"}})
        proc.stdin.write(b'{"method":"initialized","params":{}}\n')
        models, cursors, cursor = [], set(), None
        for _ in range(20):
            result = rpc("model/list", {"limit": 100, "includeHidden": False, "cursor": cursor})
            models.extend(result["data"])
            if len(models) > 2000:
                raise ValueError("catalog_too_large")
            cursor = result.get("nextCursor")
            if cursor is None:
                return {"data": models}
            if not isinstance(cursor, str) or cursor in cursors:
                raise ValueError("catalog_cursor_invalid")
            cursors.add(cursor)
        raise ValueError("catalog_pages_exceeded")
    finally:
        selector.close()
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        proc.stdin.close()
        proc.stdout.close()


if __name__ == "__main__":
    try:
        print(json.dumps(query()))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print('{"error":"model_catalog_unavailable"}')
        raise SystemExit(1)
