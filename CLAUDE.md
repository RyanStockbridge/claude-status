# CLAUDE.md — claude-status

A macOS menu bar readout of every running Claude Code session. Working and in
daily use at v0.1.2. See `README.md` for user-facing docs.

## Architecture

Two halves that talk only through a directory of JSON files. Keep it that way —
it's what let the writer be swapped mid-flight without touching the renderer.

```
Claude Code hooks ──> bin/claude-status-write.sh ──> ~/.claude/status/<sid>.json
                              │                              │
                              └─> bin/claude-status-notify.sh│
                                                             v
                                      swiftbar/claude-status.1s.py (1s poll)
                                                             │
                                                             └─> bin/claude-status-jump.sh
```

* **Writer** — one handler for every hook event, dispatching on `$1` (the state
  name) rather than parsing the payload for it. Atomic write via temp+rename.
  Intended to fire the notifier only when `prev_state != new_state` (wiring
  landing with the notifier — see below).
* **Notifier** — *(in progress, being built now)* reads
  `~/.claude/status/<sid>.json` and `~/.claude/claude-status.json`, delivers via
  `terminal-notifier` (clickable, grouped per session) or falls back to
  `osascript`. Config gating: global off-switch, per-state enable,
  `min_turn_seconds`.
* **Renderer** — SwiftBar plugin. Sweeps records older than 6h, flags `working`
  sessions idle >120s as possibly stalled.
* **Jump** — tmux pane and iTerm session are exact; VS Code is window-only.

States: `idle` `working` `waiting` `blocked` `done` `error` (+ `closed` deletes
the record).

## Hard-won gotchas — do not relearn these

1. SwiftBar's bundle id is `com.ameba.SwiftBar`, not `com.ambrosia`. Writing to
   the wrong domain succeeds silently and does nothing. Cost about an hour.
2. Never assume SwiftBar's plugin folder. Read
   `defaults read com.ameba.SwiftBar PluginDirectory` and fail loudly if unset.
   It also has a separate "repository" concept; the names confuse everyone.
3. jq's `//` treats `false` as absent. `.enabled // true` can never be false.
   Use `if . == null then <default> else . end`. This silently broke both
   notification off-switches.
4. Quarantine blocks SwiftBar plugin execution. A zip from a browser stamps
   every file; the shell will run them but SwiftBar won't.
   `xattr -dr com.apple.quarantine` on the source, not the symlinks.
5. Copy plugins into SwiftBar's folder, don't symlink. Some builds skip
   symlinked plugins.
6. The writer must never fail loudly. Every path exits 0. A broken status writer
   must not disturb a real session.
7. IDE context injection. The VS Code extension prepends
   `<ide_opened_file>…</ide_opened_file>` to the prompt payload. `strip_tags` in
   the writer removes tagged blocks before deriving a session title.
8. Hooks load at session start only. Sessions open before a hook change never
   see it. Always restart when testing.
9. `dash`'s `echo` interprets `\n`. Build test payloads with `jq -n`, not
   `echo`, or you'll get invalid JSON and chase a phantom bug.

## Testing

No test suite yet — worth adding. Existing approach: stub `terminal-notifier`
into PATH so it logs its argv, drive the writer with `jq -n`-built payloads,
assert on the log. Note the writer redirects the notifier to `/dev/null`, so a
stub must log to a file.

Verified so far: state transitions, title derivation through IDE noise,
idempotent `settings.json` merge against a file with pre-existing unrelated
hooks, malformed stdin.

Never verified — no macOS in the authoring environment: all AppleScript,
`open -b`, `lsappinfo`, `pbcopy`, `defaults`, and SwiftBar rendering itself.

## Next up

1. **VS Code tab-level jump** (open question). Currently focuses the window
   holding the project folder; you still pick the tab. There is no URL scheme or
   CLI flag for tab granularity — only an extension can do it.

   First determine what we're targeting:

   ```bash
   jq -s '[.[] | {project, program: .term.program, pid: .agent_pid}]' ~/.claude/status/*.json
   jq -r '.contributes.commands[]?.command' ~/.vscode/extensions/anthropic*/package.json
   ```

   * Integrated terminals → tractable. A `SessionStart` hook emits an OSC 2 title
     (`terminalSequence` in hook JSON output allows OSC 0/1/2) naming the
     terminal `claude·<short-id>`; a companion extension registers
     `vscode://ryan.claude-status/focus?id=…`, finds the terminal by name, calls
     `.show()`. Jump script focuses the window first, then fires the URI.
     Unknowns: whether VS Code surfaces OSC titles in `Terminal.name` (may need
     `terminal.integrated.tabs.title: "${sequence}"`), and whether Claude Code
     overwrites the title itself.
   * Extension chat panel → likely blocked at window level unless the Claude Code
     extension registers a focus command we can call.

2. **Ship to partners.** `.claude-plugin/marketplace.json` is ready;
   `/plugin marketplace add` + `/plugin install` handles the hooks half with no
   file editing. The SwiftBar half still needs a manual `./install.sh`.

3. **Native SwiftUI `MenuBarExtra`.** ~350 lines. FSEvents instead of the 1s
   poll, real badge count, `UNUserNotificationCenter` with actions, global hotkey
   to cycle sessions needing attention. Homebrew cask; sign + notarize (needs the
   $99/yr Apple Developer account) or partners hit Gatekeeper. The hooks half does
   not change — the Swift app reads the identical files, so both can run side by
   side during the rewrite.

4. **Remote sessions.** Sessions on another machine write status files there.
   Switch hook entries from `"type": "command"` to `"type": "http"` pointed at a
   listener reachable over Tailscale or an SSH reverse tunnel; Claude Code POSTs
   the same JSON, listener writes identical files. Relevant for driving the Mac
   Studio from the MacBook.

5. **State model.** Live with it before building the Swift app. Likely wants:
   splitting `working` into "running a tool" vs "thinking", and a decay on `done`
   so an acknowledged session stops counting toward the badge.
