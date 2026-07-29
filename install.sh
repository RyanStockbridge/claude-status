#!/usr/bin/env bash
#
#   ./install.sh              installs the SwiftBar plugin only
#                             (use this if you install the hooks via /plugin)
#
#   ./install.sh --local-hooks  also merges the hooks into ~/.claude/settings.json
#                               with absolute paths — good for testing before
#                               you publish the plugin repo
#
#   ./install.sh --uninstall    removes both

set -euo pipefail
RESTART_SWIFTBAR=0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
MODE="${1:-}"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only."
command -v jq >/dev/null 2>&1 || die "jq is required. Install it with: brew install jq"

chmod +x "$ROOT/bin/"*.sh "$ROOT/swiftbar/"*.py

# ---------------------------------------------------------------- SwiftBar ---
swiftbar_dir() {
  local d
  d="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
  [ -n "$d" ] && [ -d "$d" ] && { printf '%s' "$d"; return; }
  for c in "$HOME/SwiftBar" "$HOME/Documents/SwiftBar" "$HOME/.swiftbar"; do
    [ -d "$c" ] && { printf '%s' "$c"; return; }
  done
}

install_swiftbar() {
  if ! [ -d "/Applications/SwiftBar.app" ]; then
    warn "SwiftBar not found. Install it with: brew install --cask swiftbar"
    warn "Then re-run this script."
    return 1
  fi
  local dir; dir="$(swiftbar_dir)"
  if [ -z "$dir" ]; then
    dir="$HOME/SwiftBar"; mkdir -p "$dir"
    # Tell SwiftBar where to look; without this it shows an empty menu and
    # gives no indication that anything is wrong.
    defaults write com.ameba.SwiftBar PluginDirectory -string "$dir"
    ok "Set SwiftBar plugin folder to $dir"
    RESTART_SWIFTBAR=1
  fi
  # Copy, don't symlink: some SwiftBar builds skip symlinked plugins (and a
  # symlink into a moved/renamed checkout silently dangles). Copies mean you
  # re-run this script to update — which is what keeps the installed plugin from
  # rotting to an old version.
  cp "$ROOT/swiftbar/claude-status.1s.py" "$dir/claude-status.1s.py"
  # the renderer looks for the jump script beside itself first
  cp "$ROOT/bin/claude-status-jump.sh" "$dir/claude-status-jump.sh"
  chmod +x "$dir/claude-status.1s.py" "$dir/claude-status-jump.sh"
  # SwiftBar won't execute quarantined plugins, and a zip from a browser stamps
  # every file. Clear it on the installed copies.
  xattr -dr com.apple.quarantine "$dir/claude-status.1s.py" "$dir/claude-status-jump.sh" 2>/dev/null || true
  ok "SwiftBar plugin copied into $dir"

  if [ "${RESTART_SWIFTBAR:-0}" = "1" ] && pgrep -x SwiftBar >/dev/null 2>&1; then
    killall SwiftBar 2>/dev/null || true; sleep 1; open -a SwiftBar
    ok "SwiftBar restarted"
  elif ! pgrep -x SwiftBar >/dev/null 2>&1; then
    open -a SwiftBar 2>/dev/null && ok "SwiftBar launched"
  fi
}

# ------------------------------------------------------------------- hooks ---
install_hooks() {
  mkdir -p "$HOME/.claude"
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  local backup="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS" "$backup"

  jq --slurpfile add "$ROOT/hooks/hooks.json" --arg root "$ROOT" '
    # resolve ${CLAUDE_PLUGIN_ROOT} to this checkout
    ($add[0].hooks
      | with_entries(.value |= map(.hooks |= map(.command |= gsub("\\$\\{CLAUDE_PLUGIN_ROOT\\}"; $root))))
    ) as $new
    # drop any previous copy of our hooks so re-running is idempotent
    | .hooks = ((.hooks // {})
        | with_entries(.value |= (
              map(.hooks |= map(select((.command // "") | test("claude-status-write\\.sh") | not)))
            | map(select((.hooks | length) > 0))))
        | with_entries(select((.value | length) > 0)))
    # append ours
    | .hooks = (reduce ($new | to_entries[]) as $e (.hooks; .[$e.key] = ((.[$e.key] // []) + $e.value)))
  ' "$backup" > "$SETTINGS.tmp"

  jq -e . "$SETTINGS.tmp" >/dev/null || { rm -f "$SETTINGS.tmp"; die "hook merge produced invalid JSON; $backup untouched"; }
  mv -f "$SETTINGS.tmp" "$SETTINGS"
  ok "Hooks merged into $SETTINGS  (backup: $(basename "$backup"))"
}

uninstall_hooks() {
  [ -f "$SETTINGS" ] || return 0
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  jq '
    .hooks = ((.hooks // {})
      | with_entries(.value |= (
            map(.hooks |= map(select((.command // "") | test("claude-status-write\\.sh") | not)))
          | map(select((.hooks | length) > 0))))
      | with_entries(select((.value | length) > 0)))
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv -f "$SETTINGS.tmp" "$SETTINGS"
  ok "Hooks removed from $SETTINGS"
}

# -------------------------------------------------------------------- main ---
echo
case "$MODE" in
  --uninstall)
    uninstall_hooks
    d="$(swiftbar_dir)"
    [ -n "$d" ] && rm -f "$d/claude-status.1s.py" "$d/claude-status-jump.sh" && ok "SwiftBar plugin unlinked"
    rm -rf "$HOME/.claude/status" && ok "Status directory cleared"
    ;;
  --local-hooks)
    install_hooks
    install_swiftbar || true
    say ""
    say "Restart any running Claude Code sessions to pick up the hooks."
    ;;
  *)
    install_swiftbar || true
    say ""
    say "Now install the hooks. Either:"
    say "  a) publish this folder as a git repo, then in Claude Code:"
    say "       /plugin marketplace add <you>/claude-status"
    say "       /plugin install claude-status@ryan-tools"
    say "  b) or for a quick local test:  ./install.sh --local-hooks"
    ;;
esac
echo
