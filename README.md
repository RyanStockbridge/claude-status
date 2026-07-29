# claude-status

A macOS menu bar readout of every Claude Code session you have running — across
every project, every VS Code window, every terminal tab. Shows you at a glance
which ones are working, which are blocked on you, which finished, and which
errored. Click one to jump straight to it.

```
  ● 2        ← menu bar: two sessions want you

  lifewize_frontend
  🟠 refactor the auth middleware…      — needs approval 40s
  🟡 add the helpdesk runbook page      — Edit 3s
  lifewize_backend
  🟢 write migration for ledger table   — done 2m ago
  power3-ads
  🔴 (rate_limit)
```

No polling, no scraping, no remote-control session required. Claude Code's own
hooks push state out; the menu bar reads it.

---

## Install

**Requirements:** macOS, `jq` (`brew install jq`), and SwiftBar
(`brew install --cask swiftbar`).

```bash
git clone <your-repo> claude-status && cd claude-status
./install.sh --local-hooks
```

Restart any running Claude Code sessions, and the menu bar icon populates as
soon as you send a prompt.

`./install.sh --uninstall` reverses everything.

### Shipping it to your partners

`--local-hooks` edits `~/.claude/settings.json` directly, which is fine for you
but not something you want to talk five people through. Push this folder to a
git repo instead — it already contains `.claude-plugin/marketplace.json` — and
they run:

```
/plugin marketplace add <you>/claude-status
/plugin install claude-status@ryan-tools
```

That wires the hooks globally with no file editing, and `git push` ships
updates. They still need SwiftBar and the plugin symlink, so have them run
`./install.sh` (no flag) once for the menu bar half.

---

## How it works

The moving parts:

**`bin/claude-status-write.sh`** — one hook handler for every event. Reads the
hook payload on stdin, writes `~/.claude/status/<session_id>.json`. Writes are
atomic (temp file + rename) so the reader never sees a partial record. Every
failure path exits 0: a broken status writer must never interfere with an
actual session.

**`hooks/hooks.json`** — the event → state mapping:

| Event | State | |
|---|---|---|
| `SessionStart` | `idle` | session open, no turn yet |
| `UserPromptSubmit` | `working` | also captures a title from the prompt |
| `PostToolUse` | `working` | heartbeat + "what is it doing right now" |
| `Notification` / `permission_prompt` | `blocked` | needs your approval |
| `Notification` / `idle_prompt`, `agent_needs_input` | `waiting` | needs a prompt |
| `Stop` | `done` | |
| `StopFailure` | `error` | carries the error type: `rate_limit`, `overloaded`… |
| `SessionEnd` | — | record deleted |

Every handler is `"async": true`, so none of this adds latency to a turn.

**`bin/claude-status-notify.sh`** — fired by the writer only when a session
actually changes state. Sends a desktop notification via `terminal-notifier`
(click the banner to jump straight to that session, and repeat banners for one
session collapse into a group) or falls back to `osascript` if
`terminal-notifier` isn't installed. Gated by config (see
[Notifications](#notifications)); by default it stays quiet for the routine
`working`/`idle` states and only speaks up for `blocked`, `waiting`, `done`, and
`error`, with a sound reserved for `blocked`/`error`. Like the writer, every
path exits 0.

**`swiftbar/claude-status.1s.py`** — reads the directory once a second, groups
by project, sorts attention-first. Sweeps records older than 6h (crashed
sessions never fire `SessionEnd`) and flags `working` sessions with no tool
activity for 2min as possibly wedged.

### Jumping to a session

`bin/claude-status-jump.sh` uses the session's launch surface
(`CLAUDE_CODE_ENTRYPOINT`) and the terminal identity captured from the
environment at hook time, in descending order of precision:

| Surface | Precision |
|---|---|
| tmux | exact pane (`select-window` + `select-pane`) |
| iTerm2 | exact session, via AppleScript on `ITERM_SESSION_ID` |
| WezTerm | exact pane |
| VS Code extension panel | **exact session tab** — `vscode://anthropic.claude-code/open?session=<id>` reveals the panel for that Claude session id |
| VS Code integrated terminal | the **window** holding that folder (`open -b com.microsoft.VSCode <cwd>`); you pick the tab |
| Claude desktop app | app only — activates Claude; no per-session route yet |
| Terminal.app | app only — no reliable per-tab handle |

The VS Code extension-panel jump piggybacks on a URI handler the official
extension registers, so it needs no companion extension — the panel session id
is Claude Code's own `session_id`, which is what we key records on. (Verified by
reading the extension bundle; confirm against your own setup, since the bundle
auto-updates often.) The integrated-terminal and desktop-app cases remain the
honest limitations: you land in the right window/app but pick the session
yourself.

---

## Tuning

- **Too chatty?** Drop the `PostToolUse` block from `hooks/hooks.json`. You
  lose the live tool line and the stall detection, but you also stop spawning a
  process per tool call.
- **Faster/slower refresh:** rename the plugin file — `claude-status.2s.py`,
  `.5s.py`, etc. SwiftBar reads the interval from the filename.
- **Different status dir:** set `CLAUDE_STATUS_DIR` (both halves respect it).

### Notifications

Banners are on by default for the states that want your attention. To tune them,
create `~/.claude/claude-status.json`:

```json
{
  "notifications": {
    "enabled": true,
    "min_turn_seconds": 0,
    "states": {
      "blocked": true,
      "waiting": true,
      "done": true,
      "error": true,
      "working": false,
      "idle": false
    }
  }
}
```

- **`enabled`** — master switch. Set to `false` to silence everything (a real
  `false`, not just a missing key, is honored).
- **`states`** — turn any individual state on or off. Omitted states keep their
  defaults (on for `error`/`blocked`/`waiting`/`done`, off for
  `working`/`idle`).
- **`min_turn_seconds`** — suppress the "done" banner when a turn finished faster
  than this, so quick one-off commands don't ping you. Only affects the
  `working`→`done`/`idle` transition; attention states always come through.

Install [`terminal-notifier`](https://github.com/julienXX/terminal-notifier)
(`brew install terminal-notifier`) for clickable, grouped banners; without it,
notifications still work through `osascript` but can't be clicked to jump.

## Remote sessions (VS Code Remote SSH)

Sessions running on another machine write their status files *on that machine*,
so a local file watcher won't see them. Two options:

1. **Quick:** the menu shows nothing for them, but `claude --resume` still
   works — the jump script detects a foreign `host` and copies an
   `ssh … claude --resume …` command to your clipboard.
2. **Proper:** switch the hook entries from `"type": "command"` to
   `"type": "http"` pointing at a small listener on your laptop, reachable over
   Tailscale or an SSH reverse tunnel. Claude Code POSTs the same JSON payload,
   so the listener can write the identical status files. No file syncing.

## Next: the native app

This is the v0 whose job is to prove the state model is right before anyone
writes Swift. Once the states feel correct in daily use, the SwiftBar script
becomes a ~350-line SwiftUI `MenuBarExtra`:

- `FSEventStream` on the status dir instead of a 1s poll
- a real badge count on the icon, and an animated glyph while anything works
- `UNUserNotificationCenter` banner the moment a session flips to `blocked`
- global hotkey to cycle through sessions needing attention
- distribute via a Homebrew cask; sign + notarize with an Apple Developer
  account so partners don't hit Gatekeeper

The hooks half doesn't change — the Swift app reads exactly the same files.
