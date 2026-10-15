"""Minimal mock of the MKE API endpoints read by swarm-core-audit.sh, served on a unix socket.

Serves a fixture directory (info.json, version.json, nodes.json, services.json) at
/var/run/docker.sock, so the audit image can be tested against MKE-style responses
(tests/fixtures/mock-mke) or a plain MCR engine without MKE (tests/fixtures/mock-windows).
"""
import json
import os
import socketserver
from http.server import BaseHTTPRequestHandler

FIXTURES = os.environ.get("FIXTURES", "/fixtures")
SOCKET = "/var/run/docker.sock"


def load(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        return json.load(f)


ROUTES = {
    "/_ping": "OK",
    "/info": load("info.json"),
    "/version": load("version.json"),
    "/nodes": load("nodes.json"),
    "/services": load("services.json"),
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = ROUTES.get(self.path.split("?")[0])
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def address_string(self):
        return "mock"

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    pass


if os.path.exists(SOCKET):
    os.remove(SOCKET)
Server(SOCKET, Handler).serve_forever()
