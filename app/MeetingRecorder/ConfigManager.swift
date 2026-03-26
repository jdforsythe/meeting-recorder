import Foundation

/// Manages the app's JSON configuration file at
/// `~/.config/meeting-recorder/config.json`.
///
/// If the file does not exist or cannot be parsed, sensible defaults matching
/// the shared contract are used.
class ConfigManager {

    private static let configPath: String = NSString(
        string: "~/.config/meeting-recorder/config.json"
    ).expandingTildeInPath

    struct Config: Codable {
        var micDevice: String
        var systemDevice: String
        var whisperModelPath: String
        var language: String
        var defaultOutputDir: String
        var defaultSource: String

        static let `default` = Config(
            micDevice: "MacBook Pro Microphone",
            systemDevice: "BlackHole 2ch",
            whisperModelPath: "~/models/ggml-large-v3-turbo-q5_0.bin",
            language: "en",
            defaultOutputDir: "~/Documents/meeting-transcripts/",
            defaultSource: "mic"
        )
    }

    private(set) var config: Config

    init() {
        self.config = Config.default
        reload()
    }

    /// Reload configuration from disk. If the file is missing or malformed,
    /// the current (or default) config is retained.
    func reload() {
        let path = Self.configPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: path),
              let data = fm.contents(atPath: path) else {
            return
        }

        let decoder = JSONDecoder()
        if let loaded = try? decoder.decode(Config.self, from: data) {
            config = loaded
        }
    }

    /// Write the current in-memory configuration back to disk, creating
    /// intermediate directories if needed.
    func save() throws {
        let path = Self.configPath
        let directory = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default

        if !fm.fileExists(atPath: directory) {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
