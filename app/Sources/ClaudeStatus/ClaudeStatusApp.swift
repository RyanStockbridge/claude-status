import SwiftUI
import AppKit

@main
struct ClaudeStatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = SessionStore.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Agent app: menu bar only, no Dock icon. Also boots notifications and wires
/// the store's attention transitions to them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationManager.shared.configure()
        SessionStore.shared.onNeedsAttention = { session in
            NotificationManager.shared.notify(session)
        }
    }
}

// MARK: - Menu bar icon

/// A colored dot (rendered as a non-template NSImage so it keeps its color in
/// the menu bar) plus an attention count. Priority mirrors the SwiftBar glyph.
struct MenuBarLabel: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        let (color, count) = dominant
        Image(nsImage: Self.dot(color))
        if let count { Text("\(count)") }
    }

    private var dominant: (NSColor, Int?) {
        let c = store.counts
        let errors = c[.error] ?? 0
        let attention = store.attentionCount
        if errors > 0 { return (SessionState.error.nsColor, attention > 0 ? attention : errors) }
        if attention > 0 {
            let s: SessionState = (c[.blocked] ?? 0) > 0 ? .blocked : .waiting
            return (s.nsColor, attention)
        }
        if let done = c[.done], done > 0 { return (SessionState.done.nsColor, done) }
        if (c[.working] ?? 0) > 0 { return (SessionState.working.nsColor, nil) }
        return (SessionState.idle.nsColor, nil)
    }

    static func dot(_ color: NSColor, diameter d: CGFloat = 9) -> NSImage {
        let img = NSImage(size: NSSize(width: d, height: d))
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: d, height: d)).fill()
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}

// MARK: - Popover

struct PopoverView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.sessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(store.groups.enumerated()), id: \.element.project) { _, group in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.project.uppercased())
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                ForEach(group.sessions) { session in
                                    SessionRow(session: session) { jump(session) }
                                }
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 420)
            }
            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("Claude Sessions").font(.system(size: 13, weight: .semibold))
            Spacer()
            if store.attentionCount > 0 {
                Text("\(store.attentionCount) need you")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz.fill").font(.system(size: 22)).foregroundStyle(.tertiary)
            Text("No Claude Code sessions").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let done = store.counts[.done], done > 0 {
                Button("Clear finished (\(done))") { store.clearFinished() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Quit Claude Status")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func jump(_ session: Session) {
        Jump.to(session)
        NSApp.keyWindow?.close()   // dismiss the popover after jumping
    }
}

struct SessionRow: View {
    let session: Session
    let onJump: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onJump) {
            HStack(spacing: 10) {
                StatusIndicator(state: session.kind)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title?.isEmpty == false ? session.title! : "(no prompt yet)")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if hovering {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var subtitle: String {
        let age = Self.ago(session.stateSince)
        switch session.kind {
        case .working:
            let stalled = Date().timeIntervalSince1970 - (session.updatedAt ?? 0) > SessionStore.stallAfter
            if stalled { return "Stalled? · \(age)" }
            if let tool = session.lastTool, !tool.isEmpty { return "\(tool) · \(age)" }
            return "Working · \(age)"
        case .done:  return "Finished \(age) ago"
        case .error: return (session.detail?.isEmpty == false) ? session.detail! : "Error"
        default:     return "\(session.kind.phrase) · \(age)"
        }
    }

    static func ago(_ ts: Double?) -> String {
        let d = max(0, Int(Date().timeIntervalSince1970 - (ts ?? 0)))
        if d < 60 { return "\(d)s" }
        if d < 3600 { return "\(d / 60)m" }
        let h = d / 3600, m = (d % 3600) / 60
        return String(format: "%dh%02dm", h, m)
    }
}

/// A colored status dot; the `working` state gets a soft expanding pulse.
struct StatusIndicator: View {
    let state: SessionState
    @State private var pulse = false

    var body: some View {
        ZStack {
            if state == .working {
                Circle()
                    .fill(state.color.opacity(0.5))
                    .scaleEffect(pulse ? 2.0 : 1.0)
                    .opacity(pulse ? 0 : 0.6)
                    .animation(.easeOut(duration: 1.3).repeatForever(autoreverses: false), value: pulse)
                    .onAppear { pulse = true }
            }
            Image(systemName: state.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(state.color)
        }
        .frame(width: 20, height: 20)
    }
}
