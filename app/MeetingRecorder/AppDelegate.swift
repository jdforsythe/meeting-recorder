import Cocoa

extension Notification.Name {
    static let appReceivedURL = Notification.Name("appReceivedURL")
}

class AppDelegate: NSObject, NSApplicationDelegate {

    /// Handle incoming URLs via the `meetingrecorder://` custom URL scheme.
    ///
    /// `.onOpenURL` is unreliable in LSUIElement (menu-bar-only) apps, so we
    /// use `NSApplicationDelegateAdaptor` and forward every URL through
    /// NotificationCenter so that `AppState` can react.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            // Expected format:
            //   meetingrecorder://start?source=mic&output=/path/to/file.md
            //   meetingrecorder://stop
            NotificationCenter.default.post(name: .appReceivedURL, object: url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register as the handler for our URL scheme in case the system
        // needs an explicit nudge (normally handled by Info.plist).
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor,
                                          withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }
        NotificationCenter.default.post(name: .appReceivedURL, object: url)
    }
}
