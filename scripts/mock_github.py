#!/usr/bin/env python3
"""Tiny stand-in for the GitHub endpoints the bug-report chat uses (tests only).
   python3 scripts/mock_github.py <port> <login>"""
import json
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, USER = int(sys.argv[1]), sys.argv[2]
CONFIG = "reporters:\n  - Melf11\n  - freund-a\nautofix:\n  - Melf11\nmax_fixes_per_night: 3\n"
ISSUES = [{"number": 1, "title": "Spline lässt sich nicht trimmen", "body": "Trimmen geht bei Splines nicht", "state": "open",
           "labels": [{"name": "fehler"}], "user": {"login": "someone"}, "html_url": "http://localhost/issues/1"}]
COMMENTS = {1: []}
polls = {"n": 0}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, obj, status=200, raw=False):
        data = obj.encode() if raw else json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain" if raw else "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode()
        try:
            return json.loads(raw)
        except Exception:
            return dict(urllib.parse.parse_qsl(raw))

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        b = self.body()
        if u.path == "/login/device/code":
            return self.send({"device_code": "dc", "user_code": "ABCD-1234", "verification_uri": f"http://localhost:{PORT}/login/device",
                              "interval": 1, "expires_in": 60})
        if u.path == "/login/oauth/access_token":
            polls["n"] += 1
            return self.send({"error": "authorization_pending"} if polls["n"] < 2 else {"access_token": "tok-" + USER, "token_type": "bearer"})
        if u.path == "/repos/Melf11/6axis/issues":
            n = len(ISSUES) + 1
            issue = {"number": n, "title": b["title"], "body": b["body"], "state": "open", "labels": [],
                     "user": {"login": USER}, "html_url": f"http://localhost/issues/{n}"}
            ISSUES.append(issue)
            # The triage workflow would answer like this:
            COMMENTS[n] = [{"id": n * 100, "user": {"login": "github-actions[bot]"}, "body": "**Schritte** … – Rückfrage: Welche Version?",
                            "created_at": "2026-10-14T10:00:00Z"}]
            return self.send(issue, 201)
        if u.path.startswith("/repos/Melf11/6axis/issues/") and u.path.endswith("/comments"):
            n = int(u.path.split("/")[5])
            c = {"id": n * 100 + len(COMMENTS.get(n, [])) + 1, "user": {"login": USER}, "body": b["body"], "created_at": "2026-10-14T10:05:00Z"}
            COMMENTS.setdefault(n, []).append(c)
            return self.send(c, 201)
        self.send({"message": "not found"}, 404)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        if self.headers.get("Authorization") != "Bearer tok-" + USER:
            return self.send({"message": "Bad credentials"}, 401)
        if u.path == "/user":
            return self.send({"login": USER})
        if u.path == "/repos/Melf11/6axis/contents/.github/bug-automation.yml":
            return self.send(CONFIG, raw=True)
        if u.path == "/search/issues":
            words = [w.lower() for w in q.get("q", "").split() if ":" not in w]
            return self.send({"items": [i for i in ISSUES if any(w in i["title"].lower() for w in words)]})
        if u.path == "/repos/Melf11/6axis/issues":
            return self.send([i for i in ISSUES if i["user"]["login"] == q.get("creator")][::-1])
        if u.path.startswith("/repos/Melf11/6axis/issues/") and u.path.endswith("/comments"):
            return self.send(COMMENTS.get(int(u.path.split("/")[5]), []))
        self.send({"message": "not found"}, 404)


HTTPServer(("127.0.0.1", PORT), H).serve_forever()
