#!/usr/bin/env bash
#
# claude-status-write.sh <state>
#
# Reads a Claude Code hook payload on stdin and publishes the session's
# current state to $CLAUDE_STATUS_DIR/<session_id>.json (default
# ~/.claude/status). One file per live session; the menu bar app watches
# the directory.
#
# States: idle | working | waiting | blocked | done | error | closed
#
# This script must never fail loudly — a broken status writer should never
# interfere with an actual Claude Code session. Every path exits 0.

set -uo pipefail

STATE="${1:-working}"
DIR="${CLAUDE_STATUS_DIR:-$HOME/.claude/status}"

mkdir -p "$DIR" 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null)"
[ -n "$payload" ] || exit 0

sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$sid" ] || exit 0

file="$DIR/$sid.json"

# SessionEnd: drop the record entirely.
if [ "$STATE" = "closed" ]; then
  rm -f "$file"
  exit 0
fi

# Load the previous record so we can preserve started_at, title, etc.
prev='{}'
if [ -f "$file" ]; then
  prev="$(cat "$file" 2>/dev/null)"
  printf '%s' "$prev" | jq -e . >/dev/null 2>&1 || prev='{}'
fi

now="$(date +%s)"
host="$(hostname -s 2>/dev/null || echo local)"

tmp="$file.tmp.$$"

printf '%s' "$payload" | jq -c \
  --argjson prev "$prev" \
  --arg state "$STATE" \
  --argjson now "$now" \
  --arg host "$host" \
  --arg pid "${PPID:-}" \
  --arg term_program "${TERM_PROGRAM:-}" \
  --arg iterm "${ITERM_SESSION_ID:-}" \
  --arg term_session "${TERM_SESSION_ID:-}" \
  --arg tmux_pane "${TMUX_PANE:-}" \
  --arg wezterm_pane "${WEZTERM_PANE:-}" \
  --arg kitty_window "${KITTY_WINDOW_ID:-}" \
  --arg vscode_pid "${VSCODE_PID:-}" \
  --arg remote "${CLAUDE_CODE_REMOTE:-}" \
  '
  # The VS Code / JetBrains extensions inject context blocks such as
  # <ide_opened_file>...</ide_opened_file> into the prompt payload. Strip any
  # tagged block so the session title reflects what the human actually typed.
  def strip_tags($s):
    ($s // "")
    | gsub("<([a-zA-Z_][a-zA-Z0-9_-]*)\\b[^>]*>[\\s\\S]*?</\\1>"; " ")
    | gsub("<[^>]*>"; " ")
    | gsub("\\s+"; " ")
    | sub("^ +"; "") | sub(" +$"; "");

  def clip($s; $n):
    strip_tags($s) as $t
    | if ($t | length) > $n then ($t[0:$n] + "\u2026") else $t end;

  . as $h
  | (($h.cwd // $prev.cwd) // "")                                as $cwd
  | (strip_tags($h.prompt // ""))                                 as $clean
  | ($h.session_title
      // (if ($h.hook_event_name == "UserPromptSubmit") and (($clean | length) > 0)
          then clip($clean; 60)
          else null end)
      // $prev.title)                                            as $title
  | (if $prev.state == $state then ($prev.state_since // $now) else $now end) as $since
  | {
      session_id:      $h.session_id,
      state:           $state,
      state_since:     $since,
      started_at:      ($prev.started_at // $now),
      updated_at:      $now,
      cwd:             $cwd,
      project:         (($cwd | split("/") | last) // ""),
      title:           $title,
      last_event:      ($h.hook_event_name // null),
      last_tool:       ($h.tool_name // $prev.last_tool // null),
      detail:          (if ($h.message // $h.error_type // $h.reason) != null
                        then clip(($h.message // $h.error_type // $h.reason); 80)
                        else null end),
      permission_mode: ($h.permission_mode // $prev.permission_mode // null),
      host:            $host,
      agent_pid:       (($pid | tonumber?) // null),
      remote:          ($remote == "true"),
      term: {
        program:       (if $term_program != "" then $term_program else $prev.term.program end),
        iterm:         (if $iterm        != "" then $iterm        else $prev.term.iterm end),
        term_session:  (if $term_session != "" then $term_session else $prev.term.term_session end),
        tmux_pane:     (if $tmux_pane    != "" then $tmux_pane    else $prev.term.tmux_pane end),
        wezterm_pane:  (if $wezterm_pane != "" then $wezterm_pane else $prev.term.wezterm_pane end),
        kitty_window:  (if $kitty_window != "" then $kitty_window else $prev.term.kitty_window end),
        vscode_pid:    (if $vscode_pid   != "" then $vscode_pid   else $prev.term.vscode_pid end)
      }
    }
  ' > "$tmp" 2>/dev/null

# Atomic swap so the reader never sees a half-written file.
if [ -s "$tmp" ]; then
  mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
else
  rm -f "$tmp"
  exit 0
fi

# Notify only on a real state change, and only if the write landed. The notifier
# gates itself on config; keep it detached so it can never stall the session.
prev_state="$(printf '%s' "$prev" | jq -r '.state // ""' 2>/dev/null)"
prev_since="$(printf '%s' "$prev" | jq -r '.state_since // 0' 2>/dev/null)"
if [ "$prev_state" != "$STATE" ]; then
  notifier="$(dirname "$0")/claude-status-notify.sh"
  if [ -x "$notifier" ]; then
    "$notifier" "$sid" "$STATE" "$prev_state" "$prev_since" >/dev/null 2>&1 &
  fi
fi

exit 0
