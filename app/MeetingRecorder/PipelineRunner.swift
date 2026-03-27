import Foundation

/// Wraps `Process` (Foundation) calls to `meeting-pipeline.sh`.
///
/// The pipeline script is resolved in order:
/// 1. Inside the app bundle (`Contents/Resources/meeting-pipeline.sh`)
/// 2. Adjacent to the app bundle (same directory)
/// 3. `/usr/local/bin/meeting-pipeline.sh`
class PipelineRunner {

    enum PipelineError: LocalizedError {
        case scriptNotFound
        case executionFailed(exitCode: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .scriptNotFound:
                return "meeting-pipeline.sh not found. Ensure it is in the app bundle or /usr/local/bin/."
            case let .executionFailed(exitCode, stderr):
                return "Pipeline exited with code \(exitCode): \(stderr)"
            }
        }
    }

    private let configManager: ConfigManager

    /// Resolved path to the pipeline shell script.
    private var pipelineScriptPath: String {
        // 1. App bundle resources
        if let bundlePath = Bundle.main.path(forResource: "meeting-pipeline", ofType: "sh") {
            return bundlePath
        }

        // 2. Adjacent to the app bundle
        if let bundleURL = Bundle.main.bundleURL.deletingLastPathComponent() as URL? {
            let adjacent = bundleURL.appendingPathComponent("meeting-pipeline.sh").path
            if FileManager.default.isExecutableFile(atPath: adjacent) {
                return adjacent
            }
        }

        // 3. Common install locations
        let commonPaths = [
            "/usr/local/bin/meeting-pipeline.sh",
            NSString(string: "~/.local/bin/meeting-pipeline.sh").expandingTildeInPath
        ]
        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback — will fail at execution time with a clear error.
        return "/usr/local/bin/meeting-pipeline.sh"
    }

    init(configManager: ConfigManager) {
        self.configManager = configManager
    }

    // MARK: - Public Actions

    /// Start recording. The pipeline's `--action start` exits quickly after
    /// spawning sox, so this runs synchronously.
    func start(source: String, output: String) throws {
        let modelPath = NSString(string: configManager.config.whisperModelPath).expandingTildeInPath
        let language = configManager.config.language

        let args = [
            "--action", "start",
            "--source", source,
            "--output", output,
            "--model-path", modelPath,
            "--language", language
        ]

        let result = try runPipeline(arguments: args)
        if result.exitCode != 0 {
            throw PipelineError.executionFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// Stop recording. The pipeline's `--action stop` waits for sox to
    /// terminate, so this blocks briefly.
    func stop(output: String) throws {
        let args = [
            "--action", "stop",
            "--output", output
        ]

        let result = try runPipeline(arguments: args)
        if result.exitCode != 0 {
            throw PipelineError.executionFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// Run the heavy processing step (ffmpeg + whisper). This can take a long
    /// time — sentinel files are used for progress reporting.
    func process(source: String, output: String) throws {
        let modelPath = NSString(string: configManager.config.whisperModelPath).expandingTildeInPath
        let language = configManager.config.language

        let args = [
            "--action", "process",
            "--source", source,
            "--output", output,
            "--model-path", modelPath,
            "--language", language
        ]

        let result = try runPipeline(arguments: args)
        if result.exitCode != 0 {
            throw PipelineError.executionFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    // MARK: - Process Runner

    /// Execute the pipeline script with the given arguments and capture output.
    private func runPipeline(arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let scriptPath = pipelineScriptPath

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw PipelineError.scriptNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath] + arguments

        // Inherit a minimal environment so that tools like sox, ffmpeg, and
        // whisper-cli can be found on common Homebrew / MacPorts paths.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        if let existing = env["PATH"] {
            env["PATH"] = "\(extraPaths):\(existing)"
        } else {
            env["PATH"] = extraPaths
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Read pipe data before waitUntilExit to avoid deadlock when the
        // pipe buffer fills up. Capture data on background threads.
        var stdoutData = Data()
        var stderrData = Data()

        let stdoutReadGroup = DispatchGroup()
        let stderrReadGroup = DispatchGroup()

        stdoutReadGroup.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutReadGroup.leave()
        }

        stderrReadGroup.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrReadGroup.leave()
        }

        try process.run()
        process.waitUntilExit()

        stdoutReadGroup.wait()
        stderrReadGroup.wait()

        let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

        return (exitCode: process.terminationStatus, stdout: stdoutString, stderr: stderrString)
    }
}
