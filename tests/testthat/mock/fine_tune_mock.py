#!/usr/bin/env python3
"""agentgraph fine-tuning mock server (test harness only).

Serves the OpenAI fine-tuning endpoints so fine_tune()/fine_tune_status() can be
exercised offline:

  POST /files                            -> {"id":"file-mock-1"}
  POST /fine_tuning/jobs                 -> {"id":"ftjob-mock-1","status":"queued"}
  GET  /fine_tuning/jobs                 -> {"data":[{...}]}
  GET  /fine_tuning/jobs/<id>            -> {"id":...,"status":"succeeded","fine_tuned_model":"ft:gpt-4o-mini:mock"}
  POST /fine_tuning/jobs/<id>/cancel     -> {"id":...,"status":"cancelled"}

Usage: python fine_tune_mock.py <port_start> <port_end> <ready_file> <request_log>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class SingleBindServer(ThreadingHTTPServer):
    allow_reuse_address = False


def main():
    port_start = int(sys.argv[1])
    port_end = int(sys.argv[2])
    ready_file = sys.argv[3]

    job = {
        "id": "ftjob-mock-1",
        "status": "succeeded",
        "model": "gpt-4o-mini",
        "fine_tuned_model": "ft:gpt-4o-mini:mock",
        "training_file": "file-mock-1",
    }

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _send(self, obj, status=200):
            data = json.dumps(obj).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0) or 0)
            if length:
                self.rfile.read(length)
            p = self.path.rstrip("/")
            if p.endswith("/files"):
                self._send({"id": "file-mock-1", "purpose": "fine-tune"})
            elif p.endswith("/cancel"):
                self._send({**job, "status": "cancelled"})
            elif p.endswith("/fine_tuning/jobs"):
                self._send({**job, "status": "queued", "fine_tuned_model": None})
            else:
                self._send({"error": "not found"}, 404)

        def do_GET(self):
            p = self.path.rstrip("/")
            if p.endswith("/fine_tuning/jobs"):
                self._send({"data": [job], "has_more": False})
            elif "/fine_tuning/jobs/" in p:
                self._send(job)
            else:
                self._send({"error": "not found"}, 404)

    server = None
    for port in range(port_start, port_end + 1):
        try:
            server = SingleBindServer(("127.0.0.1", port), Handler)
            break
        except OSError:
            server = None
    if server is None:
        print("fine_tune_mock: no free port", file=sys.stderr)
        sys.exit(1)

    with open(ready_file, "w") as f:
        f.write(str(server.server_port))
    server.serve_forever()


if __name__ == "__main__":
    main()
