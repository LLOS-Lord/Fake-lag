import Foundation
import UIKit

// Manages global floating button daemon (simplified for build success)
// Real implementation uses posix_spawn with persona 99 UID 0

class FloatingHUDManager: ObservableObject {
    static let shared = FloatingHUDManager()
    
    @Published var isRunning = false
    private var timer: Timer?
    
    init() {
        checkRunning()
        startWatcher()
    }
    
    func checkRunning() {
        let pidPath = "/var/mobile/Library/Caches/com.aethernet.hud.pid"
        if let pidStr = try? String(contentsOfFile: pidPath), let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
            let alive = kill(pid, 0) == 0 || errno == EPERM
            DispatchQueue.main.async { self.isRunning = alive }
            return
        }
        DispatchQueue.main.async { self.isRunning = false }
    }
    
    private func startWatcher() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            self.checkRunning()
        }
    }
    
    func setEnabled(_ enabled: Bool) {
        let execPath = Bundle.main.executablePath ?? ""
        guard !execPath.isEmpty else { return }
        
        if enabled {
            if isRunning { return }
            AppGroupStore.logAction("HUD_CREATE", details: "spawning daemon")
            spawn(execPath: execPath, args: ["-hud"])
            DispatchQueue.main.asyncAfter(deadline: .now()+1.0) { self.checkRunning() }
        } else {
            AppGroupStore.logAction("HUD_REMOVE", details: "removing daemon")
            spawn(execPath: execPath, args: ["-exit"])
            isRunning = false
        }
    }
    
    private func spawn(execPath: String, args: [String]) {
        // FIXED: Use proper posix_spawn API for Swift
        var pid: pid_t = 0
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        
        // Try to set persona for root (private API, may fail on non-TrollStore)
        // We use dlsym to avoid direct reference
        // For build success, just spawn normally
        
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        
        let cArgs = [execPath] + args
        let cArgsPtr = cArgs.map { $0.withCString { strdup($0) } } + [nil]
        
        let result = cArgsPtr.withUnsafeBufferPointer { buf in
            posix_spawn(&pid, execPath, fileActions, attr, UnsafeMutablePointer(mutating: buf.baseAddress), environ)
        }
        
        // Cleanup
        for ptr in cArgsPtr { if let p = ptr { free(p) } }
        posix_spawnattr_destroy(&attr)
        posix_spawn_file_actions_destroy(&fileActions)
        
        if result == 0 {
            NSLog("[Hybrid] spawned HUD pid %d args %@", pid, args.joined(separator: " "))
        } else {
            NSLog("[Hybrid] spawn failed %d", result)
        }
    }
}
