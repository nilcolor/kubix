#!/bin/bash
# Fixed native synthetic validation; no Accessibility permission or live cluster/auth configuration.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/DerivedData/Build/Products/Debug/kubix.app/Contents/MacOS/kubix"
if [ ! -x "$app" ]; then
    echo "Build the Debug app with make build first." >&2
    exit 1
fi
root="$PWD/.build/validation/pod-ui-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$root/home" "$root/tmp"
echo "Synthetic native evidence: $root"
python3 - "$app" "$root" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

app, root = sys.argv[1:]
env = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME": root + "/home",
    "TMPDIR": root + "/tmp",
    "SHELL": "/bin/sh",
    "ZDOTDIR": root + "/home",
    "KUBIX_POD_UI_SMOKE_DIRECTORY": root,
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
        sys.exit("FAIL: native app timed out; owned PID stopped")
result = Path(root, "result.json")
if not result.exists():
    sys.exit("FAIL: no native result; see synthetic app.log")
report = json.loads(result.read_text())
print(json.dumps(report, indent=2, sort_keys=True))
if report.get("result") != "passed" or child.returncode != 0:
    sys.exit(1)
print("PASS: native pod UI; synthetic only; owned app exited")
PY
