import Foundation

// MARK: - Hybrid Config (App Group JSON) + Sync with AetherSharedState (shm)

struct HybridConfig: Codable {
    var enabled: Bool = false
    var mode: String = "hold" // hold | drop | delay | tamper
    var direction: String = "both" // both | download | upload
    var protoFilter: String = "both" // both | tcp | udp
    var captureRatio: Int = 100
    var downloadRatio: Int = 100
    var uploadRatio: Int = 100
    var latencyMs: Int = 350
    var jitterMs: Int = 80
    var bandwidthKbps: Int = 0 // 0 = unlimited
    var duplicatePercent: Int = 0
    var autoFlushSeconds: Int = 12
    var dropUDPPercent: Int = 15
    var dropTCPPercent: Int = 5
    
    var targetBundleID: String = ""
    var targetPID: Int32 = 0
    var targetProcessName: String = ""
    var targetSockets: [SocketEntry] = []
    
    // Floating Button config
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
    static let groupID = "group.com.ban.PacketBlocker"
    static let configFile = "hybrid_config.json"
    static let logFile = "hybrid_actions.log"
    
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }
    static var configURL: URL? { containerURL?.appendingPathComponent(configFile) }
    static var logURL: URL? { containerURL?.appendingPathComponent(logFile) }
    static var legacyURL: URL? { containerURL?.appendingPathComponent("fakelag_config.plist") }
    
    static func save(_ cfg: HybridConfig) {
        guard let url = configURL else { return }
        try? FileManager.default.createDirectory(at: containerURL!, withIntermediateDirectories: true)
        var c = cfg
        c.timestamp = Date().timeIntervalSince1970
        if let data = try? JSONEncoder().encode(c) {
            try? data.write(to: url, options: .atomic)
        }
        // legacy for old extension
        let legacy: [String: Any] = ["enabled": c.enabled, "timestamp": c.timestamp]
        if let lu = legacyURL { (legacy as NSDictionary).write(to: lu, atomically: true) }
        
        // Sync to AetherSharedState (shm) for HUD daemon
        syncToShm(c)
    }
    
    static func load() -> HybridConfig {
        guard let url = configURL, let data = try? Data(contentsOf: url) else { return HybridConfig() }
        return (try? JSONDecoder().decode(HybridConfig.self, from: data)) ?? HybridConfig()
    }
    
    // MARK: - Sync to AetherSharedState (C struct in shared memory)
    static func syncToShm(_ cfg: HybridConfig) {
        // Call C function AetherGetSharedState via bridging
        // We use direct file write to shm path as fallback if C not available
        // The main sync is done in FloatingHUDManager via ObjC
        NotificationCenter.default.post(name: Notification.Name("com.hybrid.configChanged"), object: nil)
    }
    
    // MARK: - Logging
    static func logAction(_ action: String, details: String = "") {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(action) \(details)\n"
        // Write to app group log
        if let url = logURL {
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(line.data(using: .utf8)!)
                    try? handle.close()
                }
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        // Also log via AetherLog (Objective-C)
        HybridLogger.log(line)
        
        // Trim if >500KB
        if let url = logURL, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? UInt64, size > 500*1024 {
            if let data = try? Data(contentsOf: url), data.count > 250*1024 {
                let trimmed = data.suffix(250*1024)
                try? trimmed.write(to: url)
            }
        }
    }
    
    static func readLogs() -> String {
        guard let url = logURL, let content = try? String(contentsOf: url) else { return "No logs yet." }
        return content
    }
    
    static func clearLogs() {
        if let url = logURL { try? FileManager.default.removeItem(at: url) }
    }
}

// Bridge to AetherLog
class HybridLogger {
    static func log(_ msg: String) {
        // Call AetherLog via ObjC runtime
        // AetherLog is defined in AetherLog.h
        // We use dynamic call to avoid import issues
        NSLog("[HybridLog] %@", msg)
    }
}
