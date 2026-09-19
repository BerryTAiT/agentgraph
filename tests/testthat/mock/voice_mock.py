#!/usr/bin/env python3
"""agentgraph voice mock server (test harness only).

Serves a minimal STT (Whisper-style) and TTS (ElevenLabs-style) endpoint so the
R-side transcribe()/synthesize() can be exercised offline:

  POST /audio/transcriptions   -> {"text":"hello from stt"}
  POST /text-to-speech/<voice> -> raw b"FAKE_AUDIO_MP3" (audio/mpeg)

Usage: python voice_mock.py <port_start> <port_end> <ready_file> <request_log>
"""
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log_lock = threading.Lock()


class SingleBindServer(ThreadingHTTPServer):
    allow_reuse_address = False


def main():
    port_start = int(sys.argv[1])
    port_end = int(sys.argv[2])
    ready_file = sys.argv[3]
    request_log = sys.argv[4]

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _log(self, body):
            if not request_log:
                return
            with log_lock:
                with open(request_log, "a", encoding="utf-8") as f:
                    f.write(body + "\n")
                    f.flush()

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0) or 0)
            body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
            self._log(self.path + " " + body)

            if "/audio/transcriptions" in self.path:
                data = b'{"text":"hello from stt"}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
            elif "/text-to-speech" in self.path:
                data = b"FAKE_AUDIO_MP3"
                self.send_response(200)
                self.send_header("Content-Type", "audio/mpeg")
            else:
                data = b'{"error":"not found"}'
                self.send_response(404)
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
        print("voice_mock: no free port in range", file=sys.stderr)
        sys.exit(1)

    with open(ready_file, "w") as f:
        f.write(str(server.server_port))

    server.serve_forever()


if __name__ == "__main__":
    main()
