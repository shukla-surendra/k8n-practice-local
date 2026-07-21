import datetime
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOSTNAME = socket.gethostname()


class Handler(BaseHTTPRequestHandler):
    def _log(self, message):
        # stdout, unbuffered by PYTHONUNBUFFERED in the Dockerfile — this is what
        # Promtail tails and Loki stores, same pipeline as sample-nginx.
        ts = datetime.datetime.now(datetime.timezone.utc).isoformat()
        print(f'{ts} pod={HOSTNAME} {message}', flush=True)

    def do_GET(self):
        self._log(f'GET {self.path} from {self.client_address[0]}')
        if self.path == "/health":
            body = b"ok"
        else:
            body = f"hello from {HOSTNAME}\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass  # replaced by _log() above — avoid double logging


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    print(f"local-demo-app listening on :{port}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
