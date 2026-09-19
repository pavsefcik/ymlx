"""Minimal OpenAI-compatible SSE mock used by the REPL integration test."""

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RECORDED = []


def _stream_for(model):
    """Yield delta dicts mimicking each family's stream shape."""
    if "Qwen" in model:
        yield {"reasoning_content": "let me "}
        yield {"reasoning_content": "think."}
        yield {"content": "Hello from Qwen"}
    elif "gemma" in model:
        yield {"content": "<|channel>thought\nweigh"}
        yield {"content": "ing\n<channel|>"}
        yield {"content": "Hello from Gemma"}
    else:  # Ministral-style inline bracket
        yield {"content": "[THI"}
        yield {"content": "NK]weigh"}
        yield {"content": "ing[/THINK]"}
        yield {"content": "Hello from Ministral"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # silence
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        RECORDED.append(body)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        for delta in _stream_for(body.get("model", "")):
            chunk = {"choices": [{"delta": delta}]}
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def start():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server
