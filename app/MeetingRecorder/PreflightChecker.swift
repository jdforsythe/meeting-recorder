import Foundation
import AVFoundation

/// Result of a preflight check run before recording starts.
struct PreflightResult {
    var micPermissionGranted: Bool
    var requiredToolsAvailable: Bool  // sox, ffmpeg, whisper-cli
    var audioDeviceAvailable: Bool
    var diskSpaceSufficient: Bool     // > 500 MB free
    var missingTools: [String]
    var issues: [String]

    var canProceed: Bool {
        micPermissionGranted && requiredToolsAvailable && audioDeviceAvailable && diskSpaceSufficient
    }
}

/// Validates system prerequisites before a recording session begins.
class PreflightChecker {

    /// Required command-line tools that must be reachable via `$PATH`.
    private static let requiredTools = ["sox", "ffmpeg", "whisper-cli"]

    /// Minimum free disk space in bytes (500 MB).
    private static let minimumDiskSpace: Int64 = 500 * 1024 * 1024

    // MARK: - Public API

    /// Run all preflight checks for the given audio source.
    static func check(source: AudioSource) async -> PreflightResult {
        var result = PreflightResult(
            micPermissionGranted: true,
            requiredToolsAvailable: true,
            audioDeviceAvailable: true,
            diskSpaceSufficient: true,
            missingTools: [],
            issues: []
        )

        // 1. Microphone permission (only needed for mic or both).
        if source == .mic || source == .both {
            let micStatus = checkMicPermission()
            if !micStatus {
                result.micPermissionGranted = false
                result.issues.append("Microphone permission not granted. Open System Settings > Privacy & Security > Microphone.")
            }
        }

        // 2. Required command-line tools.
        let missing = checkRequiredTools()
        if !missing.isEmpty {
            result.requiredToolsAvailable = false
            result.missingTools = missing
            result.issues.append("Missing tools: \(missing.joined(separator: ", ")). Install via Homebrew.")
        }

        // 3. Audio device availability.
        let deviceOK = checkAudioDevice(source: source)
        if !deviceOK {
            result.audioDeviceAvailable = false
            result.issues.append("Required audio device not available for source '\(source.rawValue)'.")
        }

        // 4. Disk space.
        let spaceOK = checkDiskSpace()
        if !spaceOK {
            result.diskSpaceSufficient = false
            result.issues.append("Insufficient disk space. At least 500 MB free is required.")
        }

        return result
    }

    /// Request microphone access from the user. Returns `true` if granted.
    static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Individual Checks

    /// Check current microphone authorization status without prompting.
    private static func checkMicPermission() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .authorized
    }

    /// Return the list of required tools that are NOT found on `$PATH`.
    private static func checkRequiredTools() -> [String] {
        var missing: [String] = []
        for tool in requiredTools {
            if !isToolAvailable(tool) {
                missing.append(tool)
            }
        }
        return missing
    }

    /// Use `which` to test whether a command-line tool is reachable.
    private static func isToolAvailable(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]

        // Extend PATH so we find Homebrew-installed tools.
        var env = ProcessInfo.processInfo.environment
        let extra = "/usr/local/bin:/opt/homebrew/bin"
        if let existing = env["PATH"] {
            env["PATH"] = "\(extra):\(existing)"
        } else {
            env["PATH"] = extra
        }
        process.environment = env

        let devNull = FileHandle.nullDevice
        process.standardOutput = devNull
        process.standardError = devNull

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Verify that the system has an audio input device appropriate for the
    /// requested source.
    ///
    /// For `.mic` we check that at least one audio capture device is available.
    /// For `.system` we verify that "BlackHole 2ch" (or the configured system
    /// device) is present. For `.both` we check both conditions.
    private static func checkAudioDevice(source: AudioSource) -> Bool {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        let deviceNames = session.devices.map { $0.localizedName }

        switch source {
        case .mic:
            return !session.devices.isEmpty

        case .system:
            let systemDevice = ConfigManager().config.systemDevice
            return deviceNames.contains(where: { $0.contains(systemDevice) })

        case .both:
            let hasMic = !session.devices.isEmpty
            let systemDevice = ConfigManager().config.systemDevice
            let hasSystem = deviceNames.contains(where: { $0.contains(systemDevice) })
            return hasMic && hasSystem
        }
    }

    /// Check that the boot volume has at least 500 MB free.
    private static func checkDiskSpace() -> Bool {
        let fm = FileManager.default
        do {
            let attrs = try fm.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let freeSize = attrs[.systemFreeSize] as? Int64 {
                return freeSize >= minimumDiskSpace
            }
        } catch {
            // If we cannot determine free space, assume it is fine and let
            // the pipeline itself fail if disk runs out.
        }
        return true
    }
}
