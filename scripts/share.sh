#!/usr/bin/env bash
# --dirty so a build with uncommitted changes can never be named after a clean tag. ditto rather than
# zip, which drops the extended attributes and symlinks the app's signature depends on.
set -euo pipefail
cd "$(dirname "$0")/.."

version="$(git describe --tags --dirty)"
./scripts/release.sh
app="$PWD/build/DerivedData/Build/Products/Release/kubix.app"
archive="$HOME/Downloads/Kubix-$version.zip"
rm -f "$archive"
/usr/bin/ditto -c -k --keepParent "$app" "$archive"
echo
echo "Shared: $archive ($(du -h "$archive" | cut -f1))"
