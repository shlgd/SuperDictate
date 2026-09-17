"""Loopback-only HTTP failures for Swift downloader regression tests."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/hang":
            time.sleep(30)
            return
        if self.path == "/error":
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        payload = b"download fixture" * 4096
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            if self.path == "/partial":
                self.wfile.write(payload[:10])
                self.close_connection = True
            else:
                self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
