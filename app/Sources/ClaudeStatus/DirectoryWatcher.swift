import Foundation

/// Watches a directory and fires `onChange` whenever its contents change.
///
/// The writer publishes every update with an atomic temp-file + rename, so each
/// state change is a rename *within* the status directory — which the directory
/// vnode sees as a `.write`. That makes a single DispatchSource on the directory
/// fd enough; no need for the heavier FSEvents subtree API. Events are debounced
/// since a rename can surface as several vnode notifications.
final class DirectoryWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: CInt = -1
    private var debounce: DispatchWorkItem?
    private let queue = DispatchQueue(label: "claude-status.watcher")

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        stop()
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.schedule() }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fd >= 0 { close(self.fd); self.fd = -1 }
        }
        source = src
        src.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// Coalesce a burst of vnode events into one reload on the main actor.
    private func schedule() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    deinit { stop() }
}
