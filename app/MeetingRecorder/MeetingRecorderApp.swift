import SwiftUI

@main
struct MeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            switch appState.state {
            case .idle:
                Image(systemName: "mic.fill")
            case .recording:
                Image(systemName: "record.circle.fill")
                    .symbolRenderingMode(.multicolor)
                    .symbolEffect(.pulse)
            case .processing(let step):
                BrickAnimationMenuBarIcon(tooltip: step.isEmpty ? "Processing audio..." : step)
            case .error(_):
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
