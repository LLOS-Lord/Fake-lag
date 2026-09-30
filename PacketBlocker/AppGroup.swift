import Foundation

struct HybridConfig: Codable {
    var enabled: Bool = false
    var mode: String = "hold"
    var direction: String = "both"
    var protoFilter: String = "both"
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
    var floatingSize: Float = 58.0
    var floatingOpacity: Float = 0.94
    var floatingEdgeSnap: Bool = true
    var floatingLockPosition: Bool = false
    var floatingHaptic: Bool = true
    var floatingPosX: Float = 310
    var floatingPosY: Float = 220
    var timestamp: TimeInterval = Date().timeIntervalSince1970
    var preset: String = "custom"
}

struct SocketEntry: Codable {
    var localPort: UInt16
    var remotePort: UInt16
    var remoteIP: String
    var proto: String
}

class AppGroupStore {
    static let groupID = "group.com.ban.PacketBlocker"
    static let configFile = "hybrid_config.json"
    static let logFile = "hybrid_actions.log"
    
    // Primary: App Group container, Fallback: Documents for TrollStore without group
    static var containerURL: URL? {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            return url
        }
        // Fallback to Documents for logging when App Group not available
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
    
    static var configURL: URL? { containerURL?.appendingPathComponent(configFile) }
    static var logURL: URL? { containerURL?.appendingPathComponent(logFile) }
    static var legacyURL: URL? { containerURL?.appendingPathComponent("fakelag_config.plist") }
    static var heartbeatURL: URL? { containerURL?.appendingPathComponent("hud_heartbeat.txt") }
    static var commandURL: URL? { containerURL?.appendingPathComponent("hud_command.txt") }
    
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
            // Also copy to /var/mobile/Library/Caches for HUD daemon fallback
            let fallback = "/var/mobile/Library/Caches/\(configFile)"
            try? data.write(to: URL(fileURLWithPath: fallback), options: .atomic)
            // Ensure readable
            try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: fallback)
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
        // Try App Group first, then fallback
        if let url = configURL, let data = try? Data(contentsOf: url), let cfg = try? JSONDecoder().decode(HybridConfig.self, from: data) {
            return cfg
        }
        // Fallback to Caches
        let fallback = "/var/mobile/Library/Caches/\(configFile)"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: fallback)), let cfg = try? JSONDecoder().decode(HybridConfig.self, from: data) {
            return cfg
        }
        return HybridConfig()
    }
    
    static func syncToShm(_ cfg: HybridConfig) {
        NotificationCenter.default.post(name: Notification.Name("com.aethernet.interceptor.config_changed"), object: nil)
        NotificationCenter.default.post(name: Notification.Name("com.hybrid.configChanged"), object: nil)
    }
    
    static func logAction(_ action: String, details: String = "") {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(action) \(details)\n"
        // Write to primary logURL
        if let container = containerURL, let url = logURL {
            try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    if let data = line.data(using: .utf8) {
                        handle.write(data)
                    }
                    try? handle.close()
                }
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
        }
        // Also write to fallback Caches for HUD daemon to read
        let fallbackLog = "/var/mobile/Library/Caches/\(logFile)"
        if FileManager.default.fileExists(atPath: fallbackLog) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: fallbackLog)) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
                try? handle.close()
            }
        } else {
            try? line.write(to: URL(fileURLWithPath: fallbackLog), atomically: true, encoding: .utf8)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: fallbackLog)
        
        // Also NSLog for debugging
        NSLog("[HybridLog] %@", line.trimmingCharacters(in: .whitespacesAndNewlines))
        
        // Trim if >500KB
        if let url = logURL, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? UInt64, size > 500*1024 {
            if let data = try? Data(contentsOf: url), data.count > 250*1024 {
                let trimmed = data.suffix(250*1024)
                try? trimmed.write(to: url)
            }
        }
    }
    
    static func readLogs() -> String {
        var combined = ""
        // Primary
        if let url = logURL, let content = try? String(contentsOf: url) {
            combined += content
        }
        // Fallback Caches
        let fallbackLog = "/var/mobile/Library/Caches/\(logFile)"
        if let content = try? String(contentsOfFile: fallbackLog) {
            if !combined.contains(content) {
                combined += "\n--- Fallback Caches Log ---\n" + content
            }
        }
        // AetherNet logs
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let appLog = docs.appendingPathComponent("aethernet.log")
            if let appLogs = try? String(contentsOf: appLog) {
                combined += "\n--- AetherNet App Log ---\n" + String(appLogs.suffix(5000))
            }
        }
        let hudLogPath = "/var/mobile/Library/aethernet-hud.log"
        if let hudLogs = try? String(contentsOfFile: hudLogPath) {
            combined += "\n--- HUD Daemon Log ---\n" + String(hudLogs.suffix(5000))
        }
        return combined.isEmpty ? "No logs yet. Try actions to generate logs." : combined
    }
    
    static func clearLogs() {
        if let url = logURL { try? FileManager.default.removeItem(at: url) }
        let fallbackLog = "/var/mobile/Library/Caches/\(logFile)"
        try? FileManager.default.removeItem(atPath: fallbackLog)
        let hudLogPath = "/var/mobile/Library/aethernet-hud.log"
        try? FileManager.default.removeItem(atPath: hudLogPath)
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let appLog = docs.appendingPathComponent("aethernet.log")
            try? FileManager.default.removeItem(at: appLog)
        }
        logAction("LOGS_CLEARED", details: "")
    }
    
    static func writeHeartbeat() {
        guard let url = heartbeatURL else { return }
        let ts = "\(Date().timeIntervalSince1970)"
        try? ts.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
    }
}

class HybridLogger {
    static func log(_ msg: String) {
        NSLog("[HybridLog] %@", msg)
    }
}
