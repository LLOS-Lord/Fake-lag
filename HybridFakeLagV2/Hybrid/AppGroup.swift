import Foundation
import Darwin

// MARK: - Hybrid Config (App Group JSON) + Caches mirror + Logging
//
// FIXED (bug #1/#2 wiring): the config is written to the App Group container
// AND mirrored to /var/mobile/Library/Caches/hybrid_config.json so that
//   • the tunnel extension can fall back to it when the App Group container
//     is not resolvable inside the provider process,
//   • the root HUD daemon can read the exact same settings,
//   • libNetHookPayload.dylib (injected layer) reads its config from a fixed,
//     world-readable path.
// NSNotification does NOT cross process boundaries — cross-process wakeups use
// Darwin notifications (notify_post), which every component observes.

struct HybridConfig: Codable {
    var enabled: Bool = false
    var mode: String = "hold" // hold | drop | delay
    var direction: String = "both" // both | download | upload
    var protoFilter: String = "both" // both | tcp | udp
    var captureRatio: Int = 100
    var downloadRatio: Int = 100
    var uploadRatio: Int = 100
    var latencyMs: Int = 350
    var jitterMs: Int = 80
    var bandwidthKbps: Int = 0
    var duplicatePercent: Int = 0
    var autoFlushSeconds: Int = 12
    var dropUDPPercent: Int = 15
    var dropTCPPercent: Int = 5

    var targetBundleID: String = ""
    var targetPID: Int32 = 0
    var targetProcessName: String = ""
    var targetSockets: [SocketEntry] = []

    // Floating Button config (shared-memory synced via HybridHUDSyncFloatingConfig)
    var floatingSize: Float = 58.0
    var floatingOpacity: Float = 0.94
    var floatingEdgeSnap: Bool = true
    var floatingLockPosition: Bool = false
    var floatingHaptic: Bool = true
    var floatingPosX: Float = 310
    var floatingPosY: Float = 220

    var timestamp: TimeInterval = Date().timeIntervalSince1970
    var preset: String = "custom" // normal, ghost, lagspike, 3g, tcp_rst
}

struct SocketEntry: Codable {
    var localPort: UInt16
    var remotePort: UInt16
    var remoteIP: String
    var proto: String
}

class AppGroupStore {
    static let groupID = "group.com.hybrid.fakelag"
    static let configFile = "hybrid_config.json"
    static let logFile = "hybrid_actions.log"
    static let cachesDir = "/var/mobile/Library/Caches"

    static var containerURL: URL? {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            return url
        }
        // Fallback so logging/config still work on builds without the group
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
    static var configURL: URL? { containerURL?.appendingPathComponent(configFile) }
    static var logURL: URL? { containerURL?.appendingPathComponent(logFile) }
    static var legacyURL: URL? { containerURL?.appendingPathComponent("fakelag_config.plist") }
    static var cachesConfigPath: String { "\(cachesDir)/\(configFile)" }
    static var cachesLogPath: String { "\(cachesDir)/\(logFile)" }

    // MARK: Config

    static func save(_ cfg: HybridConfig) {
        guard let container = containerURL, let url = configURL else {
            NSLog("[AppGroup] containerURL nil, cannot save")
            return
        }
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        var c = cfg
        c.timestamp = Date().timeIntervalSince1970
        if let data = try? JSONEncoder().encode(c) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
            // Caches mirror — read by the extension fallback, the HUD daemon
            // and the injected payload (single source of truth for all three).
            try? data.write(to: URL(fileURLWithPath: cachesConfigPath), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: cachesConfigPath)
        }
        let legacy: [String: Any] = ["enabled": c.enabled, "timestamp": c.timestamp]
        if let lu = legacyURL {
            (legacy as NSDictionary).write(to: lu, atomically: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: lu.path)
        }
        syncToShm(c)
        NSLog("[AppGroup] saved config enabled=\(c.enabled) mode=\(c.mode) target=\(c.targetBundleID)")
    }

    static func load() -> HybridConfig {
        if let url = configURL, let data = try? Data(contentsOf: url),
           let cfg = try? JSONDecoder().decode(HybridConfig.self, from: data) {
            return cfg
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: cachesConfigPath)),
           let cfg = try? JSONDecoder().decode(HybridConfig.self, from: data) {
            return cfg
        }
        return HybridConfig()
    }

    // MARK: Cross-process wakeup (Darwin notifications, NOT NSNotification)

    static func syncToShm(_ cfg: HybridConfig) {
        notify_post("com.aethernet.interceptor.config_changed")
        notify_post("com.aethernet.interceptor.state_changed")
        NotificationCenter.default.post(name: Notification.Name("com.hybrid.configChanged"), object: nil)
    }

    /// Writes {enabled,timestamp} override consumed by the tunnel extension
    /// (instant enable/disable without waiting for the config poll).
    static func writeExtensionOverride(_ enabled: Bool) {
        let dict: [String: Any] = ["enabled": enabled, "timestamp": Date().timeIntervalSince1970]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        if let url = containerURL?.appendingPathComponent("hybrid_ext_override.json") {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
        }
        try? data.write(to: URL(fileURLWithPath: "\(cachesDir)/hybrid_ext_override.json"), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: "\(cachesDir)/hybrid_ext_override.json")
    }

    // MARK: Logging (bug #2: detailed + rotatable + merged at read time)

    static func logAction(_ action: String, details: String = "", level: String = "INFO") {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] [\(level)] [\(action)] \(details.isEmpty ? "-" : details)\n"
        writeLogLine(line)
    }

    /// Detailed variant: every line embeds a live stats snapshot so the log is
    /// self-describing (the old log had one word per action).
    static func logAction(_ action: String, details: String, passed: UInt64, dropped: UInt64, held: Int, extra: String = "") {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] [\(action)] \(details.isEmpty ? "-" : details) | passed=\(passed) dropped=\(dropped) held=\(held)\(extra.isEmpty ? "" : " | \(extra)")\n"
        writeLogLine(line)
    }

    private static func writeLogLine(_ line: String) {
        if let container = containerURL, let url = logURL {
            try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            appendToFile(line, url: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
        }
        // Caches mirror — readable by the root HUD daemon and the extension.
        appendToFile(line, url: URL(fileURLWithPath: cachesLogPath))
        try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: cachesLogPath)

        NSLog("[HybridLog] %@", line.trimmingCharacters(in: .whitespacesAndNewlines))

        rotateIfNeeded(url: logURL, limit: 512 * 1024, keep: 256 * 1024)
        rotateIfNeeded(url: URL(fileURLWithPath: cachesLogPath), limit: 512 * 1024, keep: 256 * 1024)
    }

    private static func appendToFile(_ line: String, url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) { handle.write(data) }
                try? handle.close()
            }
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func rotateIfNeeded(url: URL?, limit: Int, keep: Int) {
        guard let url = url,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, size > limit else { return }
        if let data = try? Data(contentsOf: url), data.count > keep {
            try? data.suffix(keep).write(to: url)
        }
    }

    /// Merges every log source into one chronological view:
    /// App Group log + Caches mirror + injected-payload (AetherNet) app log +
    /// HUD daemon log. Optional keyword filter (case-insensitive).
    static func readLogs(filter: String? = nil) -> String {
        var combined = ""
        if let url = logURL, let content = try? String(contentsOf: url) {
            combined += content
        }
        if let content = try? String(contentsOfFile: cachesLogPath) {
            if !combined.contains(String(content.suffix(2000))) {
                combined += "\n--- Caches Mirror Log ---\n" + content
            }
        }
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let appLog = docs.appendingPathComponent("aethernet.log")
            if let appLogs = try? String(contentsOf: appLog) {
                combined += "\n--- AetherNet App Log (inject layer) ---\n" + String(appLogs.suffix(8000))
            }
        }
        let hudLogPath = "/var/mobile/Library/aethernet-hud.log"
        if let hudLogs = try? String(contentsOfFile: hudLogPath) {
            combined += "\n--- HUD Daemon Log ---\n" + String(hudLogs.suffix(8000))
        }

        if let filter = filter, !filter.isEmpty {
            let q = filter.lowercased()
            let kept = combined.components(separatedBy: "\n").filter { line in
                line.isEmpty ? true : line.lowercased().contains(q)
            }
            combined = kept.joined(separator: "\n")
        }
        return combined.isEmpty ? "No logs yet. Try actions to generate logs." : combined
    }

    static func clearLogs() {
        if let url = logURL { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(atPath: cachesLogPath)
        try? FileManager.default.removeItem(atPath: "/var/mobile/Library/aethernet-hud.log")
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: docs.appendingPathComponent("aethernet.log"))
        }
        logAction("LOGS_CLEARED", details: "")
    }
}

class HybridLogger {
    static func log(_ msg: String) {
        NSLog("[HybridLog] %@", msg)
    }
}
