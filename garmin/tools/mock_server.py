"""Mock of the worklog brief API for the Connect IQ simulator.

    python garmin/tools/mock_server.py [--fail 401|500|slow] [--delay 130] [--port 8503]

Serves GET /api/status and POST /api/start, /api/pause, /api/stop (with ?brief=1) on
127.0.0.1, keeping the timer state in memory. Any Basic login is accepted. --fail makes every
reply fail: 401, 500, or "slow" (each reply waits --delay seconds, default 130, so the
request times out on the phone or in the simulator).
In the simulator, switch off the HTTPS check and set serverUrl to http://127.0.0.1:8503.
"""
import argparse
import json
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {"state": "stopped", "since": None, "started": None, "type": None, "project": None,
         "work_s": 0.0, "resume": None}
FAIL = None
DELAY = 130


def brief() -> dict:
    now = time.time()
    running = now - STATE["started"] if STATE["started"] else None
    work = STATE["work_s"] + (running if STATE["state"] == "working" else 0)
    return {"state": STATE["state"], "date": datetime.now().date().isoformat(), "since": STATE["since"],
            "elapsed_s": int(running) if running is not None else None,
            "type": STATE["type"], "project": STATE["project"],
            "today_work_h": round(work / 3600, 2), "resume": STATE["resume"]}


def close_block():
    if STATE["state"] == "working" and STATE["started"]:
        STATE["work_s"] += time.time() - STATE["started"]
        STATE["resume"] = {"type": STATE["type"], "project": STATE["project"]}


def open_block(state, type_, project):
    STATE.update(state=state, started=time.time(), since=datetime.now().strftime("%H:%M"),
                 type=type_, project=project)


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def guard(self) -> bool:
        if FAIL == "slow":
            time.sleep(DELAY)
        if FAIL == "401" or not self.headers.get("Authorization", "").startswith("Basic "):
            self.reply(401, {"error": "login required"})
            return False
        if FAIL == "500":
            self.reply(500, {"error": "internal error"})
            return False
        return True

    def do_GET(self):
        if not self.guard():
            return
        if self.path.split("?")[0] == "/api/status":
            self.reply(200, brief())
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if not self.guard():
            return
        try:
            body = json.loads(raw or b"{}") or {}
        except ValueError:
            body = {}
        route = self.path.split("?")[0]
        if route == "/api/start":
            close_block()
            open_block("working", body.get("type") or "dev", body.get("project"))
        elif route == "/api/pause":
            if STATE["state"] == "working":
                close_block()
                open_block("break", body.get("type") or "eat", None)
        elif route == "/api/stop":
            close_block()
            STATE.update(state="stopped", started=None, since=None, type=None, project=None)
        else:
            self.reply(404, {"error": "not found"})
            return
        print(f"{route} {body} -> {STATE['state']} {STATE['type']} {STATE['project']}")
        self.reply(200, brief())


def main():
    global FAIL, DELAY
    p = argparse.ArgumentParser()
    p.add_argument("--fail", choices=["401", "500", "slow"])
    p.add_argument("--delay", type=int, default=130, help="seconds a slow reply waits")
    p.add_argument("--port", type=int, default=8503)
    p.add_argument("--project", default="acme", help="project of the first start's resume")
    a = p.parse_args()
    FAIL = a.fail
    DELAY = a.delay
    STATE["resume"] = {"type": "dev", "project": a.project}
    print(f"mock worklog on http://127.0.0.1:{a.port} (fail={FAIL})")
    ThreadingHTTPServer(("127.0.0.1", a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
