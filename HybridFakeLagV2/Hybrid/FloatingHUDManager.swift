import Foundation
import UIKit

// Floating HUD manager — FIXED to follow the TrollNetInterceptor (.zip) flow
// through the real ObjC engine (AetherProcessManager) instead of the broken
// plain-posix_spawn fallback the mixed source had:
//
//   1. HybridHUDPrepareForSpawn()  → kill old daemon + RESET shm hudCommand /
//      heartbeat + remove stale pid file. (A leftover "exit" command in the
//      shared memory used to kill the fresh daemon within 1s — that is why
//      "bấm Create mà không thấy nút nào xuất hiện".)
//   2. posix_spawn with persona-99 ROOT re-exec of THIS binary with "-hud"
//      (plain spawns run as uid 501 and SpringBoard kills their window).
//   3. Verify after 1.5s that the daemon is really alive (shm heartbeat).
//   4. Watchdog respawns the daemon (bounded attempts) if it silently dies
//      while the user still expects it (respring / jetsam / crash).
//   5. Floating config (size/opacity/snap/lock/haptic/position) is pushed into
//      the shared memory the daemon reads — the old mix only saved a JSON file
//      the daemon never opened.
class FloatingHUDManager: ObservableObject {
    static let shared = FloatingHUDManager()

    @Published var isRunning = false
    @Published var lastError: String?
    private var timer: Timer?
    private var watchdog: Timer?
    private var respawnAttempts = 0
    private let maxRespawnAttempts = 3
    /// True while the user wants the HUD alive (after pressing Create).
    private var expectedEnabled = false
    /// Debounce + in-flight guards: rapid re-taps used to prepare+spawn several
    /// daemons per second, each prepare() KILLING the previous child mid-boot.
    private var lastSpawnAt = Date.distantPast
    private var inFlightSpawn = false
    /// Pid of the most recently spawned child (diagnostics).
    private var lastChildPid: Int32 = 0

    init() {
        expectedEnabled = HybridHUDIsRunning()
        checkRunning()
        startWatcher()
        startWatchdog()
    }

    func checkRunning() {
        // Primary: shm heartbeat via C helper (works across uid 501 ↔ root,
        // tolerates EPERM on the pid probe — same semantics as the .zip app).
        let alive = HybridHUDIsRunning()
        if alive != isRunning {
            AppGroupStore.logAction("HUD_STATUS", details: "daemon \(alive ? "alive" : "gone")")
        }
        DispatchQueue.main.async { self.isRunning = alive }
    }

    private func startWatcher() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkRunning()
        }
    }

    /// Respawns the daemon if it silently died while the user still expects it.
    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, self.expectedEnabled, !self.isRunning else { return }
            guard !self.inFlightSpawn else { return } // spawn already pending
            guard self.respawnAttempts < self.maxRespawnAttempts else {
                AppGroupStore.logAction("HUD_WATCHDOG", details: "give up after \(self.maxRespawnAttempts) respawn attempts")
                self.expectedEnabled = false
                return
            }
            self.respawnAttempts += 1
            AppGroupStore.logAction("HUD_WATCHDOG", details: "daemon missing — respawn attempt \(self.respawnAttempts)/\(self.maxRespawnAttempts)")
            self.spawnDaemon()
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            if isRunning {
                AppGroupStore.logAction("HUD_CREATE_SKIP", details: "already running")
                expectedEnabled = true
                return
            }
            // Debounce: one spawn attempt per 4s max (previous child must not
            // be killed mid-boot by an impatient re-tap).
            if inFlightSpawn || Date().timeIntervalSince(lastSpawnAt) < 4.0 {
                AppGroupStore.logAction("HUD_CREATE_SKIP", details: "debounce — spawn already in flight, wait for verify")
                expectedEnabled = true
                return
            }
            expectedEnabled = true
            respawnAttempts = 0
            AppGroupStore.logAction("HUD_CREATE", details: "prepare + spawn root HUD daemon (TrollNet flow)")
            spawnDaemon()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.verifySpawn() }
            // Push the current floating config right away so the fresh daemon
            // starts with the user's size/opacity/position.
            syncFloatingConfigFromStore()
        } else {
            expectedEnabled = false
            respawnAttempts = 0
            AppGroupStore.logAction("HUD_REMOVE", details: "graceful exit via shm command + root -exit fallback")
            HybridHUDRequestExit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.checkRunning()
                if let self = self, !self.isRunning {
                    AppGroupStore.logAction("HUD_REMOVED", details: "daemon confirmed stopped")
                }
            }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    /// The actual spawn: prepare (kill old + reset shm) → re-exec self with -hud.
    private func spawnDaemon() {
        guard let execPath = Bundle.main.executablePath else {
            lastError = "Bundle.main.executablePath is nil"
            AppGroupStore.logAction("HUD_SPAWN_FAIL", details: lastError!, level: "ERROR")
            return
        }

        lastSpawnAt = Date()
        inFlightSpawn = true
        let prepare = HybridHUDPrepareForSpawn()
        if prepare == 1 {
            // An old daemon needed killing — give it a moment, then spawn.
            AppGroupStore.logAction("HUD_PREPARE", details: "old daemon killed, waiting 0.9s before spawn")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.doSpawn(execPath: execPath)
            }
        } else {
            doSpawn(execPath: execPath)
        }
    }

    private func doSpawn(execPath: String) {
        #if os(iOS)
        var childPid: Int32 = 0
        let rc = execPath.withCString { cPath -> Int32 in
            Int32(HybridSpawnRootPID(cPath, "-hud", "", &childPid))
        }
        lastChildPid = childPid
        AppGroupStore.logAction("HUD_SPAWN_RESULT", details: "posix_spawn rc=\(rc) (0=ok) childPid=\(childPid) exec=\(execPath)")
        if rc != 0 {
            DispatchQueue.main.async { self.lastError = "posix_spawn failed rc=\(rc)" }
            self.inFlightSpawn = false
            return
        }
        // Probe the child: rc=0 does NOT prove exec worked (0=gone 1=alive 2=root).
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            var path = [CChar](repeating: 0, count: 1024)
            let probe = path.withUnsafeMutableBufferPointer { buf -> Int32 in
                Int32(HybridProbeChildPid(childPid, buf.baseAddress, 1024))
            }
            let exe = String(cString: path).trimmingCharacters(in: .whitespacesAndNewlines)
            AppGroupStore.logAction("HUD_SPAWN_PID",
                details: "child pid=\(childPid) probe=\(probe) (0=gone 1=alive 2=alive-root) exe=\(exe.isEmpty ? "?" : exe)")
        }
        #else
        AppGroupStore.logAction("HUD_SPAWN_SKIP", details: "non-iOS build: \(execPath)")
        #endif
    }

    private func verifySpawn() {
        checkRunning()
        inFlightSpawn = false
        if isRunning {
            AppGroupStore.logAction("HUD_ALIVE", details: "daemon verified via shm heartbeat — floating button should be visible")
            DispatchQueue.main.async { self.lastError = nil }
        } else {
            let msg = "daemon not alive after 2.5s (lastChildPid=\(lastChildPid) — see HUD_SPAWN_PID / HUD_EARLY / HUD_STEP lines); watchdog will retry"
            AppGroupStore.logAction("HUD_VERIFY_FAIL", details: msg, level: "WARN")
            DispatchQueue.main.async { self.lastError = msg }
        }
    }

    /// Pushes the Settings-tab floating customization into the HUD daemon's
    /// shared memory (the daemon reads size/opacity/snap/lock/haptic/pos).
    func syncFloatingConfigFromStore() {
        let cfg = AppGroupStore.load()
        HybridHUDSyncFloatingConfig(cfg.floatingSize, cfg.floatingOpacity,
                                    cfg.floatingEdgeSnap, cfg.floatingLockPosition,
                                    cfg.floatingHaptic, cfg.floatingPosX, cfg.floatingPosY)
        AppGroupStore.logAction("HUD_CONFIG_SYNC", details: "size=\(cfg.floatingSize) opacity=\(cfg.floatingOpacity) snap=\(cfg.floatingEdgeSnap) lock=\(cfg.floatingLockPosition) haptic=\(cfg.floatingHaptic) pos=(\(cfg.floatingPosX),\(cfg.floatingPosY))")
    }
}
