#!/usr/bin/env python3
"""Streaming (SSE) mock LLM server for agentgraph streaming tests.

Serves a scripted token sequence as OpenAI-style `stream: true` chat completion
chunks over plain HTTP/SSE so the native C++ WinHTTP + SSE parser can be
exercised offline.

Usage: python stream_mock.py <port_start> <port_end> <tokens_json> <ready_file> <request_log>

tokens_json, either:
  - a JSON array of strings: each string is emitted as one content delta chunk,
    followed by a final chunk with finish_reason "stop", then data: [DONE]; or
  - a JSON object:
      {"tokens": ["Hel", "lo"],
       "tool_calls": [{"id": "call_1", "name": "calculator",
                       "arg_fragments": ['{"expr', 'ession":', '"2+3"}']}],
       "final_finish": "tool_calls"}
    which additionally emits tool-call deltas with the arguments split across
    fragments (as real providers do), exercising argument accumulation.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class SingleBindServer(ThreadingHTTPServer):
    # Disable SO_REUSEADDR so two concurrent mocks cannot bind the same port
    # on Windows (see mock_llm_server.py for details).
    allow_reuse_address = False


def build_chunks(spec):
    chunks = []
    tokens = spec if isinstance(spec, list) else spec.get("tokens", [])
    if isinstance(tokens, str):
        tokens = [tokens]
    for t in tokens:
        chunks.append({"choices": [{"delta": {"content": t}, "finish_reason": None}]})

    if isinstance(spec, dict):
        for tc in spec.get("tool_calls", []):
            first = {
                "index": 0,
                "id": tc.get("id", "call_1"),
                "type": "function",
                "function": {"name": tc.get("name", ""), "arguments": ""},
            }
            chunks.append({"choices": [{"delta": {"tool_calls": [first]},
                                        "finish_reason": None}]})
            for frag in tc.get("arg_fragments", []):
                part = {"index": 0,
                        "function": {"arguments": frag}}
                chunks.append({"choices": [{"delta": {"tool_calls": [part]},
                                            "finish_reason": None}]})

    final_finish = "stop"
    if isinstance(spec, dict):
        final_finish = spec.get("final_finish", "stop")
    chunks.append({"choices": [{"delta": {}, "finish_reason": final_finish}]})
    return chunks


def main():
    port_start = int(sys.argv[1])
    port_end = int(sys.argv[2])
    tokens_file = sys.argv[3]
    ready_file = sys.argv[4]
    request_log = sys.argv[5]

    with open(tokens_file, "r", encoding="utf-8") as f:
        spec = json.load(f)
    chunks = build_chunks(spec)

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

            for chunk in chunks:
                self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode("utf-8"))
                self.wfile.flush()
                time.sleep(0.02)

            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            self.close_connection = True

    server = None
    for p in range(port_start, port_end + 1):
        try:
            server = SingleBindServer(("127.0.0.1", p), Handler)
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
