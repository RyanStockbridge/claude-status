#!/usr/bin/env bash
#
# claude-status-notify.sh <session_id> <new_state> <prev_state> <prev_state_since>
#
# Delivers a desktop notification when a session changes state. Invoked by
# claude-status-write.sh, and only when prev_state != new_state.
#
# Reads the just-written record at $CLAUDE_STATUS_DIR/<sid>.json for the
# human-facing bits (title, project, detail) and $HOME/.claude/claude-status.json
# for gating. Delivers via terminal-notifier (clickable — jumps to the session,
# grouped per session) and falls back to osascript when it isn't installed.
#
# Like the writer, this must never fail loudly. Every path exits 0 — a broken
# notifier must not disturb a real Claude Code session.

set -uo pipefail

sid="${1:-}"
STATE="${2:-}"
PREV_STATE="${3:-}"
PREV_SINCE="${4:-0}"

[ -n "$sid" ] && [ -n "$STATE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

DIR="${CLAUDE_STATUS_DIR:-$HOME/.claude/status}"
file="$DIR/$sid.json"
[ -f "$file" ] || exit 0

CONFIG="${CLAUDE_STATUS_CONFIG:-$HOME/.claude/claude-status.json}"
cfg='{}'
if [ -f "$CONFIG" ]; then
  raw="$(cat "$CONFIG" 2>/dev/null)"
  if printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    cfg="$raw"
  fi
fi

# --- gating -----------------------------------------------------------------
# jq's `//` treats `false` as absent, so `.enabled // true` can never be false
# (gotcha #3). Every boolean default below uses `if . == null then D else . end`.

enabled="$(printf '%s' "$cfg" | jq -r '
  .notifications.enabled | if . == null then true else . end' 2>/dev/null)"
[ "$enabled" = "true" ] || exit 0

# Per-state switch. Default: notify for states that want your attention, stay
# quiet for the routine ones (working / idle).
state_on="$(printf '%s' "$cfg" | jq -r --arg s "$STATE" '
  .notifications.states[$s]
  | if . == null then ($s | IN("error","blocked","waiting","done")) else . end
  ' 2>/dev/null)"
[ "$state_on" = "true" ] || exit 0

# min_turn_seconds: suppress a working->done/idle flip when the turn was shorter
# than this, so quick commands do not spam a banner. Only applies coming out of
# `working`; attention states are never suppressed by it.
min_turn="$(printf '%s' "$cfg" | jq -r '
  .notifications.min_turn_seconds | if . == null then 0 else . end | floor' 2>/dev/null)"
case "$min_turn" in ''|*[!0-9]*) min_turn=0 ;; esac
case "$PREV_SINCE" in ''|*[!0-9]*) PREV_SINCE=0 ;; esac
if [ "$min_turn" -gt 0 ] && [ "$PREV_STATE" = "working" ]; then
  now="$(date +%s)"
  if [ "$(( now - PREV_SINCE ))" -lt "$min_turn" ]; then
    exit 0
  fi
fi

# --- message ----------------------------------------------------------------
title="$(jq -r '.title // ""' "$file" 2>/dev/null)"
project="$(jq -r '.project // ""' "$file" 2>/dev/null)"
detail="$(jq -r '.detail // ""' "$file" 2>/dev/null)"

case "$STATE" in
  blocked) message="Needs your approval" ;;
  waiting) message="Waiting for your input" ;;
  done)    message="Finished" ;;
  error)   message="${detail:-Something went wrong}" ;;
  working) message="Working${title:+: }$title" ;;
  idle)    message="Session ready" ;;
  *)       message="$STATE" ;;
esac

ntitle="Claude Code${project:+ · }$project"
subtitle="$title"

# --- deliver ----------------------------------------------------------------
JUMP="$(dirname "$0")/claude-status-jump.sh"

if command -v terminal-notifier >/dev/null 2>&1; then
  args=(
    -title "$ntitle"
    -message "$message"
    -group "$sid"
  )
  [ -n "$subtitle" ] && args+=( -subtitle "$subtitle" )
  # Click the banner to jump to the session's terminal / editor.
  [ -x "$JUMP" ] && args+=( -execute "\"$JUMP\" \"$sid\"" )
  # A sound only for the states you actually need to act on.
  case "$STATE" in blocked|error) args+=( -sound default ) ;; esac
  terminal-notifier "${args[@]}" >/dev/null 2>&1
else
  # Fallback: osascript can't make the banner clickable. Sanitize quotes so the
  # AppleScript string literal stays well-formed.
  san() { printf '%s' "$1" | tr '"' "'"; }
  osascript -e "display notification \"$(san "$message")\" with title \"$(san "$ntitle")\" subtitle \"$(san "$subtitle")\"" >/dev/null 2>&1
fi

exit 0
