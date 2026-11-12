#!/usr/bin/env python3
"""After scripts/build.sh, check the production model without SSH or real preferences."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import pathlib
import platform
import plistlib
import shutil
import subprocess
import tempfile
import threading
import uuid


class NamingHandler(BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *args):
        pass

    def do_POST(self):
        assert self.path == "/v1/chat/completions"
        assert self.headers.get("Authorization") == "Bearer fixture"
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert body["model"] == "fixture"
        assert body["messages"][1]["content"] == "Fix the login redirect loop in the sample app"
        assert "tools" not in body
        self.requests.append(body)
        response = json.dumps({"choices": [{"message": {"content": "修复登录跳转"}, "finish_reason": "stop"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)


@contextmanager
def naming_service():
    server = ThreadingHTTPServer(("127.0.0.1", 0), NamingHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(subprocess.check_output(
    ["swift", "build", "--build-system", "native", "-c", "release", "--show-bin-path"], cwd=ROOT, text=True).strip())
DOMAIN = "dev.agentworkbench.namingqa." + uuid.uuid4().hex
includes = ["-I", str(BIN / "Modules")]
for path in ["swift-markdown/Sources/CAtomic/include", "swift-cmark/src/include", "swift-cmark/extensions/include"]:
    includes += ["-I", str(ROOT / ".build/checkouts" / path)]
ghostty = ROOT / ".build/artifacts/libghostty-spm/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64"
includes += ["-I", str(ghostty / "Headers")]
objects = []
for target in ["WorkbenchCore", "Markdown", "CAtomic", "cmark_gfm", "cmark_gfm_extensions",
               "GhosttyTerminal", "GhosttyKit", "MSDisplayLink", "SwiftMath"]:
    objects += sorted((BIN / (target + ".build")).glob("*.o"))
sources = sorted(path for path in (ROOT / "Sources/AgentWorkbench").glob("*.swift")
                 if path.name != "WorkbenchApp.swift")

with naming_service() as server, tempfile.TemporaryDirectory(prefix="perch-naming-check-", dir=ROOT / ".build") as folder:
    work = pathlib.Path(folder)
    app = work / "NamingLifecycleChecks.app"
    executable = app / "Contents/MacOS/NamingLifecycleChecks"
    executable.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": DOMAIN, "CFBundleName": "Naming Lifecycle Checks",
        "CFBundleExecutable": executable.name, "CFBundlePackageType": "APPL", "LSUIElement": True,
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    }))
    compiled = work / "compiled"
    subprocess.run([
        "swiftc", "-j", str(os.cpu_count() or 4), "-Onone", "-swift-version", "5", "-parse-as-library",
        "-target", platform.machine() + "-apple-macosx26.0", *includes,
        *map(str, sources), str(ROOT / "Tests/NamingLifecycleChecks/App.swift"),
        *map(str, objects), str(ghostty / "libghostty.a"), "-lc++",
        "-framework", "Carbon", "-framework", "Metal", "-framework", "QuartzCore",
        "-o", str(compiled),
    ], cwd=ROOT, check=True)
    # Stage a fresh executable inode before signing the isolated app bundle.
    shutil.copy2(compiled, executable)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    try:
        env = dict(os.environ, PERCH_NAMING_FIXTURE_URL=f"http://localhost:{server.server_port}/v1")
        subprocess.run([str(executable)], check=True, timeout=30, env=env)
        assert len(NamingHandler.requests) == 1, "The accepted first prompt must make exactly one HTTP naming request"
    finally:
        subprocess.run(["defaults", "delete", DOMAIN], capture_output=True)
        shutil.rmtree(pathlib.Path.home() / "Library/Application Support" / DOMAIN, ignore_errors=True)
