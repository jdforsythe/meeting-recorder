import UserNotifications

/// Wraps `UNUserNotificationCenter` for macOS notifications.
///
/// Usage:
///     NotificationManager.shared.requestAuthorization()
///     NotificationManager.shared.sendRecordingStarted()
///     NotificationManager.shared.sendTranscriptReady(filename: "2026-03-25-standup.md")
///     NotificationManager.shared.sendError(message: "sox process crashed")
class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    /// Request notification authorization. Call once at app launch
    /// (also handled in AppDelegate.applicationDidFinishLaunching).
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Notify the user that recording has started.
    func sendRecordingStarted() {
        send(title: "Meeting Recorder", body: "Recording started")
    }

    /// Notify the user that a transcript is ready.
    /// - Parameter filename: The output filename (not the full path) to display.
    func sendTranscriptReady(filename: String) {
        send(title: "Meeting Recorder", body: "Transcript ready: \(filename)")
    }

    /// Notify the user of an error.
    /// - Parameter message: A human-readable error description.
    func sendError(message: String) {
        send(title: "Meeting Recorder", body: "Error: \(message)")
    }

    // MARK: - Private

    private func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // Deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }
}
