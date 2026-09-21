#!/bin/bash
# Opt-in synthetic probe for the client-certificate finding in ARCHITECTURE.md, whose answers depend
# on how the app is signed. No real credential material: the PKCS#12 is generated here and deleted,
# and the app removes whatever it managed to store. Pass a signing identity to probe under one:
#   scripts/keychain-probe.sh                       # as built (ad-hoc)
#   scripts/keychain-probe.sh <TEAMID>              # signed with your Apple Development identity
#   scripts/keychain-probe.sh "" --real-home        # against the real login keychain
# With --real-home the probe adds a synthetic EC key to the login keychain and deletes it again; it
# is killed after 60s in case a keychain prompt blocks it.
set -euo pipefail
cd "$(dirname "$0")/.."
team="${1:-}"
home_mode="${2:-isolated}"
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
# A local TLS server that demands a client certificate, so the identity is answered to something
# real. Self-signed on both sides, synthetic, and gone with the temp directory.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -subj "/CN=localhost" -keyout "$root/server.key" -out "$root/server.pem" 2>/dev/null
port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
openssl s_server -accept "$port" -cert "$root/server.pem" -key "$root/server.key" \
    -CAfile "$root/cert.pem" -Verify 1 -www -quiet >"$root/server.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null; rm -rf "$root"' EXIT
for _ in $(seq 1 50); do
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then break; fi
    sleep 0.1
done

# A container with no encryption and no MAC: if Security accepts this, an in-memory writer needs
# ASN.1 only, with no crypto of its own.
openssl pkcs12 -export -inkey "$root/key.pem" -in "$root/cert.pem" -name kubix-probe \
    -keypbe NONE -certpbe NONE -nomac -passout pass: -out "$root/plain.p12" 2>/dev/null || true

echo "Signature of the bundle being probed:"
codesign -dvvv "$app" 2>&1 | grep -E "Signature=|TeamIdentifier=" | sed 's/^/  /'
probe_home="$root/home"
if [ "$home_mode" = "--real-home" ]; then probe_home="$HOME"; fi
env -i PATH=/usr/bin:/bin HOME="$probe_home" TMPDIR="$root/tmp" \
    KUBIX_KEYCHAIN_PROBE_DIRECTORY="$root" KUBIX_KEYCHAIN_PROBE_URL="https://localhost:$port/" \
    "$app/Contents/MacOS/kubix" >"$root/app.log" 2>&1 &
probe_pid=$!
( sleep 60; kill "$probe_pid" 2>/dev/null ) &
killer=$!
wait "$probe_pid" 2>/dev/null || true
kill "$killer" 2>/dev/null || true
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
            "import PKCS#12 to memory only", "import PKCS#12 to the keychain",
            "import unencrypted, MAC-less PKCS#12",
            "client-certificate handshake, identity offered",
            "client-certificate handshake, identity withheld"]:
    if key in results:
        print("%-44s %s" % (key, results[key]))
PY
