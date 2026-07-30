import Foundation

/// Runs the shared bin/claude-status-jump.sh so the native app and the SwiftBar
/// plugin focus sessions through the exact same logic (tmux / iTerm / VS Code
/// panel / Claude desktop / …). We locate the script rather than reimplement it.
enum Jump {
    /// First hit wins:
    ///   1. $CLAUDE_STATUS_JUMP                       (explicit override)
    ///   2. Contents/Resources/claude-status-jump.sh   (bundled in the .app)
    ///   3. next to the executable                     (CLI / dev binary)
    ///   4. the SwiftBar plugin copy                   (existing install)
    ///   5. the dev checkout                           (running from source)
    static func scriptPath() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["CLAUDE_STATUS_JUMP"] {
            candidates.append(env)
        }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("claude-status-jump.sh").path)
        }
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exe.appendingPathComponent("claude-status-jump.sh").path)
        }
        let home = fm.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent("Documents/swiftbar-repository/claude-status-jump.sh").path)
        candidates.append(home.appendingPathComponent("claude-status/bin/claude-status-jump.sh").path)
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    static func to(_ session: Session) {
        guard let path = scriptPath() else {
            NSLog("claude-status: no claude-status-jump.sh found on any known path")
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [path, session.sessionId]
        do { try proc.run() } catch {
            NSLog("claude-status: jump failed: \(error.localizedDescription)")
        }
    }
}
