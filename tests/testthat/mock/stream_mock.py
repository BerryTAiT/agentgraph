#!/usr/bin/env python3
"""Streaming (SSE) mock LLM server for agentgraph streaming tests.

Serves a scripted token sequence as OpenAI-style `stream: true` chat completion
chunks over plain HTTP/SSE so the native C++ WinHTTP + SSE parser can be
exercised offline.

Usage: python stream_mock.py <port_start> <port_end> <tokens_json> <ready_file> <request_log>

tokens_json: a JSON array of strings; each string is emitted as one delta chunk,
followed by a final chunk carrying finish_reason "stop", then data: [DONE].
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main():
    port_start = int(sys.argv[1])
    port_end = int(sys.argv[2])
    tokens_file = sys.argv[3]
    ready_file = sys.argv[4]
    request_log = sys.argv[5]

    with open(tokens_file, "r", encoding="utf-8") as f:
        tokens = json.load(f)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"  # no keep-alive; connection closes after response

        def log_message(self, *args):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0) or 0)
            body = self.rfile.read(length).decode("utf-8", "replace") if length else ""

            if request_log:
                with open(request_log, "a", encoding="utf-8") as f:
                    f.write(" ".join(body.split()) + "\n")

            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()

            for t in tokens:
                chunk = {"choices": [{"delta": {"content": t}, "finish_reason": None}]}
                self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode("utf-8"))
                self.wfile.flush()
                time.sleep(0.02)

            final = {"choices": [{"delta": {}, "finish_reason": "stop"}]}
            self.wfile.write(("data: " + json.dumps(final) + "\n\n").encode("utf-8"))
            self.wfile.write(b"data: [DONE]\n\n")
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
        print("stream_mock: no free port", file=sys.stderr)
        sys.exit(1)

    with open(ready_file, "w") as f:
        f.write(str(server.server_port))

    server.serve_forever()


if __name__ == "__main__":
    main()
