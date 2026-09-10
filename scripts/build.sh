#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/generate.sh
xcodebuild -project kubix.xcodeproj -scheme kubix -configuration Debug \
  -derivedDataPath build/DerivedData build
