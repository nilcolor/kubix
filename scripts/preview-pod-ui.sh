#!/bin/bash
# Opt-in synthetic layout preview: the same closed fixture the native smoke uses, left on screen.
# Not a cluster validation and not an automation interface; no live config, auth or network.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/DerivedData/Build/Products/Debug/kubix.app/Contents/MacOS/kubix"
if [ ! -x "$app" ]; then
    echo "Build the Debug app with make build first." >&2
    exit 1
fi
root="$PWD/.build/validation/pod-ui-preview-$$"
mkdir -p "$root/home" "$root/tmp"
env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$root/home" TMPDIR="$root/tmp" \
    SHELL=/bin/sh ZDOTDIR="$root/home" \
    KUBIX_POD_UI_SMOKE_DIRECTORY="$root" KUBIX_POD_UI_PREVIEW=1 \
    "$app" >"$root/app.log" 2>&1 &
pid=$!
echo "Preview PID: $pid"
for _ in $(seq 1 100); do
    if grep -q "PREVIEW window rect" "$root/app.log" 2>/dev/null; then break; fi
    sleep 0.2
done
grep "PREVIEW window rect" "$root/app.log" || echo "no window rect; see $root/app.log"
