#!/usr/bin/env python3
# <bitbar.title>Claude Status</bitbar.title>
# <bitbar.version>v0.1.0</bitbar.version>
# <bitbar.author>Ryan</bitbar.author>
# <bitbar.desc>Live status of every Claude Code session, grouped by project.</bitbar.desc>
# <bitbar.dependencies>python3</bitbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
"""
Reads ~/.claude/status/*.json (written by the claude-status hooks) and renders
a SwiftBar menu.

Menu bar glyph, in priority order:
    !  n   one or more sessions errored
    *  n   one or more sessions need you (permission prompt or idle)
    v  n   one or more sessions finished and you haven't looked yet
    o      something is working
    .      nothing running

Click a session to jump to its terminal / editor window.
"""

import json
import os
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
STATUS_DIR = os.environ.get("CLAUDE_STATUS_DIR", os.path.join(HOME, ".claude", "status"))
SELF = os.environ.get("SWIFTBAR_PLUGIN_PATH", os.path.abspath(__file__))
JUMP = os.path.join(os.path.dirname(SELF), "claude-status-jump.sh")
if not os.path.exists(JUMP):  # dev layout: swiftbar/ next to bin/
    JUMP = os.path.abspath(
        os.path.join(os.path.dirname(SELF), "..", "bin", "claude-status-jump.sh")
    )

# How long a session may sit untouched before we consider it dead and sweep it.
STALE_AFTER = 6 * 60 * 60
# A "working" session with no tool activity for this long is probably wedged.
STALL_AFTER = 120

STATES = {
    #  key        glyph  color      menu bar rank (higher wins)
    "error":   ("\U0001F534", "#ff5f56", 5),   # red
    "blocked": ("\U0001F7E0", "#ff9f0a", 4),   # orange  - needs permission
    "waiting": ("\U0001F535", "#0a84ff", 3),   # blue    - needs a prompt
    "done":    ("\U0001F7E2", "#30d158", 2),   # green
    "working": ("\U0001F7E1", "#ffd60a", 1),   # yellow
    "idle":    ("\u26AA", "#8e8e93", 0),       # white
}
ATTENTION = ("error", "blocked", "waiting", "done")


def esc(text):
    """SwiftBar treats | as the param separator and \n as a row break."""
    if text is None:
        return ""
    return str(text).replace("|", "\u00a6").replace("\n", " ").strip()


def ago(ts):
    d = max(0, int(time.time() - (ts or 0)))
    if d < 60:
        return "%ds" % d
    if d < 3600:
        return "%dm" % (d // 60)
    h, m = divmod(d // 60, 60)
    return "%dh%02dm" % (h, m)


def load():
    sessions = []
    now = time.time()
    try:
        names = os.listdir(STATUS_DIR)
    except OSError:
        return sessions
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(STATUS_DIR, name)
        try:
            with open(path) as fh:
                s = json.load(fh)
        except (OSError, ValueError):
            continue
        if now - s.get("updated_at", 0) > STALE_AFTER:
            try:
                os.remove(path)
            except OSError:
                pass
            continue
        s["_path"] = path
        sessions.append(s)
    return sessions


def alive(s):
    """Best-effort liveness check; only meaningful on the local host."""
    if s.get("host") != os.uname().nodename.split(".")[0]:
        return True
    pid = s.get("agent_pid")
    if not pid:
        return True
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def label(s):
    state = s.get("state", "idle")
    title = esc(s.get("title")) or "(no prompt yet)"
    age = ago(s.get("state_since"))
    if state == "working":
        stalled = time.time() - s.get("updated_at", 0) > STALL_AFTER
        tool = s.get("last_tool")
        suffix = "stalled? %s" % age if stalled else (
            "%s %s" % (tool, age) if tool else age
        )
    elif state == "blocked":
        suffix = "needs approval %s" % age
    elif state == "waiting":
        suffix = "waiting %s" % age
    elif state == "done":
        suffix = "done %s ago" % age
    elif state == "error":
        suffix = "%s" % (esc(s.get("detail")) or "error")
    else:
        suffix = "idle %s" % age
    return "%s  \u2014 %s" % (title, suffix)


def action(*args):
    """Build SwiftBar params that run this script with arguments."""
    parts = ['bash="%s"' % SELF]
    for i, a in enumerate(args, start=1):
        parts.append('param%d="%s"' % (i, a))
    parts.append("terminal=false refresh=true")
    return " ".join(parts)


def jump_action(sid):
    return 'bash="%s" param1="%s" terminal=false refresh=true' % (JUMP, sid)


def render():
    sessions = load()
    counts = {k: 0 for k in STATES}
    for s in sessions:
        counts[s.get("state", "idle")] = counts.get(s.get("state", "idle"), 0) + 1

    # --- menu bar title ---
    attention = sum(counts.get(k, 0) for k in ("error", "blocked", "waiting"))
    if counts.get("error"):
        print("! %d | color=%s" % (attention or counts["error"], STATES["error"][1]))
    elif attention:
        color = STATES["blocked"][1] if counts.get("blocked") else STATES["waiting"][1]
        print("\u2022 %d | color=%s" % (attention, color))
    elif counts.get("done"):
        print("\u2713 %d | color=%s" % (counts["done"], STATES["done"][1]))
    elif counts.get("working"):
        print("\u25CF | color=%s" % STATES["working"][1])
    else:
        print("\u25CB | color=#8e8e93")

    print("---")

    if not sessions:
        print("No Claude Code sessions | color=#8e8e93")
    else:
        # attention first, then most-recently-changed
        sessions.sort(
            key=lambda s: (
                -STATES.get(s.get("state", "idle"), ("", "", 0))[2],
                -(s.get("state_since") or 0),
            )
        )
        by_project = {}
        for s in sessions:
            by_project.setdefault(s.get("project") or "(unknown)", []).append(s)

        first = True
        for project, group in by_project.items():
            if not first:
                print("---")
            first = False
            host = group[0].get("host", "")
            header = esc(project)
            if host and host != os.uname().nodename.split(".")[0]:
                header += "  @%s" % esc(host)
            print("%s | size=11 color=#8e8e93" % header)

            for s in group:
                state = s.get("state", "idle")
                glyph, color, _ = STATES.get(state, STATES["idle"])
                dead = not alive(s)
                row = "%s %s" % (glyph, label(s))
                if dead:
                    row += "  (gone)"
                print("%s | %s color=%s" % (esc(row), jump_action(s["session_id"]), color))

                # submenu
                print("-- Jump to session | %s" % jump_action(s["session_id"]))
                print(
                    '-- Copy resume command | %s'
                    % action("copy-resume", s["session_id"])
                )
                if s.get("detail"):
                    print("-- %s | color=#8e8e93 size=11" % esc(s["detail"]))
                print("-- Reveal folder | bash=\"/usr/bin/open\" param1=\"%s\" terminal=false"
                      % esc(s.get("cwd", "")))
                print("-- Dismiss | %s" % action("dismiss", s["session_id"]))

    print("---")
    if counts.get("done"):
        print("Clear finished (%d) | %s" % (counts["done"], action("clear-done")))
    print("Open status folder | bash=\"/usr/bin/open\" param1=\"%s\" terminal=false" % STATUS_DIR)
    print("Refresh | refresh=true")


# --- click handlers ---------------------------------------------------------

def handle(cmd, arg=None):
    if cmd == "dismiss" and arg:
        try:
            os.remove(os.path.join(STATUS_DIR, "%s.json" % arg))
        except OSError:
            pass
    elif cmd == "clear-done":
        for s in load():
            if s.get("state") == "done":
                try:
                    os.remove(s["_path"])
                except OSError:
                    pass
    elif cmd == "copy-resume" and arg:
        for s in load():
            if s.get("session_id") == arg:
                cmdline = 'cd %s && claude --resume %s' % (s.get("cwd", ""), arg)
                if s.get("host") != os.uname().nodename.split(".")[0]:
                    cmdline = 'ssh %s -t "%s"' % (s.get("host"), cmdline)
                p = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
                p.communicate(cmdline.encode())
                break


if __name__ == "__main__":
    if len(sys.argv) > 1:
        handle(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
    else:
        render()
