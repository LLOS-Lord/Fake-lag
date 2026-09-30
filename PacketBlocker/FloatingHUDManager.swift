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
            DispatchQueue.main.async { self.isRunning = false }
        }
    }
    
    private func spawn(execPath: String, args: [String]) {
        var pid: pid_t = 0
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // Set pgid
        if let attr = attr {
            var mutableAttr = attr
            posix_spawnattr_setflags(&mutableAttr, Int16(POSIX_SPAWN_SETPGROUP))
            // For TrollStore root persona, we would use private API posix_spawnattr_set_persona_np
            // Skip for build
        }
        
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        
        let cArgs = [execPath] + args
        // Create C string array
        let cArgsCStrings = cArgs.map { strdup($0) }
        var cArgsPtr: [UnsafeMutablePointer<CChar>?] = cArgsCStrings.map { $0 } + [nil]
        
        let result = cArgsPtr.withUnsafeMutableBufferPointer { buffer in
            // buffer.baseAddress is UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
            posix_spawn(&pid, execPath, &fileActions, &attr, buffer.baseAddress, environ)
        }
        
        for ptr in cArgsCStrings { free(ptr) }
        posix_spawnattr_destroy(&attr)
        posix_spawn_file_actions_destroy(&fileActions)
        
        if result == 0 {
            NSLog("[Hybrid] spawned HUD pid %d args %@", pid, args.joined(separator: " "))
        } else {
            NSLog("[Hybrid] spawn failed %d", result)
        }
    }
}
