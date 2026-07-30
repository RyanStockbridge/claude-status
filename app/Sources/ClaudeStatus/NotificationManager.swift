import Foundation
import UserNotifications

/// Native banners when a session needs you (blocked / waiting / error), each
/// with a "Jump to session" action. Fires only on a transition *into* an
/// attention state — SessionStore does the diffing and calls `notify`.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()
    private nonisolated static let categoryId = "SESSION_ATTENTION"
    private nonisolated static let jumpActionId = "JUMP"
    private var authorized = false

    /// Request authorization and register the "Jump" action. Call once at launch.
    func configure() {
        center.delegate = self
        let jump = UNNotificationAction(
            identifier: Self.jumpActionId,
            title: "Jump to session",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryId,
            actions: [jump],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        // Request auth off the main actor (a @MainActor completion handler fired
        // on a background queue traps under Swift 6). The nonisolated helper
        // grabs its own center reference so nothing crosses the actor boundary;
        // the Bool result hops back here to set `authorized`.
        Task { authorized = await Self.requestAuth() }
    }

    private nonisolated static func requestAuth() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do { return try await center.requestAuthorization(options: [.alert, .sound]) }
        catch {
            NSLog("claude-status: notification auth error: \(error.localizedDescription)")
            return false
        }
    }

    func notify(_ session: Session) {
        let content = UNMutableNotificationContent()
        content.title = (session.project?.isEmpty == false) ? session.project! : "Claude Code"
        content.subtitle = session.title ?? ""
        content.body = (session.kind == .error && session.detail?.isEmpty == false)
            ? session.detail!
            : session.kind.phrase
        content.categoryIdentifier = Self.categoryId
        content.userInfo = ["sessionId": session.sessionId]
        content.interruptionLevel = .active
        // A sound only for the states you must act on.
        if session.kind == .blocked || session.kind == .error {
            content.sound = .default
        }
        // Unique per transition (session + when it changed) so each new event
        // alerts fresh — reusing an id makes macOS silently *update* the existing
        // Center entry instead of presenting a new banner.
        let stamp = Int(session.stateSince ?? 0)
        let request = UNNotificationRequest(
            identifier: "attention-\(session.sessionId)-\(stamp)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    // Show the banner even though a menu-bar agent is never "frontmost".
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Tapping the banner (or its Jump action) focuses the session.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let sid = response.notification.request.content.userInfo["sessionId"] as? String
        let action = response.actionIdentifier
        guard let sid,
              action == Self.jumpActionId || action == UNNotificationDefaultActionIdentifier
        else { return }
        Jump.to(sessionId: sid)
    }
}
