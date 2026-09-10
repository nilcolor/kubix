#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh
open build/DerivedData/Build/Products/Debug/kubix.app
