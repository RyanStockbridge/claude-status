import Foundation
import ServiceManagement

/// Launch-at-login via ServiceManagement (macOS 13+). Registers the app itself
/// as a login item; the user can also manage it in System Settings → Login Items.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns the resulting enabled state (unchanged on failure).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("claude-status: login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        return isEnabled
    }
}
