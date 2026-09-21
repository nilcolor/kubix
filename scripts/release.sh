#!/usr/bin/env bash
# The configuration that ships: Release compiles out the DEBUG drivers, so it can break while every
# Debug check passes. Signature and entitlements are reported because they are what notarization
# turns on, and the drivers' absence is asserted because shipping one would be a leak.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/generate.sh
xcodebuild -project kubix.xcodeproj -scheme kubix -configuration Release \
  -derivedDataPath build/DerivedData build
app="$PWD/build/DerivedData/Build/Products/Release/kubix.app"
binary="$app/Contents/MacOS/kubix"
[ -x "$binary" ] || { echo "FAIL: no Release binary at $binary" >&2; exit 1; }

/usr/bin/codesign --verify --strict --verbose=2 "$app"
echo
/usr/bin/codesign -dvvv "$app" 2>&1 | grep -E "^(Identifier|Signature|TeamIdentifier|CodeDirectory)" | sed 's/^/  /'
/usr/bin/codesign -d --entitlements :- "$app" 2>/dev/null | grep -E "<key>" | sed 's/^/  entitlement /'
# Notarization readiness is reported, never enforced: there is no Developer ID yet, and this target
# has to keep passing until there is.
if /usr/bin/codesign -dvvv "$app" 2>&1 | grep -q "Signature=adhoc"; then
    echo "  not notarizable yet: ad-hoc signature, no team. Needs a Developer ID Application"
    echo "  identity, --timestamp, and xcrun notarytool. Not a failure."
fi
if /usr/bin/codesign -d --entitlements :- "$app" 2>/dev/null | grep -q "get-task-allow"; then
    echo "FAIL: get-task-allow is in the Release entitlements; notarization would refuse it" >&2
    exit 1
fi
echo
for marker in KUBIX_POD_UI_SMOKE_DIRECTORY KUBIX_KEYCHAIN_PROBE_DIRECTORY KUBIX_EXEC_VALIDATION_CONFIRM; do
    if strings "$binary" | grep -q "$marker"; then
        echo "FAIL: $marker is in the Release binary; a DEBUG driver is being shipped" >&2
        exit 1
    fi
done
echo "  no DEBUG driver markers in the Release binary"
echo
echo "Release app: $app ($(du -sh "$app" | cut -f1))"
