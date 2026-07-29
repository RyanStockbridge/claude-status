#!/usr/bin/env bash
#
# claude-status-jump.sh <session_id>
#
# Brings the terminal/editor hosting a Claude Code session to the front,
# as precisely as the host program allows:
#
#   tmux      exact pane
#   iTerm2    exact session (window + tab + split)
#   VS Code   the window that has the project folder open
#   other     activate the app, else reveal the folder in Finder
#
# Remote sessions (a different host) can't be focused locally, so the
# resume command is copied to the clipboard instead.

set -uo pipefail

DIR="${CLAUDE_STATUS_DIR:-$HOME/.claude/status}"
sid="${1:-}"
file="$DIR/$sid.json"
[ -n "$sid" ] && [ -f "$file" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

get() { jq -r --arg p "$1" 'getpath($p | split(".")) // "" | tostring' "$file" 2>/dev/null; }

cwd="$(get cwd)"
host="$(get host)"
program="$(get term.program)"
entrypoint="$(get entrypoint)"
iterm="$(get term.iterm)"
tmux_pane="$(get term.tmux_pane)"
wezterm_pane="$(get term.wezterm_pane)"
me="$(hostname -s 2>/dev/null || echo local)"

notify() {
  osascript -e "display notification \"$1\" with title \"Claude Status\"" >/dev/null 2>&1
}

# --- remote session: hand back a resume command -----------------------------
if [ -n "$host" ] && [ "$host" != "$me" ]; then
  printf 'ssh %s -t "cd %q && claude --resume %s"' "$host" "$cwd" "$sid" | pbcopy 2>/dev/null
  notify "Session is on $host — resume command copied to clipboard"
  exit 0
fi

# --- surface routing by entrypoint -----------------------------------------
# CLAUDE_CODE_ENTRYPOINT tells us which app launched the session, which is the
# only reliable signal for the windowless surfaces (the VS Code extension panel
# and the Claude desktop app set no TERM_PROGRAM, so `program` is empty).
case "$entrypoint" in
  claude-vscode)
    # The official extension registers a URI handler: /open?session=<id> calls
    # createPanel(id), which reveals the existing panel for that Claude session
    # id (the same id we key our records on). Opening the URI also brings VS Code
    # to the front, so this both focuses the window and the exact session tab.
    # (A session living only in the integrated terminal has no panel, so this
    # would open a fresh one — the extension panel/sidebar is the common case.)
    open "vscode://anthropic.claude-code/open?session=$sid" >/dev/null 2>&1 && exit 0
    ;;
  claude-desktop)
    # No documented route to focus a specific session inside the desktop app yet
    # (it registers the `claude://` scheme, grammar TBD). Activate the app.
    open -b com.anthropic.claudefordesktop >/dev/null 2>&1 && exit 0
    open -a Claude >/dev/null 2>&1 && exit 0
    ;;
esac

# --- tmux: select the exact pane, then fall through to focus the terminal ---
if [ -n "$tmux_pane" ] && command -v tmux >/dev/null 2>&1; then
  tmux select-window -t "$tmux_pane" >/dev/null 2>&1
  tmux select-pane   -t "$tmux_pane" >/dev/null 2>&1
fi

# --- WezTerm ---------------------------------------------------------------
if [ -n "$wezterm_pane" ] && command -v wezterm >/dev/null 2>&1; then
  wezterm cli activate-pane --pane-id "$wezterm_pane" >/dev/null 2>&1 && exit 0
fi

case "$program" in
  vscode)
    # VS Code focuses the existing window that already has this folder open.
    for bundle in com.microsoft.VSCode com.microsoft.VSCodeInsiders com.vscodium.codium; do
      if open -b "$bundle" "$cwd" >/dev/null 2>&1; then exit 0; fi
    done
    open -a "Visual Studio Code" "$cwd" >/dev/null 2>&1 && exit 0
    ;;

  iTerm.app)
    # ITERM_SESSION_ID looks like "w0t2p0:UUID"; iTerm's session id is the UUID.
    uuid="${iterm##*:}"
    if [ -n "$uuid" ]; then
      osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (id of s) is "$uuid" then
          select w
          select t
          select s
          activate
          return
        end if
      end repeat
    end repeat
  end repeat
  activate
end tell
APPLESCRIPT
      exit 0
    fi
    open -a iTerm >/dev/null 2>&1 && exit 0
    ;;

  Apple_Terminal)
    # Terminal.app gives us no reliable per-tab handle; activate the app.
    open -a Terminal >/dev/null 2>&1 && exit 0
    ;;

  ghostty)  open -a Ghostty  >/dev/null 2>&1 && exit 0 ;;
  WarpTerminal) open -a Warp >/dev/null 2>&1 && exit 0 ;;
  Hyper)    open -a Hyper    >/dev/null 2>&1 && exit 0 ;;
  kitty)    open -a kitty    >/dev/null 2>&1 && exit 0 ;;
esac

# --- last resort ------------------------------------------------------------
[ -n "$cwd" ] && open "$cwd" >/dev/null 2>&1
exit 0
