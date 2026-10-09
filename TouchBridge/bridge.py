"""Standard-library WDA client and authenticated, serialized Windows bridge."""
import argparse
import base64
import hmac
import json
import math
import os
import threading
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


class WDAError(RuntimeError):
    pass


class WDA:
    def __init__(self, url, timeout=30):
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            raise ValueError("WDA URL must be http(s)://host:port")
        self.url = url.rstrip("/")
        self.timeout = timeout
        self.session_id = None
        self.lock = threading.Lock()
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(self, method, path, body=None):
        data = None if body is None else json.dumps(body, allow_nan=False).encode()
        request = urllib.request.Request(self.url + path, data=data, method=method,
                                         headers={"Content-Type": "application/json"})
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                payload = json.load(response)
        except (OSError, ValueError) as exc:
            # A timeout can happen AFTER the device taps. Never replay a tap.
            raise WDAError("WDA request failed; execution may be uncertain. No retry was sent.") from exc
        value = payload.get("value")
        if isinstance(value, dict) and value.get("error"):
            raise WDAError(value.get("message", value["error"]))
        if payload.get("status", 0) != 0:
            raise WDAError(str(value))
        return value

    def ensure_session(self):
        if self.session_id is None:
            result = self.request("POST", "/session", {"capabilities": {"alwaysMatch": {}}})
            if not isinstance(result, dict) or not result.get("sessionId"):
                raise WDAError("WDA did not return a session ID")
            self.session_id = urllib.parse.quote(result["sessionId"], safe="")

    @staticmethod
    def number(value, name):
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError(f"{name} must be a finite number")
        return value

    def tap(self, x, y, units="points", image_width=None, image_height=None):
        x, y = self.number(x, "x"), self.number(y, "y")
        with self.lock:
            self.ensure_session()
            size = self.request("GET", f"/session/{self.session_id}/window/size")
            width, height = size["width"], size["height"]
            if units == "normalized":
                if not (0 <= x < 1 and 0 <= y < 1):
                    raise ValueError("Normalized coordinates must be in [0, 1)")
                x, y = x * width, y * height
            elif units == "pixels":
                iw = self.number(image_width, "image_width")
                ih = self.number(image_height, "image_height")
                if iw <= 0 or ih <= 0:
                    raise ValueError("Screenshot dimensions must be positive")
                if abs(iw / ih - width / height) > 0.02:
                    raise ValueError("Screenshot orientation/aspect differs from current screen")
                x, y = x / iw * width, y / ih * height
            elif units != "points":
                raise ValueError("units must be points, pixels or normalized")
            if not (0 <= x < width and 0 <= y < height):
                raise ValueError("Coordinates are outside the current screen")
            self.request("POST", f"/session/{self.session_id}/wda/tap", {"x": x, "y": y})
            return {"ok": True, "x_points": x, "y_points": y,
                    "screen_points": {"width": width, "height": height}}

    def screenshot(self):
        return base64.b64decode(self.request("GET", "/screenshot"), validate=True)


def serve(wda, host, port, token):
    if not token or len(token) < 24:
        raise ValueError("Set TOUCHBRIDGE_TOKEN to at least 24 characters")

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format_string, *args):
            # Do not print request URLs, headers or credentials.
            pass

        def respond(self, status, body):
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def authorized(self):
            supplied = self.headers.get("Authorization", "").encode("utf-8")
            if not hmac.compare_digest(supplied, ("Bearer " + token).encode("utf-8")):
                self.respond(401, {"error": "unauthorized"})
                return False
            return True

        def do_GET(self):
            if not self.authorized():
                return
            if self.path != "/status":
                self.respond(404, {"error": "not_found"})
                return
            try:
                self.respond(200, {"wda": wda.request("GET", "/status")})
            except WDAError as exc:
                self.respond(502, {"error": str(exc)})

        def do_POST(self):
            if not self.authorized():
                return
            if self.path != "/tap":
                self.respond(404, {"error": "not_found"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 4096:
                    raise ValueError("JSON body must be 1..4096 bytes")
                body = json.loads(self.rfile.read(length))
                if not isinstance(body, dict):
                    raise ValueError("JSON body must be an object")
                allowed = {"x", "y", "units", "image_width", "image_height"}
                if set(body) - allowed or not {"x", "y"}.issubset(body):
                    raise ValueError("Provide x and y; unknown fields are not allowed")
                self.respond(200, wda.tap(**body))
            except (ValueError, TypeError) as exc:
                self.respond(400, {"error": str(exc)})
            except WDAError as exc:
                self.respond(502, {"error": str(exc), "retry_safe": False})

    server = HTTPServer((host, port), Handler)
    server.timeout = 15
    print(f"TouchBridge listening on {host}:{port}")
    try:
        server.serve_forever()
    finally:
        server.server_close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wda", required=True, help="e.g. http://192.168.1.50:8100")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    tap = sub.add_parser("tap")
    tap.add_argument("x", type=float)
    tap.add_argument("y", type=float)
    tap.add_argument("--units", choices=["points", "pixels", "normalized"], default="points")
    tap.add_argument("--image-width", type=float)
    tap.add_argument("--image-height", type=float)
    screenshot = sub.add_parser("screenshot")
    screenshot.add_argument("output", type=Path)
    server = sub.add_parser("serve")
    server.add_argument("--host", default="127.0.0.1")
    server.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    wda = WDA(args.wda)
    if args.command == "status":
        print(json.dumps(wda.request("GET", "/status"), ensure_ascii=False, indent=2))
    elif args.command == "tap":
        print(json.dumps(wda.tap(args.x, args.y, args.units, args.image_width, args.image_height)))
    elif args.command == "screenshot":
        args.output.write_bytes(wda.screenshot())
        print(f"Saved {args.output}")
    else:
        serve(wda, args.host, args.port, os.environ.get("TOUCHBRIDGE_TOKEN"))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, WDAError) as exc:
        raise SystemExit(str(exc))
