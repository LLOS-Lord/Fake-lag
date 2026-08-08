import Foundation

/// Quản lý config qua file trong App Group - không phụ thuộc IPC
class SharedConfig {
    static let shared = SharedConfig()

    private let groupID = "group.com.ban.PacketBlocker"
    private var configFileURL: URL {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)!
            .appendingPathComponent("fakelag_config.plist")
    }

    struct Config: Codable {
        var enabled: Bool = false
        var delayMs: Int = 100
        var dropEnabled: Bool = false
        var dropPercent: Int = 30
        var timestamp: TimeInterval = 0
    }

    private init() {}

    func write(config: Config) {
        do {
            let data = try PropertyListEncoder().encode(config)
            try data.write(to: configFileURL, options: .atomic)
        } catch {
            NSLog("[SharedConfig] Write error: \(error)")
        }
    }

    func read() -> Config {
        guard FileManager.default.fileExists(atPath: configFileURL.path) else {
            return Config()
        }
        do {
            let data = try Data(contentsOf: configFileURL)
            return try PropertyListDecoder().decode(Config.self, from: data)
        } catch {
            NSLog("[SharedConfig] Read error: \(error)")
            return Config()
        }
    }

    func lastModified() -> TimeInterval {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: configFileURL.path),
              let date = attrs[.modificationDate] as? Date else {
            return 0
        }
        return date.timeIntervalSince1970
    }
}
