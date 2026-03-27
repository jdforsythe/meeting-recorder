import SwiftUI
import Combine

// MARK: - Shared Contracts (interface for UI layer)

enum RecordingState: Equatable {
    case idle
    case recording
    case processing(step: String)
    case error(message: String)
}

enum AudioSource: String, CaseIterable, Identifiable {
    case mic = "mic"
    case system = "system"
    case both = "both"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .mic: return "Microphone"
        case .system: return "System Audio"
        case .both: return "Both"
        }
    }
}

// MARK: - AppState

@MainActor
class AppState: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var selectedSource: AudioSource = .mic
    @Published var currentOutputPath: String?
    @Published var recordingStartTime: Date?
    @Published var lastRecordingInfo: LastRecordingInfo?

    /// Computed elapsed time since recording started (for UI display).
    var elapsedTime: TimeInterval {
        guard let start = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    /// Computed current processing step (extracted from state enum).
    var currentStep: String {
        if case .processing(let step) = state { return step }
        return ""
    }

    private var pipelineRunner: PipelineRunner
    private var configManager: ConfigManager
    private var cancellables = Set<AnyCancellable>()
    private var sentinelTimer: AnyCancellable?
    private var elapsedTimeTimer: AnyCancellable?

    struct LastRecordingInfo {
        let outputPath: String
        let timestamp: Date
        let duration: TimeInterval?
    }

    init() {
        self.configManager = ConfigManager()
        self.pipelineRunner = PipelineRunner(configManager: configManager)

        // Apply default source from config
        if let defaultSource = AudioSource(rawValue: configManager.config.defaultSource) {
            self.selectedSource = defaultSource
        }

        setupURLHandler()
    }

    // MARK: - Recording Lifecycle

    func startRecording(source: AudioSource, outputPath: String?) {
        guard case .idle = state else {
            // Already recording or processing — reject silently.
            return
        }

        let output = outputPath ?? generateDefaultOutputPath()

        // Run preflight asynchronously, then start the pipeline.
        Task { [weak self] in
            guard let self else { return }

            let preflight = await PreflightChecker.check(source: source)
            guard preflight.canProceed else {
                let issues = preflight.issues.joined(separator: "; ")
                self.handleError(message: "Preflight failed: \(issues)")
                return
            }

            do {
                try self.pipelineRunner.start(source: source.rawValue, output: output)
                self.state = .recording
                self.currentOutputPath = output
                self.recordingStartTime = Date()
                self.startElapsedTimeTimer()
                NotificationManager.shared.sendRecordingStarted()
            } catch {
                self.handleError(message: "Failed to start recording: \(error.localizedDescription)")
            }
        }
    }

    func stopRecording() {
        guard case .recording = state else { return }
        guard let output = currentOutputPath else {
            handleError(message: "No output path set for current recording.")
            return
        }

        let source = selectedSource.rawValue

        elapsedTimeTimer?.cancel()
        elapsedTimeTimer = nil
        state = .processing(step: "audio_stopped")

        Task.detached { [weak self] in
            guard let self else { return }

            do {
                try self.pipelineRunner.stop(output: output)
            } catch {
                await MainActor.run {
                    self.handleError(message: "Failed to stop recording: \(error.localizedDescription)")
                }
                return
            }

            // Begin polling sentinel files for progress updates (on the main actor).
            await MainActor.run {
                self.startPolling()
            }

            // Kick off the heavy processing (ffmpeg + whisper) off the main actor.
            do {
                try self.pipelineRunner.process(source: source, output: output)
            } catch {
                await MainActor.run {
                    self.handleError(message: "Processing failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Completion Handlers

    func handleProcessingComplete() {
        sentinelTimer?.cancel()
        sentinelTimer = nil
        elapsedTimeTimer?.cancel()
        elapsedTimeTimer = nil

        let duration: TimeInterval? = {
            guard let start = recordingStartTime else { return nil }
            return Date().timeIntervalSince(start)
        }()

        if let output = currentOutputPath {
            lastRecordingInfo = LastRecordingInfo(
                outputPath: output,
                timestamp: Date(),
                duration: duration
            )
            let filename = (output as NSString).lastPathComponent
            NotificationManager.shared.sendTranscriptReady(filename: filename)
        }

        state = .idle
        currentOutputPath = nil
        recordingStartTime = nil
    }

    func handleError(message: String) {
        sentinelTimer?.cancel()
        sentinelTimer = nil
        elapsedTimeTimer?.cancel()
        elapsedTimeTimer = nil

        NotificationManager.shared.sendError(message: message)
        state = .error(message: message)

        // Auto-recover to idle after 5 seconds.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self else { return }
            if case .error = self.state {
                self.state = .idle
                self.currentOutputPath = nil
                self.recordingStartTime = nil
            }
        }
    }

    // MARK: - URL Scheme Handler

    private func setupURLHandler() {
        NotificationCenter.default.publisher(for: .appReceivedURL)
            .compactMap { $0.object as? URL }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                self?.handleIncomingURL(url)
            }
            .store(in: &cancellables)
    }

    private func handleIncomingURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        let host = components.host ?? ""
        let queryItems = components.queryItems ?? []

        switch host {
        case "start":
            guard case .idle = state else { return }

            let sourceString = queryItems.first(where: { $0.name == "source" })?.value ?? selectedSource.rawValue
            let source = AudioSource(rawValue: sourceString) ?? selectedSource
            let output = queryItems.first(where: { $0.name == "output" })?.value

            startRecording(source: source, outputPath: output)

        case "stop":
            stopRecording()

        default:
            break
        }
    }

    // MARK: - Elapsed Time Timer

    /// Publishes every second to drive the elapsed time display in the UI.
    private func startElapsedTimeTimer() {
        elapsedTimeTimer?.cancel()
        elapsedTimeTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                // Trigger a SwiftUI redraw by nudging objectWillChange.
                // The computed `elapsedTime` property reads `recordingStartTime`
                // which doesn't change, but `objectWillChange` forces the view
                // to re-evaluate the computed property.
                self?.objectWillChange.send()
            }
    }

    // MARK: - Sentinel File Polling

    private func startPolling() {
        sentinelTimer?.cancel()

        sentinelTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.pollSentinels()
            }
    }

    private func pollSentinels() {
        guard let output = currentOutputPath else { return }
        let fm = FileManager.default

        // Check for .error sentinel first (highest priority).
        let errorPath = output + ".error"
        if fm.fileExists(atPath: errorPath) {
            if let data = fm.contents(atPath: errorPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let step = json["step"] as? String ?? "unknown"
                let exitCode = json["exit_code"] as? Int ?? -1
                let stderr = json["stderr"] as? String ?? ""
                handleError(message: "Pipeline error at \(step) (exit \(exitCode)): \(stderr)")
            } else {
                handleError(message: "Pipeline failed (could not parse error details).")
            }
            return
        }

        // Check for .done sentinel (processing complete).
        let donePath = output + ".done"
        if fm.fileExists(atPath: donePath) {
            handleProcessingComplete()
            return
        }

        // Check for .processing sentinel (step update).
        let processingPath = output + ".processing"
        if fm.fileExists(atPath: processingPath),
           let data = fm.contents(atPath: processingPath),
           let stepName = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stepName.isEmpty {
            state = .processing(step: stepName)
        }
    }

    // MARK: - Helpers

    private func generateDefaultOutputPath() -> String {
        let outputDir = NSString(string: configManager.config.defaultOutputDir).expandingTildeInPath
        let fm = FileManager.default

        // Ensure output directory exists.
        if !fm.fileExists(atPath: outputDir) {
            try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        }

        // Match MCP server format: {timestamp}-meeting.md
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm"
        let timestamp = formatter.string(from: Date())

        return (outputDir as NSString).appendingPathComponent("\(timestamp)-meeting.md")
    }
}
