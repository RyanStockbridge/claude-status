import SwiftUI
import Combine

/// Loads and watches ~/.claude/status/*.json and publishes the current set of
/// sessions, grouped and sorted the way the menu renders them.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    /// A crashed session never fires SessionEnd; sweep records this stale.
    private let staleAfter: TimeInterval = 6 * 60 * 60
    /// A `working` session with no update for this long is probably wedged.
    static let stallAfter: TimeInterval = 120

    let dir: URL
    private var watcher: DirectoryWatcher?
    private var tick: Timer?

    init(dir: URL = SessionStore.defaultDir) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reload()
        watcher = DirectoryWatcher(url: dir) { [weak self] in self?.reload() }
        watcher?.start()
        // File events cover content changes; this slow tick only refreshes the
        // relative-time labels ("3m ago") and stall detection.
        tick = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    static var defaultDir: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_STATUS_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/status")
    }

    func reload() {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            sessions = []
            return
        }
        let now = Date().timeIntervalSince1970
        var loaded: [Session] = []
        for name in names where name.hasSuffix(".json") {
            let path = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: path),
                  let s = try? decoder.decode(Session.self, from: data) else { continue }
            if now - (s.updatedAt ?? 0) > staleAfter {
                try? fm.removeItem(at: path)   // sweep dead records
                continue
            }
            loaded.append(s)
        }
        sessions = loaded
    }

    // MARK: derived views

    var counts: [SessionState: Int] {
        Dictionary(grouping: sessions, by: \.kind).mapValues(\.count)
    }

    /// error + blocked + waiting — what the badge counts.
    var attentionCount: Int {
        SessionState.attention.reduce(0) { $0 + (counts[$1] ?? 0) }
    }

    /// Sessions grouped by project, attention-first then most-recently-changed,
    /// ready for the menu.
    var groups: [(project: String, sessions: [Session])] {
        let sorted = sessions.sorted {
            if $0.kind.rank != $1.kind.rank { return $0.kind.rank > $1.kind.rank }
            return ($0.stateSince ?? 0) > ($1.stateSince ?? 0)
        }
        var order: [String] = []
        var byProject: [String: [Session]] = [:]
        for s in sorted {
            let key = (s.project?.isEmpty == false ? s.project! : "(unknown)")
            if byProject[key] == nil { order.append(key) }
            byProject[key, default: []].append(s)
        }
        return order.map { ($0, byProject[$0] ?? []) }
    }

    func clearFinished() {
        let fm = FileManager.default
        for s in sessions where s.kind == .done {
            try? fm.removeItem(at: dir.appendingPathComponent("\(s.sessionId).json"))
        }
        reload()
    }

    func dismiss(_ s: Session) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(s.sessionId).json"))
        reload()
    }
}
