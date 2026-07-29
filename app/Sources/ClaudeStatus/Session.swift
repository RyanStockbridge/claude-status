import SwiftUI

/// One live Claude Code session, decoded from ~/.claude/status/<sid>.json.
/// Mirrors the record written by bin/claude-status-write.sh. Extra keys in the
/// file (term{}, permission_mode, …) are ignored — the jump script reads the
/// file itself for those, so the app only decodes what it renders.
struct Session: Identifiable, Decodable {
    let sessionId: String
    let state: String
    let stateSince: Double?
    let updatedAt: Double?
    let project: String?
    let title: String?
    let lastTool: String?
    let detail: String?
    let host: String?
    let agentPid: Int?
    let cwd: String?

    var id: String { sessionId }

    var kind: SessionState { SessionState(rawValue: state) ?? .idle }
}

/// The six states, with the same glyphs / colors / attention ranking the
/// SwiftBar renderer uses, so both frontends read identically.
enum SessionState: String, CaseIterable {
    case error, blocked, waiting, done, working, idle

    /// Colored emoji — renders in color in the menu bar (unlike a template
    /// SF Symbol) and matches the SwiftBar dots.
    var glyph: String {
        switch self {
        case .error:   return "🔴"
        case .blocked: return "🟠"
        case .waiting: return "🔵"
        case .done:    return "🟢"
        case .working: return "🟡"
        case .idle:    return "⚪️"
        }
    }

    var color: Color {
        switch self {
        case .error:   return Color(red: 1.00, green: 0.37, blue: 0.34)
        case .blocked: return Color(red: 1.00, green: 0.62, blue: 0.04)
        case .waiting: return Color(red: 0.04, green: 0.52, blue: 1.00)
        case .done:    return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .working: return Color(red: 1.00, green: 0.84, blue: 0.04)
        case .idle:    return Color(red: 0.56, green: 0.56, blue: 0.58)
        }
    }

    /// Higher wins for the menu-bar glyph and the attention-first sort.
    var rank: Int {
        switch self {
        case .error:   return 5
        case .blocked: return 4
        case .waiting: return 3
        case .done:    return 2
        case .working: return 1
        case .idle:    return 0
        }
    }

    /// The states that count toward the badge / draw the eye.
    static let attention: Set<SessionState> = [.error, .blocked, .waiting]
}
