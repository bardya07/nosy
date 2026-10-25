"""Focused local HTTP fixture: Range support, ignored Range, slow transfer, request audit."""
import http.server
import json
import pathlib
import sys
import time

root = pathlib.Path(sys.argv[1])
payload = bytes(range(256)) * 4096
(root / 'payload').write_bytes(payload)

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        requested = self.headers.get('Range', '')
        with (root / 'requests.jsonl').open('a') as log:
            log.write(json.dumps({'path': self.path, 'range': requested}) + '\n')
        start = int(requested.removeprefix('bytes=').split('-')[0]) if requested else 0
        if self.path == '/ignore':
            start = 0
        self.send_response(206 if start else 200)
        self.send_header('Content-Length', str(len(payload) - start))
        if start:
            self.send_header('Content-Range', f'bytes {start}-{len(payload)-1}/{len(payload)}')
        self.end_headers()
        try:
            for offset in range(start, len(payload), 8192):
                self.wfile.write(payload[offset:offset+8192])
                self.wfile.flush()
                time.sleep(0.012)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
