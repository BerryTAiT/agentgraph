#!/usr/bin/env python3
"""Error-path mock LLM server for agentgraph error handling tests.

Serves a scripted sequence of HTTP responses so the native C++ WinHTTP client's
error paths can be exercised offline (non-200 statuses, malformed JSON, etc.).

Usage: python error_mock.py <port_start> <port_end> <scenario_json> <ready_file> <request_log>

scenario_json: a JSON array of response objects, each with:
    status       int HTTP status code (default 200)
    body         string raw response body (default "{}")
    content_type string (default "application/json")
    delay        float seconds to sleep before responding (optional)

Requests are served sequentially; when the list is exhausted the last response
is repeated. Uses HTTP/1.0 + Connection: close so WinHTTP's read loop terminates.
"""
import json
import sys
import time
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main():
    port_start = int(sys.argv[1])
    port_end = int(sys.argv[2])
    scenario_file = sys.argv[3]
    ready_file = sys.argv[4]
    request_log = sys.argv[5]

    with open(scenario_file, "r", encoding="utf-8") as f:
        responses = json.load(f)
    if not responses:
        responses = [{"status": 200, "body": "{}"}]

    idx = [0]
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def log_message(self, *args):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0) or 0)
            body = self.rfile.read(length).decode("utf-8", "replace") if length else ""

            if request_log:
                with open(request_log, "a", encoding="utf-8") as f:
                    f.write(" ".join(body.split()) + "\n")

            with lock:
                i = idx[0]
                if i < len(responses):
                    idx[0] = i + 1
            r = responses[min(i, len(responses) - 1)]

            if r.get("delay"):
                time.sleep(float(r["delay"]))

            raw = str(r.get("body", "{}")).encode("utf-8")
            self.send_response(int(r.get("status", 200)))
            self.send_header("Content-Type", r.get("content_type", "application/json"))
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)
            self.wfile.flush()
            self.close_connection = True

    server = None
    for p in range(port_start, port_end + 1):
        try:
            server = ThreadingHTTPServer(("127.0.0.1", p), Handler)
            break
        except OSError:
            server = None

    if server is None:
        print("error_mock: no free port", file=sys.stderr)
        sys.exit(1)

    with open(ready_file, "w") as f:
        f.write(str(server.server_port))

    server.serve_forever()


if __name__ == "__main__":
    main()
