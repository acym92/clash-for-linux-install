#!/usr/bin/env python3
"""Tiny LAN-only subscription server for the generated client configuration."""

import argparse
import ipaddress
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--file", type=Path, required=True)
    parser.add_argument("--cidr", required=True)
    args = parser.parse_args()

    expected = f"/sub/{args.token_file.read_text(encoding='utf-8').strip()}"
    allowed_network = ipaddress.ip_network(args.cidr, strict=False)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            try:
                allowed = ipaddress.ip_address(self.client_address[0]) in allowed_network
            except ValueError:
                allowed = False
            if not allowed:
                self.send_error(403)
                return
            if self.path.split("?", 1)[0] != expected:
                self.send_error(404)
                return
            try:
                body = args.file.read_bytes()
            except OSError:
                self.send_error(503)
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/yaml; charset=utf-8")
            self.send_header("Content-Disposition", 'attachment; filename="lan-ha.yaml"')
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *values):
            # Do not log paths because they contain the bearer token.
            print(f"{self.client_address[0]} {values[1]}", flush=True)

    ThreadingHTTPServer((args.bind, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
