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
  Fires the notifier only when `prev_state != new_state`, detached so it can
  never stall the session; passes it `<sid> <new_state> <prev_state>
  <prev_state_since>`.
* **Notifier** — reads `~/.claude/status/<sid>.json` and
  `~/.claude/claude-status.json`, delivers via `terminal-notifier` (clickable —
  click jumps to the session, grouped per session) or falls back to `osascript`.
  Config gating: global off-switch, per-state enable (defaults: on for
  `error`/`blocked`/`waiting`/`done`, off for `working`/`idle`),
  `min_turn_seconds` (suppresses a `working`→`done`/`idle` flip whose turn was
  shorter than N seconds). Sound only for `blocked`/`error`.
* **Renderer** — SwiftBar plugin. Sweeps records older than 6h, flags `working`
  sessions idle >120s as possibly stalled.
* **Jump** — routes on `CLAUDE_CODE_ENTRYPOINT` (the launch surface) first, then
  terminal identity. tmux pane and iTerm session are exact; the VS Code
  extension panel is exact via a URI handler; VS Code integrated terminal is
  window-only; the Claude desktop app can only be activated (no per-session
  route yet).

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
hooks, malformed stdin. Notifier: fires only on state change, config gating
(global off, per-state, `min_turn_seconds`), terminal-notifier argv (title,
group, subtitle, `-execute` jump, sound on blocked/error), and osascript
fallback when terminal-notifier is absent — all checked on macOS by stubbing
`terminal-notifier`/`osascript` into PATH.

Never verified — no macOS in the authoring environment: all AppleScript,
`open -b`, `lsappinfo`, `pbcopy`, `defaults`, and SwiftBar rendering itself.

## Next up

1. **Precise jump for the remaining surfaces.** The VS Code *extension panel*
   case is solved (see the Jump bullet): the official `anthropic.claude-code`
   extension registers a URI handler whose `/open?session=<id>` route calls
   `createPanel(id)`, which does `sessionPanels.get(id).reveal()` — and that map
   is keyed by Claude Code's own `session_id`, the same id we record. So
   `open "vscode://anthropic.claude-code/open?session=<sid>"` reveals the exact
   tab, no companion extension needed. Caveat: a session living only in the
   integrated terminal has no panel, so the URI would spawn an empty one — the
   jump only fires it for `entrypoint == claude-vscode`, which is the panel /
   sidebar case. Verified by reading the (minified, fast-updating) bundle, not
   yet confirmed live — recheck if the URI stops working after an update.

   Two surfaces still lack a per-session jump:

   * **Claude desktop app** (`entrypoint == claude-desktop`) — this is the
     surface actually in daily use here. It registers the `claude://` URL scheme
     (`/Applications/Claude.app`), but the route grammar for focusing a specific
     session is unknown. R&D: inspect the Electron app's resources for a deep
     link, or whether it exposes session windows/tabs at all. Until then the jump
     only activates the app.
   * **VS Code integrated terminal** (`entrypoint == cli`, `TERM_PROGRAM=vscode`)
     — still window-only. The old OSC-2-title + companion-extension idea still
     applies here if it turns out to matter: a `SessionStart` hook names the
     terminal `claude·<short-id>` and an extension finds it by name and calls
     `.show()`. Lower priority than the desktop app.

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
