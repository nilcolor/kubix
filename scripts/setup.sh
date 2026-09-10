#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

GHOSTTY_REPO="https://github.com/ghostty-org/ghostty"
# agterm's verified pre-renderer-regression pin: later revisions blanked scrollback on font zoom.
# Upgrade deliberately and re-test rendering when Kubix has terminal surfaces.
GHOSTTY_REV="4dcb09ada0c0909717d92547623b26eafa50ca8a"
ZIG_FORMULA="zig@0.15"
FRAMEWORK="GhosttyKit.xcframework"
RESOURCES="kubix/Resources"

has_files() {
  [[ -d "$1" && -n "$(find "$1" -type f -print -quit)" ]]
}

if [[ -f "$FRAMEWORK/Info.plist" && -f "$FRAMEWORK/.kubix-revision" ]] &&
  [[ -s "$FRAMEWORK/macos-$(uname -m)/libghostty-internal-fat.a" ]] &&
  [[ "$(cat "$FRAMEWORK/.kubix-revision")" == "$GHOSTTY_REV" ]] &&
  has_files "$RESOURCES/ghostty/themes" &&
  has_files "$RESOURCES/ghostty/shell-integration" &&
  [[ -s "$RESOURCES/terminfo/78/xterm-ghostty" || -s "$RESOURCES/terminfo/x/xterm-ghostty" ]] &&
  [[ -f "$RESOURCES/ghostty/LICENSE" ]]; then
  echo "GhosttyKit and resources already present ($GHOSTTY_REV); setup skipped"
  exit 0
fi

mkdir -p .build/tmp .build/ghostty
export TMPDIR="$ROOT/.build/tmp"
export ZIG_GLOBAL_CACHE_DIR="$ROOT/.build/ghostty/cache"
export HOMEBREW_CACHE="$ROOT/.build/homebrew/cache"
export HOMEBREW_LOGS="$ROOT/.build/homebrew/logs"
export HOMEBREW_TEMP="$TMPDIR"
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

# A second prep must not replace artifacts while the first is still building them.
LOCK="$ROOT/.build/ghostty/setup.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Ghostty setup is already running (lock: $LOCK)" >&2
  exit 1
fi
trap 'rmdir "$LOCK"' EXIT

ZIG="$(brew --prefix "$ZIG_FORMULA" 2>/dev/null || true)/bin/zig"
if [[ ! -x "$ZIG" ]]; then
  echo "Installing required keg-only $ZIG_FORMULA..."
  brew install "$ZIG_FORMULA"
  ZIG="$(brew --prefix "$ZIG_FORMULA")/bin/zig"
fi
if [[ "$("$ZIG" version)" != "0.15.2" ]]; then
  echo "This Ghostty pin requires Zig 0.15.2; found $("$ZIG" version)" >&2
  exit 1
fi
if ! xcrun metal --version >/dev/null 2>&1; then
  xcodebuild -downloadComponent MetalToolchain
fi

SOURCE="$ROOT/.build/ghostty/source"
if [[ ! -d "$SOURCE/.git" ]]; then
  git init -q "$SOURCE"
fi
if ! git -C "$SOURCE" cat-file -e "$GHOSTTY_REV^{commit}" 2>/dev/null; then
  echo "Fetching Ghostty $GHOSTTY_REV..."
  git -C "$SOURCE" fetch -q --depth 1 "$GHOSTTY_REPO" "$GHOSTTY_REV"
fi
git -C "$SOURCE" -c advice.detachedHead=false checkout -q "$GHOSTTY_REV"

echo "Building Ghostty $GHOSTTY_REV from source with Zig $("$ZIG" version)..."
(
  cd "$SOURCE"
  "$ZIG" build -Doptimize=ReleaseFast -Demit-xcframework=true \
    -Dxcframework-target=native -Demit-macos-app=false
)

# Replace only setup-owned generated artifacts after a successful source build.
rm -rf "$FRAMEWORK" "$RESOURCES/ghostty" "$RESOURCES/terminfo"
mkdir -p "$RESOURCES/ghostty"
cp -R "$SOURCE/macos/GhosttyKit.xcframework" "$FRAMEWORK"
cp -R "$SOURCE/zig-out/share/ghostty/themes" "$RESOURCES/ghostty/"
cp -R "$SOURCE/zig-out/share/ghostty/shell-integration" "$RESOURCES/ghostty/"
# libghostty resolves TERMINFO as dirname(GHOSTTY_RESOURCES_DIR)/terminfo.
cp -R "$SOURCE/zig-out/share/terminfo" "$RESOURCES/terminfo"
cp "$SOURCE/LICENSE" "$RESOURCES/ghostty/LICENSE"
printf '%s\n' "$GHOSTTY_REV" > "$FRAMEWORK/.kubix-revision"
echo "Ghostty setup complete"
