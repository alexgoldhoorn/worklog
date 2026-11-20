#!/usr/bin/env python
"""Run the Qt Quick tests against a real worklog server on a throwaway database.

    python qt/tests/run_tests.py <build dir with tst_worklog> [-- extra tst_worklog args]

Run it with a Python that has the server's dependencies (`uv run python qt/tests/run_tests.py ...`).
The build: cmake -S qt -B <dir> -DWORKLOG_TESTS=ON && cmake --build <dir> --target tst_worklog
(the Qt bin directory must be on PATH, or next to the DLLs on Windows).
"""
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    # resolved: the test exe is started from its own directory, where a relative path would no longer fit
    build, extra = Path(args[0]).resolve(), (args[args.index("--") + 1:] if "--" in args else [])
    exe = next((p for p in (build / "tests" / "tst_worklog.exe", build / "tests" / "tst_worklog",
                            build / "tst_worklog.exe", build / "tst_worklog") if p.exists()), None)
    if exe is None:
        print(f"no tst_worklog in {build}")
        return 2

    port = free_port()
    with tempfile.TemporaryDirectory(prefix="worklog-qt-test-") as tmp:
        env = dict(os.environ, WORKLOG_ENV_FILE=os.devnull, WORKLOG_DB=str(Path(tmp, "t.db")),
                   TZ="Europe/Amsterdam", PYTHONPATH=str(REPO))
        Path(tmp, "balance").mkdir()   # the Week page reads the balance store
        env.update(BALANCE_DB=str(Path(tmp, "b.db")), BALANCE_STATE_DIR=str(Path(tmp, "balance")))
        Path(tmp, "inbox").mkdir()   # the Day page uploads an Outlook PDF here
        env["WORK_CALENDAR_INBOX"] = str(Path(tmp, "inbox"))
        env["DAY_RULES"] = str(REPO / "day" / "rules.example.json")   # the Find page's planner: the example household only
        for k in ("WORKLOG_AUTH_USER", "WORKLOG_AUTH_PASSWORD_HASH"):
            env.pop(k, None)
        server = subprocess.Popen(
            [sys.executable, "-m", "uvicorn", "worklog.web.app:factory", "--factory",
             "--host", "127.0.0.1", "--port", str(port), "--log-level", "warning"],
            cwd=REPO, env=env)
        try:
            url = f"http://127.0.0.1:{port}"
            for _ in range(100):
                try:
                    urllib.request.urlopen(url + "/healthz", timeout=1).read()
                    break
                except OSError:
                    if server.poll() is not None:
                        print("server exited")
                        return 1
                    time.sleep(0.2)
            else:
                print("server did not start")
                return 1
            test_env = dict(os.environ, WORKLOG_TEST_URL=url, QT_QPA_PLATFORM=os.environ.get("QT_QPA_PLATFORM", "offscreen"))
            # the test exe is a GUI-subsystem program on Windows, so its stdout is lost: write a file
            result = Path(tmp, "result.txt")
            code = subprocess.call([str(exe), "-o", f"{result},txt", *extra], env=test_env, cwd=exe.parent)
            if result.exists():
                lines = result.read_text(encoding="utf-8", errors="replace").splitlines()
                print(chr(10).join(l for l in lines if not l.startswith(("PASS", "QINFO", "QWARN  : tst_worklog::UnknownTestFunc"))))
            return code
        finally:
            server.terminate()
            try:
                server.wait(10)
            except subprocess.TimeoutExpired:
                server.kill()


if __name__ == "__main__":
    sys.exit(main())
