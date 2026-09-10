#!/usr/bin/env bash
# Run after make prep; intentionally separate from host-free SwiftPM tests.
set -euo pipefail
cd "$(dirname "$0")/.."

artifacts=(GhosttyKit.xcframework kubix/Resources/ghostty kubix/Resources/terminfo)
for artifact in "${artifacts[@]}"; do
  if [[ ! -d "$artifact" ]]; then
    echo "Missing $artifact; run make prep first" >&2
    exit 1
  fi
done

snapshot() {
  # Content and mtime checks catch both rewrites and replacement with identical files.
  find "${artifacts[@]}" -type f -exec stat -f '%N %m %z' {} \; \
    -exec shasum -a 256 {} \; | LC_ALL=C sort | shasum -a 256
}

before="$(snapshot)"
SECONDS=0
output="$(./scripts/setup.sh)"
elapsed="$SECONDS"
printf '%s\n' "$output"
[[ "$output" == *"setup skipped"* ]] || {
  echo "Setup did not take its present-check fast path" >&2
  exit 1
}
[[ "$elapsed" -lt 5 ]] || {
  echo "Cached setup took ${elapsed}s (expected <5s)" >&2
  exit 1
}
[[ "$before" == "$(snapshot)" ]] || {
  echo "Cached setup changed generated artifacts" >&2
  exit 1
}
echo "Setup idempotence passed: no artifact changes; cached invocation took ${elapsed}s"
