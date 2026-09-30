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
        #if os(iOS)
        // Real device with TrollStore: use posix_spawn with persona for root
        var pid: pid_t = 0
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // Set flags - pass pointer to optional
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        
        let cArgs = [execPath] + args
        let cStrings = cArgs.map { strdup($0) }
        var cArgsPtr: [UnsafeMutablePointer<CChar>?] = cStrings.map { $0 } + [nil]
        
        let result = cArgsPtr.withUnsafeMutableBufferPointer { buf in
            posix_spawn(&pid, execPath, &fileActions, &attr, buf.baseAddress, environ)
        }
        
        for ptr in cStrings { free(ptr) }
        posix_spawnattr_destroy(&attr)
        posix_spawn_file_actions_destroy(&fileActions)
        
        if result == 0 {
            NSLog("[Hybrid] spawned HUD pid %d", pid)
        } else {
            NSLog("[Hybrid] spawn failed %d", result)
        }
        #else
        // macOS GitHub Actions build: skip actual spawn
        NSLog("[Hybrid] spawn skipped on macOS (GitHub Actions) - execPath: %@ args: %@", execPath, args.joined(separator: " "))
        #endif
    }
}
