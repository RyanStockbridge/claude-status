import SwiftUI

@main
struct ClaudeStatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = SessionStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            Text(menuBarTitle)
        }
    }

    /// Menu-bar glyph, in priority order (mirrors the SwiftBar renderer):
    ///   🔴 n  something errored
    ///   🟠/🔵 n  needs you (permission / prompt)
    ///   🟢 n  finished, unacknowledged
    ///   🟡    working
    ///   ⚪️    idle / nothing
    private var menuBarTitle: String {
        let c = store.counts
        let errors = c[.error] ?? 0
        let attention = store.attentionCount
        if errors > 0 { return "🔴 \(attention > 0 ? attention : errors)" }
        if attention > 0 {
            let glyph = (c[.blocked] ?? 0) > 0 ? "🟠" : "🔵"
            return "\(glyph) \(attention)"
        }
        if let done = c[.done], done > 0 { return "🟢 \(done)" }
        if let working = c[.working], working > 0 { return "🟡" }
        return "⚪️"
    }
}

/// Agent app: live in the menu bar only, no dock icon or app menu.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuContent: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        if store.sessions.isEmpty {
            Text("No Claude Code sessions")
        } else {
            ForEach(Array(store.groups.enumerated()), id: \.element.project) { index, group in
                if index > 0 { Divider() }
                Section(group.project) {
                    ForEach(group.sessions) { session in
                        Button {
                            Jump.to(session)
                        } label: {
                            Text("\(session.kind.glyph)  \(rowLabel(session))")
                        }
                    }
                }
            }
        }

        Divider()
        if let done = store.counts[.done], done > 0 {
            Button("Clear finished (\(done))") { store.clearFinished() }
        }
        Button("Refresh") { store.reload() }
        Button("Quit Claude Status") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// "<title> — <status> <age>", matching the SwiftBar row.
    private func rowLabel(_ s: Session) -> String {
        let title = (s.title?.isEmpty == false) ? s.title! : "(no prompt yet)"
        let age = ago(s.stateSince)
        let suffix: String
        switch s.kind {
        case .working:
            let stalled = Date().timeIntervalSince1970 - (s.updatedAt ?? 0) > SessionStore.stallAfter
            if stalled { suffix = "stalled? \(age)" }
            else if let tool = s.lastTool, !tool.isEmpty { suffix = "\(tool) \(age)" }
            else { suffix = age }
        case .blocked: suffix = "needs approval \(age)"
        case .waiting: suffix = "waiting \(age)"
        case .done:    suffix = "done \(age) ago"
        case .error:   suffix = (s.detail?.isEmpty == false) ? s.detail! : "error"
        case .idle:    suffix = "idle \(age)"
        }
        return "\(title)  —  \(suffix)"
    }

    private func ago(_ ts: Double?) -> String {
        let d = max(0, Int(Date().timeIntervalSince1970 - (ts ?? 0)))
        if d < 60 { return "\(d)s" }
        if d < 3600 { return "\(d / 60)m" }
        let h = d / 3600, m = (d % 3600) / 60
        return String(format: "%dh%02dm", h, m)
    }
}
