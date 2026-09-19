#!/usr/bin/env python3
"""Latent mock LLM server for agentgraph parallel-fan-out concurrency tests.

Adds a fixed per-request latency and echoes the request's system prompt back as
the assistant content, so each concurrent child node can be identified by its
own response. Threaded so concurrent requests overlap.

Usage: python latent_mock.py <port_start> <port_end> <delay_seconds> <ready_file> <request_log>
"""
import json
import sys
import time
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log_lock = threading.Lock()


class SingleBindServer(ThreadingHTTPServer):
    # Disable SO_REUSEADDR so two concurrent mocks cannot bind the same port
    # on Windows (see mock_llm_server.py for details).
    allow_reuse_address = False


def main():
    port_start = int(sys.argv[1])
    port_end = int(sys.argv[2])
    delay = float(sys.argv[3])
    ready_file = sys.argv[4]
    request_log = sys.argv[5]

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0) or 0)
            body = self.rfile.read(length).decode("utf-8", "replace") if length else ""

            system_prompt = ""
            try:
                parsed = json.loads(body)
                for m in parsed.get("messages", []):
                    if m.get("role") == "system":
                        system_prompt = m.get("content", "")
                        break
            except Exception:
                system_prompt = ""

            time.sleep(delay)

            if request_log:
                with log_lock:
                    with open(request_log, "a", encoding="utf-8") as f:
                        f.write(system_prompt + "\n")
                        f.flush()

            payload = {
                "id": "chatcmpl-latent",
                "object": "chat.completion",
                "created": 0,
                "model": "mock-model",
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": system_prompt},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            }
            data = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = None
    for p in range(port_start, port_end + 1):
        try:
            server = SingleBindServer(("127.0.0.1", p), Handler)
            break
        except OSError:
            server = None

    if server is None:
        print("latent_mock: no free port", file=sys.stderr)
        sys.exit(1)

    with open(ready_file, "w") as f:
        f.write(str(server.server_port))

    server.serve_forever()


if __name__ == "__main__":
    main()
