#!/bin/bash
# Native Debug-app integration, separate from host-free make test. No Accessibility automation.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/DerivedData/Build/Products/Debug/kubix.app/Contents/MacOS/kubix"
if [ ! -x "$app" ]; then
    echo "Build the Debug app with make build first." >&2
    exit 1
fi
root="$PWD/.build/validation/terminal-smoke-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$root/home" "$root/tmp"
echo "Terminal smoke evidence: $root"
python3 - "$app" "$root" "$PWD/scripts/fixtures/terminal-smoke" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

app, root, startup = sys.argv[1:]
env = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME": root + "/home",
    "TMPDIR": root + "/tmp",
    "SHELL": "/bin/zsh",
    "ZDOTDIR": startup,
    "KUBIX_TERMINAL_SMOKE_DIRECTORY": root,
    "KUBIX_TERMINAL_SMOKE_STARTUP": startup,
}
with open(root + "/app.log", "wb") as log:
    child = subprocess.Popen([app], env=env, stdout=log, stderr=log)
    print("Owned app PID:", child.pid, flush=True)
    try:
        child.wait(timeout=90)
    except subprocess.TimeoutExpired:
        child.terminate()
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=10)
        sys.exit("FAIL: app timed out; owned PID stopped")
result = Path(root, "result.json")
if not result.exists():
    sys.exit("FAIL: no native smoke result; see app.log")
report = json.loads(result.read_text())
print(json.dumps(report, indent=2, sort_keys=True))
if report.get("result") != "passed" or child.returncode != 0:
    sys.exit(1)
print("PASS: native terminal rendering/input/resize/teardown; owned app exited")
PY
