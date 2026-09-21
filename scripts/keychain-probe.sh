#!/bin/bash
# Opt-in synthetic probe for the client-certificate finding in ARCHITECTURE.md, whose answers depend
# on how the app is signed. No real credential material: the PKCS#12 is generated here and deleted,
# and the app removes whatever it managed to store. Pass a signing identity to probe under one:
#   scripts/keychain-probe.sh                       # as built (ad-hoc)
#   scripts/keychain-probe.sh <TEAMID>              # signed with your Apple Development identity
set -euo pipefail
cd "$(dirname "$0")/.."
team="${1:-}"
app="$PWD/build/DerivedData/Build/Products/Debug/kubix.app"
if [ -n "$team" ]; then
    echo "Building signed with team $team (Xcode must be signed in to that Apple ID)…"
    xcodebuild -project kubix.xcodeproj -scheme kubix -configuration Debug \
        -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' \
        CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$team" CODE_SIGN_IDENTITY="Apple Development" \
        KUBIX_SKIP_ADHOC_SIGN=1 -allowProvisioningUpdates build >/dev/null
fi
if [ ! -x "$app/Contents/MacOS/kubix" ]; then
    echo "Build the Debug app with make build first." >&2
    exit 1
fi
root="$PWD/.build/validation/keychain-probe-$$"
mkdir -p "$root/home" "$root/tmp"
trap 'rm -rf "$root"' EXIT
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -subj "/CN=kubix-probe" -keyout "$root/key.pem" -out "$root/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$root/key.pem" -in "$root/cert.pem" -name kubix-probe \
    -passout pass:probe -out "$root/probe.p12" 2>/dev/null
echo "Signature of the bundle being probed:"
codesign -dvvv "$app" 2>&1 | grep -E "Signature=|TeamIdentifier=" | sed 's/^/  /'
env -i PATH=/usr/bin:/bin HOME="$root/home" TMPDIR="$root/tmp" \
    KUBIX_KEYCHAIN_PROBE_DIRECTORY="$root" "$app/Contents/MacOS/kubix" >"$root/app.log" 2>&1 || true
if [ ! -f "$root/result.json" ]; then
    echo "FAIL: no probe result; see $root/app.log" >&2
    tail -5 "$root/app.log" >&2
    exit 1
fi
python3 - "$root/result.json" <<'PY'
import json, sys
results = json.load(open(sys.argv[1]))
print("\n%-44s %s" % ("call", "result"))
print("-" * 92)
for key in ["signature", "generate key in memory", "add private key, default keychain",
            "add private key, data protection keychain", "generate key directly into the keychain",
            "import PKCS#12 to memory only", "import PKCS#12 to the keychain"]:
    if key in results:
        print("%-44s %s" % (key, results[key]))
PY
