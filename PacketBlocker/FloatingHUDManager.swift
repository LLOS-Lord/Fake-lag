import Foundation
import UIKit

class FloatingHUDManager: ObservableObject {
    static let shared = FloatingHUDManager()
    @Published var isRunning = false
    private var timer: Timer?
    
    init() {
        checkRunning()
        startWatcher()
    }
    
    func checkRunning() {
        // Check via shm heartbeat + pid file
        // Primary: check shm if available (via AppGroup log timestamp)
        // Fallback: pid file
        let pidPath = "/var/mobile/Library/Caches/com.aethernet.hud.pid"
        if let pidStr = try? String(contentsOfFile: pidPath), let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
            let alive = kill(pid, 0) == 0 || errno == EPERM
            DispatchQueue.main.async { self.isRunning = alive }
            return
        }
        // Also check App Group heartbeat file
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ban.PacketBlocker") {
            let heartbeatPath = container.appendingPathComponent("hud_heartbeat.txt")
            if let data = try? Data(contentsOf: heartbeatPath), let str = String(data: data, encoding: .utf8), let ts = TimeInterval(str) {
                if Date().timeIntervalSince1970 - ts < 5 {
                    DispatchQueue.main.async { self.isRunning = true }
                    return
                }
            }
        }
        DispatchQueue.main.async { self.isRunning = false }
    }
    
    private func startWatcher() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            self.checkRunning()
        }
    }
    
    func setEnabled(_ enabled: Bool) {
        guard let execPath = Bundle.main.executablePath else { return }
        
        if enabled {
            if isRunning {
                AppGroupStore.logAction("HUD_CREATE_SKIP", details: "already running")
                return
            }
            AppGroupStore.logAction("HUD_CREATE", details: "spawning daemon via PersonaHelper root")
            let result = spawnRoot(execPath: execPath, args: ["-hud"])
            AppGroupStore.logAction("HUD_SPAWN_RESULT", details: "result=\(result)")
            DispatchQueue.main.asyncAfter(deadline: .now()+1.5) { self.checkRunning() }
        } else {
            AppGroupStore.logAction("HUD_REMOVE", details: "removing daemon")
            // Try graceful via notification + file
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ban.PacketBlocker") {
                let cmdPath = container.appendingPathComponent("hud_command.txt")
                try? "exit".write(to: cmdPath, atomically: true, encoding: .utf8)
            }
            // Legacy -exit spawn
            _ = spawnRoot(execPath: execPath, args: ["-exit"])
            // Also try kill via pid file
            let pidPath = "/var/mobile/Library/Caches/com.aethernet.hud.pid"
            if let pidStr = try? String(contentsOfFile: pidPath), let pid = Int32(pidStr) {
                kill(pid, SIGKILL)
                try? FileManager.default.removeItem(atPath: pidPath)
            }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }
    
    private func spawnRoot(execPath: String, args: [String]) -> Int32 {
        #if os(iOS)
        // Use PersonaHelper C function for root spawn
        let arg1 = args.first ?? ""
        let arg2 = args.count > 1 ? args[1] : ""
        // Call C function HybridSpawnRoot
        let result = execPath.withCString { cPath in
            arg1.withCString { cArg1 in
                arg2.withCString { cArg2 in
                    HybridSpawnRoot(cPath, cArg1, cArg2.isEmpty ? nil : cArg2)
                }
            }
        }
        return Int32(result)
        #else
        NSLog("[Hybrid] spawn skipped on macOS - %@", execPath)
        return 0
        #endif
    }
}
