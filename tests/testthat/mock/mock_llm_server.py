#!/usr/bin/env python3
"""agentgraph mock LLM server (test harness only).

Serves a scripted sequence of OpenAI chat-completions responses over plain
HTTP so the native C++ WinHTTP client can be exercised offline. Responses
come from a scenario JSON file (an array of response objects), served in
order; the final entry repeats for any further request.

Usage: python mock_llm_server.py <port_start> <port_end> <scenario_json> <ready_file> <request_log>

Scenario response object fields:
  finish_reason  "stop" | "tool_calls" | "length" | "error"   (default "stop")
  content        assistant message content (default "")
  tool_calls     array of {id, name, arguments}
  model          model name echoed back (default "mock-model")
  usage          {prompt_tokens, completion_tokens, total_tokens}
  status         HTTP status code (default 200)
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log_lock = threading.Lock()


def main():
    port_start = int(sys.argv[1])
    port_end = int(sys.argv[2])
    scenario_file = sys.argv[3]
    ready_file = sys.argv[4]
    request_log = sys.argv[5]

    with open(scenario_file, "r", encoding="utf-8") as f:
        scenario = json.load(f)

    if not isinstance(scenario, list) or not scenario:
        print("mock_llm_server: empty or malformed scenario file", file=sys.stderr)
        sys.exit(1)

    call_count = [0]

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _respond(self):
            length = int(self.headers.get("Content-Length", 0) or 0)
            body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
            call_count[0] += 1

            if request_log:
                line = " ".join(body.split())
                if not line:
                    line = "<empty>"
                with log_lock:
                    with open(request_log, "a", encoding="utf-8") as f:
                        f.write(line + "\n")
                        f.flush()

            idx = min(call_count[0], len(scenario))
            item = scenario[idx - 1]
            status = int(item.get("status", 200))
            finish = item.get("finish_reason", "stop")
            content = item.get("content", "")
            model = item.get("model", "mock-model")
            usage = item.get("usage", {
                "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15
            })

            message = {"role": "assistant"}
            tool_calls = item.get("tool_calls")
            if tool_calls is None:
                message["content"] = content
            else:
                if content:
                    message["content"] = content
                message["tool_calls"] = [
                    {
                        "id": tc["id"],
                        "type": "function",
                        "function": {"name": tc["name"], "arguments": tc["arguments"]},
                    }
                    for tc in tool_calls
                ]

            payload = {
                "id": "chatcmpl-mock-%d" % idx,
                "object": "chat.completion",
                "created": 0,
                "model": model,
                "choices": [
                    {"index": 0, "message": message, "finish_reason": finish}
                ],
                "usage": usage,
            }
            data = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            data = b"OK"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            self._respond()

    server = None
    for p in range(port_start, port_end + 1):
        try:
            server = ThreadingHTTPServer(("127.0.0.1", p), Handler)
            break
        except OSError:
            server = None

    if server is None:
        print("mock_llm_server: no free port in range %d-%d" % (port_start, port_end),
              file=sys.stderr)
        sys.exit(1)

    with open(ready_file, "w") as f:
        f.write(str(server.server_port))

    server.serve_forever()


if __name__ == "__main__":
    main()
