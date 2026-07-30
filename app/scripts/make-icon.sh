#!/usr/bin/env bash
#
# Generate Resources/AppIcon.icns from a source PNG (ideally 1024x1024).
#
#   ./scripts/make-icon.sh [source.png]     default: Resources/icon.png
#
# The source should already be the full rounded-square artwork — macOS does not
# mask app icons the way iOS does, so whatever shape you provide is what shows.

set -euo pipefail
APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$APP_ROOT/Resources/icon.png}"
OUT="$APP_ROOT/Resources/AppIcon.icns"

[ -f "$SRC" ] || { echo "source image not found: $SRC" >&2; exit 1; }

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  s2=$((s * 2))
  sips -z "$s"  "$s"  "$SRC" --out "$ICONSET/icon_${s}x${s}.png"     >/dev/null
  sips -z "$s2" "$s2" "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png"  >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$(dirname "$ICONSET")"
echo "wrote $OUT"
