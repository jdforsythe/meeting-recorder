import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            switch appState.state {
            case .idle:
                idleView
            case .recording:
                recordingView
            case .processing:
                processingView
            case .error(let message):
                errorView(message: message)
            }
        }
        .frame(width: 280)
        .padding()
    }

    // MARK: - Idle State

    private var idleView: some View {
        VStack(spacing: 12) {
            Text("Meeting Recorder")
                .font(.headline)

            sourcePickerView

            Button(action: startRecording) {
                Label("Start Recording", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let info = appState.lastRecordingInfo {
                lastRecordingInfoView(info: info)
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
        }
    }

    private var sourcePickerView: some View {
        Picker("Source", selection: $appState.currentSource) {
            Text("Microphone").tag("mic")
            Text("System Audio").tag("system")
            Text("Both").tag("both")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func lastRecordingInfoView(info: RecordingInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()

            Text("Last Recording")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack {
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
                Text(info.timestamp, style: .date)
                    + Text(" ")
                    + Text(info.timestamp, style: .time)
            }
            .font(.caption)

            HStack {
                Image(systemName: "timer")
                    .foregroundColor(.secondary)
                Text(Self.formatDuration(info.duration))
            }
            .font(.caption)

            HStack {
                Image(systemName: "doc")
                    .foregroundColor(.secondary)
                Text(info.outputPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
        }
    }

    // MARK: - Recording State

    private var recordingView: some View {
        VStack(spacing: 12) {
            Text("Recording")
                .font(.headline)
                .foregroundColor(.red)

            Text(Self.formatDuration(appState.elapsedTime))
                .font(.system(.largeTitle, design: .monospaced))
                .foregroundColor(.red)

            Text("Source: \(sourceDisplayName)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button(action: stopRecording) {
                Label("Stop Recording", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
        }
    }

    // MARK: - Processing State

    private var processingView: some View {
        VStack(spacing: 12) {
            Text("Processing audio...")
                .font(.headline)

            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.regular)

            if !appState.currentStep.isEmpty {
                Text(appState.currentStep)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Error State

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.yellow)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Dismiss") {
                appState.state = .idle
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Actions

    private func startRecording() {
        let output = appState.currentOutputPath ?? defaultOutputPath()
        appState.startRecording(source: appState.currentSource, output: output)
    }

    private func stopRecording() {
        appState.stopRecording()
    }

    // MARK: - Helpers

    private var sourceDisplayName: String {
        switch appState.currentSource {
        case "mic": return "Microphone"
        case "system": return "System Audio"
        case "both": return "Both"
        default: return appState.currentSource
        }
    }

    private func defaultOutputPath() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH-mm"
        let timestamp = dateFormatter.string(from: Date())
        let dir = NSString("~/Documents/meeting-transcripts").expandingTildeInPath
        return "\(dir)/\(timestamp)-meeting.md"
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
