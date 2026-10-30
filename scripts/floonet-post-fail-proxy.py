#!/usr/bin/env python3
"""Прокси к floonet-ноде, который валит первые broadcast-запросы.

Нужен для живого UI-теста repost: приложение подписывает транзакцию и сохраняет
Slate, но публикация (`push_transaction`) получает настоящую ошибку от «ноды».
После этого UI повторяет публикацию без новой подписи — прокси пропускает её.

Использование:
    python3 scripts/floonet-post-fail-proxy.py \
        --listen 13414 --target http://127.0.0.1:13413 --fail-broadcasts 1

Снаружи это обычный JSON-RPC прокси: путь, заголовки и тело forwardятся как есть.
"""

import argparse
import json
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib import error, request


class State:
    def __init__(self, fail_broadcasts):
        self.lock = threading.Lock()
        self.remaining = fail_broadcasts
        self.failed = 0


def make_handler(target, state):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            sys.stderr.write((fmt % args) + "\n")
            sys.stderr.flush()

        def _read_body(self):
            length = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(length) if length else b""

        @staticmethod
        def _method(body):
            if not body:
                return None
            try:
                data = json.loads(body.decode("utf-8"))
            except Exception:
                return None
            return data.get("method") if isinstance(data, dict) else None

        def _forward(self, body):
            req = request.Request(target + self.path, data=body, method=self.command)
            for key, value in self.headers.items():
                if key.lower() in ("host", "content-length", "connection"):
                    continue
                req.add_header(key, value)
            if body:
                req.add_header("Content-Length", str(len(body)))
            try:
                with request.urlopen(req, timeout=30) as response:
                    return response.status, response.headers.get("Content-Type", "application/json"), response.read()
            except error.HTTPError as exc:
                return exc.code, exc.headers.get("Content-Type", "application/json"), exc.read()

        def _respond(self, status, content_type, payload):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if payload:
                self.wfile.write(payload)

        def _handle(self):
            body = self._read_body()
            if self._method(body) == "push_transaction":
                with state.lock:
                    fail = state.remaining > 0
                    if fail:
                        state.remaining -= 1
                        state.failed += 1
                if fail:
                    self.log_message("push_transaction -> 500 (тестовый сбой публикации)")
                    payload = json.dumps(
                        {
                            "jsonrpc": "2.0",
                            "id": None,
                            "error": {"code": -32000, "message": "post failed (UI test)"},
                        }
                    ).encode("utf-8")
                    self._respond(500, "application/json", payload)
                    return
            try:
                status, content_type, payload = self._forward(body)
            except Exception as exc:  # сеть до ноды недоступна
                self.log_message("forward error: %s", exc)
                self._respond(502, "text/plain", str(exc).encode("utf-8"))
                return
            self._respond(status, content_type, payload)

        do_POST = _handle
        do_GET = _handle

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", type=int, default=13414)
    parser.add_argument("--target", default="http://127.0.0.1:13413")
    parser.add_argument("--fail-broadcasts", type=int, default=1)
    args = parser.parse_args()

    state = State(args.fail_broadcasts)
    server = ThreadingHTTPServer(
        ("127.0.0.1", args.listen), make_handler(args.target.rstrip("/"), state)
    )
    server.daemon_threads = True

    def stop(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    print(
        f"proxy 127.0.0.1:{args.listen} -> {args.target}, "
        f"fail first {args.fail_broadcasts} push_transaction",
        flush=True,
    )
    server.serve_forever()
    print("proxy stopped", flush=True)


if __name__ == "__main__":
    main()
