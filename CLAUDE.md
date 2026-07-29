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
  extension panel is exact via the extension's URI handler
  (`vscode://anthropic.claude-code/open?session=<id>`); the Claude desktop app is
  exact via its own handler (`claude://resume?session=<id>`, verified live); VS
  Code integrated terminal stays window-only.

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

1. **Precise jump per surface** — the two surfaces in daily use here are done,
   both piggybacking on handlers the apps already register (no companion
   extension), keyed on Claude Code's own `session_id`:

   * **Claude desktop app** (`entrypoint == claude-desktop`) — **done, verified
     live.** The app's `claude://` handler (in `Claude.app/.../app.asar`) has a
     top-level `switch(i.host)` with a `resume` host:
     `claude://resume?session=<id>` → `importCliSession(id)` (id is the CLI
     session id = our `session_id`) → opens that conversation and focuses the
     app. Dead ends found on the way, in case a future version moves things:
     host `claude.ai` `/chat/<uuid>` is claude.ai *web* conversations (a
     different id space, 404s on a CLI id); host `code` only matches `/new` plus
     a route-matcher (`uhe`/`fkn`) and rejects everything else silently (the
     window won't even focus). The `resume` route is not behind the
     `code`-host's `At("2143883161")` feature gate.
   * **VS Code extension panel** (`entrypoint == claude-vscode`) — **done,
     verified live.** The official `anthropic.claude-code` extension registers a
     URI handler whose `/open?session=<id>` route calls `createPanel(id)` →
     `sessionPanels.get(id).reveal()`, and that map is keyed by our `session_id`.
     So `open "vscode://anthropic.claude-code/open?session=<sid>"` reveals the
     exact tab. The jump first activates the VS Code app (the URI alone doesn't
     reliably raise the window), then fires the URI. First jump shows a one-time
     VS Code consent ("Allow 'Claude Code for VS Code' to open this URI?" → "Do
     not ask again for this extension"). Caveat: a session living only in the
     integrated terminal has no panel, so the URI would spawn an empty one — the
     jump only fires it for this entrypoint (panel / sidebar). The bundle is
     minified and auto-updates often; recheck if a jump breaks after an update.

   Remaining, low priority (not used here): **VS Code integrated terminal**
   (`entrypoint == cli`, `TERM_PROGRAM=vscode`) — still window-only. The old
   OSC-2-title + companion-extension idea applies if it ever matters: a
   `SessionStart` hook names the terminal `claude·<short-id>` and an extension
   finds it by name and calls `.show()`.

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
