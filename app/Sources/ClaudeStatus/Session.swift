import SwiftUI
import AppKit

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

    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .error:   return NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1)
        case .blocked: return NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1)
        case .waiting: return NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1)
        case .done:    return NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
        case .working: return NSColor(srgbRed: 0.96, green: 0.72, blue: 0.02, alpha: 1)
        case .idle:    return NSColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1)
        }
    }

    /// SF Symbol for the row indicator — conveys the state at a glance without
    /// leaning on emoji.
    var symbol: String {
        switch self {
        case .error:   return "exclamationmark.triangle.fill"
        case .blocked: return "hand.raised.fill"
        case .waiting: return "bubble.left.fill"
        case .done:    return "checkmark.circle.fill"
        case .working: return "circle.fill"
        case .idle:    return "moon.zzz.fill"
        }
    }

    /// Short human label used in the row subtitle and notifications.
    var phrase: String {
        switch self {
        case .error:   return "Error"
        case .blocked: return "Needs your approval"
        case .waiting: return "Waiting for your input"
        case .done:    return "Finished"
        case .working: return "Working"
        case .idle:    return "Idle"
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
