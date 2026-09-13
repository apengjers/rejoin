#!/usr/bin/env python3
# Rejoin heartbeat server (pure Python stdlib, no dependencies).
#
# Listens on 127.0.0.1:<port> for POST /heartbeat from Roblox clones (executor's
# raw `request()`, NOT HttpService which is proxied by Roblox servers). Each hit
# updates an in-memory map key -> last-seen epoch and rewrites the state file so
# the Lua monitor can read it without any network call.
#
# State file format (simple line-based, no JSON needed by Lua):
#   <key>=<unix_epoch>
#
# Usage:
#   python scripts/heartbeat_server.py --state data/heartbeat_state.txt --port 8080

import argparse
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state_path = None
state = {}


def now():
    return int(time.time())


def write_state():
    tmp = state_path + ".tmp"
    try:
        with open(tmp, "w") as f:
            for k, v in sorted(state.items()):
                f.write("%s=%d\n" % (k, v))
        os.replace(tmp, state_path)
    except OSError:
        pass


class Handler(BaseHTTPRequestHandler):
    server_version = "RejoinHeartbeat/1.0"

    def log_message(self, fmt, *args):
        pass

    def _read_json(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(n) if n > 0 else b"{}"
        if not raw:
            raw = b"{}"
        return json.loads(raw.decode("utf-8", "replace"))

    def do_POST(self):
        if self.path != "/heartbeat":
            self.send_error(404)
            return
        try:
            data = self._read_json()
            key = str(data.get("app") or data.get("acc") or "").strip()
            if not key:
                self.send_response(400)
                self.end_headers()
                return
            state[key] = now()
            write_state()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK")
        except Exception:
            self.send_response(400)
            self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            body = json.dumps(state, separators=(",", ":")).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)


def main():
    global state_path
    ap = argparse.ArgumentParser(description="Rejoin heartbeat receiver")
    ap.add_argument("--state", default="data/heartbeat_state.txt")
    ap.add_argument("--port", type=int, default=8080)
    args = ap.parse_args()
    state_path = args.state
    os.makedirs(os.path.dirname(os.path.abspath(state_path)), exist_ok=True)
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print("heartbeat server: 127.0.0.1:%d state=%s" % (args.port, args.state), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()