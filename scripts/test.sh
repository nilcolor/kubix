#!/usr/bin/env bash
# No app host, Ghostty build, cluster, or user credentials.
set -euo pipefail
cd "$(dirname "$0")/.."

swift test --package-path KubixCore "$@"
