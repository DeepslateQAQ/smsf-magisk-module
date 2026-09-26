#!/usr/bin/env python3
"""Tiny webhook sink used by the payload tests.

Captures every request as one JSON line in --log and answers 200 "ok" unless the
path encodes a different behaviour:

  /status/<code>   always answer <code>
  /flaky/<n>       answer 500 for the first <n> requests for that path, then 200
  /match/<text>    answer 200 with body containing <text>
"""
import argparse
import http.server
import json
import re
import socketserver
import sys
import threading

COUNTS = {}
LOCK = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _handle(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        record = {
            "method": self.command,
            "path": self.path,
            "headers": {k: v for k, v in self.headers.items()},
            "body": body.decode("utf-8", "replace"),
        }
        if not self.path.startswith("/ping"):
            with LOCK:
                with open(self.server.log_path, "a", encoding="utf-8") as fh:
                    fh.write(json.dumps(record) + "\n")

        if self.path.startswith("/chunked"):
            payload = b"chunked-ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"%x\r\n%s\r\n0\r\n\r\n" % (len(payload), payload))
            return
        if self.path.startswith("/close/"):
            # no Content-Length anywhere: the client has to read until EOF
            payload = self.path[len("/close/"):].encode() or b"close-ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
            self.close_connection = True
            return
        if self.path.startswith("/redir307-localhost"):
            self.send_response(307)
            self.send_header("Location", "http://localhost:%d/final" % self.server.server_address[1])
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if re.match(r"^/redir/\d+", self.path):
            self.send_response(302)
            self.send_header("Location", "/final")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        code = 200
        payload = b"ok"
        m = re.match(r"^/status/(\d+)", self.path)
        if m:
            code = int(m.group(1))
            payload = ("status-%d" % code).encode()
        m = re.match(r"^/flaky/(\d+)", self.path)
        if m:
            n = int(m.group(1))
            with LOCK:
                seen = COUNTS.get(self.path, 0) + 1
                COUNTS[self.path] = seen
            if seen <= n:
                code = 500
                payload = b"boom"
            else:
                payload = b"ok"
        m = re.match(r"^/match/(.+)$", self.path)
        if m:
            payload = m.group(1).encode()

        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _handle

    def log_message(self, fmt, *args):  # keep the test output quiet
        sys.stderr.write("mock: " + (fmt % args) + "\n")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18733)
    ap.add_argument("--log", default="/tmp/smsfw-requests.jsonl")
    ap.add_argument("--cert", default="")
    ap.add_argument("--key", default="")
    args = ap.parse_args()
    srv = Server(("127.0.0.1", args.port), Handler)
    if args.cert and args.key:
        import ssl
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.cert, args.key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.log_path = args.log
    print("listening on %d" % args.port, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
