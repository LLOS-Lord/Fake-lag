import Foundation
import UIKit

// Manages global floating button daemon (same binary -hud mode)
// Ported from AetherNet ProcessManager but enhanced with HybridConfig sync

class FloatingHUDManager: ObservableObject {
    static let shared = FloatingHUDManager()
    
    @Published var isRunning = false
    private var timer: Timer?
    
    init() {
        checkRunning()
        startHeartbeatWatcher()
    }
    
    func checkRunning() {
        // Check via shm heartbeat (primary) + pid file (fallback)
        // Call Objective-C ProcessManager isGlobalFloatingHUDRunning
        // Simplified: check file /var/mobile/Library/Caches/com.aethernet.hud.pid
        let pidPath = "/var/mobile/Library/Caches/com.aethernet.hud.pid"
        if let pidStr = try? String(contentsOfFile: pidPath), let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
            // kill 0 check
            let alive = kill(pid, 0) == 0 || errno == EPERM
            isRunning = alive
            return
        }
        // Check shm heartbeat via AppGroupStore timestamp? fallback false
        isRunning = false
    }
    
    private func startHeartbeatWatcher() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            self.checkRunning()
        }
    }
    
    func setEnabled(_ enabled: Bool) {
        // Use posix_spawn with persona 99 UID 0 like AetherNet
        let execPath = getExecPath()
        guard !execPath.isEmpty else { return }
        
        if enabled {
            if isRunning { return }
            AppGroupStore.logAction("HUD_CREATE", details: "spawning daemon")
            spawn(execPath: execPath, args: ["-hud"])
            // Sync config to shm
            syncConfigToShm()
            DispatchQueue.main.asyncAfter(deadline: .now()+1.0) { self.checkRunning() }
        } else {
            AppGroupStore.logAction("HUD_REMOVE", details: "removing daemon")
            // Try graceful via shm command first (AetherNet does)
            // Then legacy -exit
            spawn(execPath: execPath, args: ["-exit"])
            isRunning = false
        }
    }
    
    private func getExecPath() -> String {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        _NSGetExecutablePath(&buf, &size)
        return String(cString: buf)
    }
    
    private func spawn(execPath: String, args: [String]) {
        // Use posix_spawnattr_set_persona_np for root
        // Simplified: use ProcessManager's method via ObjC bridge
        // For Swift, we call the ObjC ProcessManager singleton
        // This is a workaround - call via Notification to let ObjC handle
        // We'll directly use the Objective-C class if available
        if let cls = NSClassFromString("AetherProcessManager") as? NSObjectProtocol {
            // Try perform selector setGlobalFloatingHUDEnabled:
            // Use runtime
        }
        // Fallback pure Swift spawn (may not be root but works on some TrollStore)
        var pid: pid_t = 0
        var attr: posix_spawnattr_t = posix_spawnattr_t()
        posix_spawnattr_init(&attr)
        // Try persona 99 root
        // posix_spawnattr_set_persona_np is private, we call via dlsym
        // For simplicity, just spawn normally
        let cArgs = [execPath] + args
        let cArgsPtr = cArgs.map { strdup($0) } + [nil]
        let env = [String](["PATH=/usr/bin:/bin:/usr/sbin:/sbin"])
        // posix_spawn
        var fileActions: posix_spawn_file_actions_t? = nil
        // We ignore persona for Swift fallback
        let result = cArgsPtr.withUnsafeBufferPointer { buf in
            posix_spawn(&pid, execPath, nil, &attr, UnsafeMutablePointer(mutating: buf.baseAddress), environ)
        }
        posix_spawnattr_destroy(&attr)
        for ptr in cArgsPtr { if let p = ptr { free(p) } }
        if result == 0 {
            NSLog("[Hybrid] spawned HUD pid %d args %@", pid, args.joined(separator: " "))
        } else {
            NSLog("[Hybrid] spawn failed %d", result)
        }
    }
    
    private func syncConfigToShm() {
        // Sync HybridConfig to AetherSharedState via C
        // This will be done in Objective-C bridge: AetherGetSharedState
        // We post notification
        NotificationCenter.default.post(name: NSNotification.Name("com.aethernet.interceptor.config_changed"), object: nil)
    }
}
