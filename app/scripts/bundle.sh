#!/usr/bin/env bash
#
# Build ClaudeStatus.app — a menu-bar (LSUIElement) app bundle.
#
#   ./scripts/bundle.sh            build into app/dist/ClaudeStatus.app
#   ./scripts/bundle.sh --install  also copy it into /Applications
#
# Ad-hoc signed (codesign -s -) so it runs locally. Distribution needs a real
# Developer ID cert + notarization — deferred until there's an Apple account.

set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/.." && pwd)"
APP="$APP_ROOT/dist/ClaudeStatus.app"

echo "Building release binary..."
( cd "$APP_ROOT" && swift build -c release )
BIN="$APP_ROOT/.build/release/ClaudeStatus"
[ -x "$BIN" ] || { echo "build produced no binary at $BIN" >&2; exit 1; }

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeStatus"
cp "$APP_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# App icon (Finder + notifications): generate the .icns from the source PNG if
# it's missing or stale, then bundle it.
if [ -f "$APP_ROOT/Resources/icon.png" ]; then
  if [ ! -f "$APP_ROOT/Resources/AppIcon.icns" ] || \
     [ "$APP_ROOT/Resources/icon.png" -nt "$APP_ROOT/Resources/AppIcon.icns" ]; then
    "$APP_ROOT/scripts/make-icon.sh" >/dev/null
  fi
  cp "$APP_ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# Bundle the jump script so the app is self-contained (no dev checkout needed).
cp "$REPO_ROOT/bin/claude-status-jump.sh" "$APP/Contents/Resources/claude-status-jump.sh"
chmod +x "$APP/Contents/Resources/claude-status-jump.sh"

echo "Ad-hoc signing..."
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/  /' || true

if [ "${1:-}" = "--install" ]; then
  echo "Installing to /Applications..."
  rm -rf "/Applications/ClaudeStatus.app"
  cp -R "$APP" "/Applications/ClaudeStatus.app"
  echo "Installed. Launch with: open -a ClaudeStatus"
else
  echo "Built $APP"
  echo "Run it with: open \"$APP\"    (or re-run with --install)"
fi
