# claude-status

A macOS menu bar app that shows every Claude Code session you have running — across
every project, every VS Code window, every terminal, and the Claude desktop app.
See at a glance which sessions are working, which are blocked on you, which
finished, and which errored — and **click one to jump straight to it**. Get a
native notification the moment a session needs your input.

No polling, no scraping, no remote-control session. Claude Code's own hooks push
each session's state to a JSON file; the menu bar app reads it.

```
  ● 2                                   ← menu bar: two sessions want you

  LIFEWIZE
  ✋ Refactor the auth middleware…       Needs your approval · 40s
  ● Add the helpdesk runbook page       Edit · 3s
  POWER3-ADS
  ✓ Write migration for ledger table    Finished 2m ago
```

---

## Requirements

- **macOS 14 (Sonoma) or newer**
- **`jq`** — `brew install jq`
- **Xcode command-line tools** (to build the app) — `xcode-select --install`

## Install

Two halves: the **hooks** publish each session's state, and the **menu bar app**
reads it. Clone once, then run both steps:

```bash
git clone https://github.com/RyanStockbridge/claude-status.git
cd claude-status
```

**1. Install the hooks** (publishes status to `~/.claude/status/`):

```bash
./install.sh --local-hooks
```

This backs up and edits `~/.claude/settings.json` to add the hooks. Hooks load at
session start, so **restart any running Claude Code sessions** afterward — new
sessions show up in the app as soon as you send a prompt.

**2. Build & install the menu bar app:**

```bash
cd app && ./scripts/bundle.sh --install
open -a ClaudeStatus
```

That compiles `ClaudeStatus.app`, installs it to `/Applications`, and launches it.
It lives in the menu bar (no Dock icon).

### First-run notes / quirks

- **Gatekeeper:** the app is unsigned (ad-hoc). Because you *build it locally* it
  carries no quarantine flag, so it just opens. (If you instead copy a prebuilt
  `.app` from another Mac or a download, macOS will block it — clear it with
  `xattr -dr com.apple.quarantine /Applications/ClaudeStatus.app`, or approve it
  in System Settings → Privacy & Security → "Open Anyway".)
- **Notifications:** on first launch, click **Allow** on the permission prompt.
  Then in System Settings → Notifications → **ClaudeStatus**, set the alert style
  to **Alerts** if you want them to stay on screen (Banners auto-dismiss). A Focus
  / Do Not Disturb will send them to Notification Center only.
- **Open at Login:** tick the checkbox in the app's popover footer so it starts
  automatically.
- **jq required:** the hook writer no-ops silently without `jq`, so install it
  first.

### Updating

```bash
cd claude-status && git pull
./install.sh --local-hooks            # refresh the hooks (safe to re-run)
cd app && ./scripts/bundle.sh --install   # rebuild & reinstall the app
```

Then restart the app (quit from its popover, `open -a ClaudeStatus`) and restart
any Claude sessions to pick up hook changes.

### Uninstall

```bash
./install.sh --uninstall                 # removes hooks + status dir
rm -rf /Applications/ClaudeStatus.app    # removes the app
```

---

## How it works

Two halves that talk only through a directory of JSON files (`~/.claude/status/`),
one file per live session.

**`bin/claude-status-write.sh`** — one hook handler for every event. Reads the
hook payload on stdin, writes `~/.claude/status/<session_id>.json`. Writes are
atomic (temp file + rename) so the reader never sees a partial record. Captures
the session's launch surface (`CLAUDE_CODE_ENTRYPOINT`) and terminal identity for
precise jumps. Every failure path exits 0 — a broken status writer must never
interfere with a real session.

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

**`app/` — the menu bar app** (SwiftUI `MenuBarExtra`). Watches the status
directory (event-driven, no polling), groups sessions by project attention-first,
draws the colored status dot + attention count, and posts a native notification
(with a **Jump** action) the moment a session enters `blocked`/`waiting`/`error`.
Sweeps records older than 6h (crashed sessions never fire `SessionEnd`) and flags
`working` sessions idle >2min as possibly stalled.

### Jumping to a session

Clicking a session runs `bin/claude-status-jump.sh`, which focuses the host as
precisely as it allows, keyed on Claude Code's own `session_id`:

| Surface | Precision |
|---|---|
| Claude desktop app | **exact session** — `claude://resume?session=<id>` opens that conversation and focuses the app |
| VS Code extension panel | **exact session tab** — `vscode://anthropic.claude-code/open?session=<id>` reveals the panel (one-time per-extension consent on first jump) |
| tmux | exact pane |
| iTerm2 | exact session, via AppleScript on `ITERM_SESSION_ID` |
| WezTerm | exact pane |
| VS Code integrated terminal | the **window** holding that folder; you pick the tab |
| Terminal.app | app only — no reliable per-tab handle |

Both the desktop-app and VS Code-panel jumps piggyback on URI handlers those apps
already register — no companion extension. (Verified live; both bundles
auto-update often, so recheck if a jump ever stops working.)

---

## Options

- **Different status dir:** set `CLAUDE_STATUS_DIR` (both halves respect it). The
  app also reads a `statusDir` value from its own `UserDefaults` for testing.
- **Too chatty?** Drop the `PostToolUse` block from `hooks/hooks.json` to stop
  spawning a process per tool call (you lose the live tool line + stall detection).

### Shell-notifier alternative

The app owns notifications. There's also a standalone shell notifier
(`bin/claude-status-notify.sh`, via `terminal-notifier`/`osascript`) for setups
not running the app — configure it in `~/.claude/claude-status.json`:

```json
{ "notifications": { "enabled": true, "min_turn_seconds": 0,
  "states": { "blocked": true, "waiting": true, "done": true, "error": true,
              "working": false, "idle": false } } }
```

`enabled:false` silences it (a real `false` is honored). If you run **both** the
app and the shell notifier you'll get double banners — keep one. `min_turn_seconds`
suppresses the "done" banner for turns shorter than N seconds.

### SwiftBar (legacy frontend)

Before the native app there was a SwiftBar plugin (`swiftbar/claude-status.1s.py`)
— a 1s-poll renderer of the same files. Still works if you prefer SwiftBar
(`brew install --cask swiftbar`, then `./install.sh --swiftbar`), but the native
app is recommended. Don't run both, or you'll get two menu bar items.

## Remote sessions (VS Code Remote SSH)

Sessions on another machine write their status files *there*, so a local watcher
won't see them. The jump script detects a foreign `host` and copies an
`ssh … claude --resume …` command to your clipboard. For real remote tracking,
switch the hook entries from `"type": "command"` to `"type": "http"` pointed at a
listener on your laptop (over Tailscale or an SSH reverse tunnel) that writes the
identical files.

## Roadmap

- **Sign + notarize + Homebrew cask** — so friends can `brew install --cask`
  without building. Needs an Apple Developer ID; until then, build from source
  (above).
- Global hotkey to cycle sessions needing attention.
- Splitting `working` into "running a tool" vs "thinking", and a decay on `done`.
