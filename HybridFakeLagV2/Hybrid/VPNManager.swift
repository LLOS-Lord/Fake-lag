import NetworkExtension
import SwiftUI

// VPN manager — FIXED lifecycle:
//   • VPN comes up with simulation OFF: the tunnel is a pure relay (bug #3),
//     traffic flows untouched until the user presses "Bật FakeLag".
//   • enable/disable pokes the provider directly (sendProviderMessage) AND
//     persists an override file the extension reads — the old mix sent
//     messages the extension answered with "ok" and then ignored.
//   • Full lifecycle logging with error codes + live stats polling
//     (handleAppMessage "getstats") so the Home tab shows relay counters.
class VPNManager: ObservableObject {
    static let shared = VPNManager()

    @Published var isVPNConnected = false
    @Published var isBlocking = false
    @Published var isProcessing = false
    @Published var lastError: String?
    @Published var selectedProcess: ProcessInfoModel?
    @Published var lastStats: String = ""

    @Published var mode: String = "hold"
    @Published var direction: String = "both"
    @Published var protoFilter: String = "both"
    @Published var latencyMs: Int = 350
    @Published var jitterMs: Int = 80
    @Published var bandwidthKbps: Int = 0
    @Published var captureRatio: Int = 100

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private let procScanner = ProcessManagerSwift()

    var extBundleID: String {
        let main = Bundle.main.bundleIdentifier ?? "com.hybrid.fakelag"
        return "\(main).extension"
    }

    init() {
        let cfg = AppGroupStore.load()
        self.isBlocking = cfg.enabled
        self.mode = cfg.mode
        self.direction = cfg.direction
        self.protoFilter = cfg.protoFilter
        self.latencyMs = cfg.latencyMs
        self.jitterMs = cfg.jitterMs
        self.bandwidthKbps = cfg.bandwidthKbps
        self.captureRatio = cfg.captureRatio
        AppGroupStore.logAction("APP_INIT", details: "config loaded enabled=\(cfg.enabled) mode=\(cfg.mode) dir=\(cfg.direction) proto=\(cfg.protoFilter) ratio=\(cfg.captureRatio) latency=\(cfg.latencyMs)ms target=\(cfg.targetBundleID.isEmpty ? "GLOBAL" : cfg.targetBundleID)")
        loadVPN()
        setupObserver()
    }

    private func setupObserver() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
            guard let self = self else { return }
            let conn = (note.object as? NEVPNConnection)?.status
            self.updateStatus()
            AppGroupStore.logAction("VPN_STATUS", details: "status=\(conn.map { String(describing: $0) } ?? "changed") connected=\(self.isVPNConnected)")
        }
    }

    private func updateStatus() {
        DispatchQueue.main.async {
            let st = self.manager?.connection.status ?? .invalid
            let was = self.isVPNConnected
            self.isVPNConnected = (st == .connected)
            if was && !self.isVPNConnected {
                // VPN went down — make sure the simulation is disabled on disk too.
                self.isBlocking = false
                var cfg = AppGroupStore.load()
                cfg.enabled = false
                AppGroupStore.save(cfg)
                AppGroupStore.writeExtensionOverride(false)
                AppGroupStore.logAction("VPN_DOWN", details: "cleaned enabled=false")
            }
        }
    }

    func loadVPN() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let e = error {
                self.lastError = "Load: \(e.localizedDescription)"
                AppGroupStore.logAction("VPN_LOAD_FAIL", details: "\(e.localizedDescription) (code \((e as NSError).code))", level: "ERROR")
                return
            }
            let found = managers ?? []
            AppGroupStore.logAction("VPN_LOAD", details: "\(found.count) saved manager(s): \(found.compactMap { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier ?? "?" }.joined(separator: ", "))")
            self.manager = found.first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.extBundleID }) ?? found.first
            self.updateStatus()
        }
    }

    func saveConfig() {
        var cfg = AppGroupStore.load()
        cfg.enabled = isBlocking
        cfg.mode = mode
        cfg.direction = direction
        cfg.protoFilter = protoFilter
        cfg.latencyMs = latencyMs
        cfg.jitterMs = jitterMs
        cfg.bandwidthKbps = bandwidthKbps
        cfg.captureRatio = captureRatio
        cfg.downloadRatio = captureRatio
        cfg.uploadRatio = captureRatio

        if let proc = selectedProcess {
            cfg.targetBundleID = proc.bundleID
            cfg.targetPID = proc.pid
            cfg.targetProcessName = proc.displayName
            // REAL live socket dump of the target PID (proc_pidfdinfo) so the
            // tunnel matches the app's actual remote endpoints.
            let dump = procScanner.dumpSocketsForPID(proc.pid)
            cfg.targetSockets = dump
            if dump.isEmpty {
                AppGroupStore.logAction("CONFIG_TARGET", details: "pid=\(proc.pid) \(proc.displayName) — socket dump EMPTY, extension will fall back to match-all for this target", level: "WARN")
            }
        } else {
            cfg.targetBundleID = ""
            cfg.targetPID = 0
            cfg.targetProcessName = ""
            cfg.targetSockets = []
        }
        AppGroupStore.save(cfg)
        AppGroupStore.logAction("CONFIG_SAVE", details: "enabled=\(cfg.enabled) mode=\(cfg.mode) dir=\(cfg.direction) proto=\(cfg.protoFilter) ratio=\(cfg.captureRatio)% latency=\(cfg.latencyMs)ms jitter=\(cfg.jitterMs)ms bw=\(cfg.bandwidthKbps)kbps target=\(cfg.targetBundleID.isEmpty ? "GLOBAL" : "\(cfg.targetBundleID) pid=\(cfg.targetPID) sockets=\(cfg.targetSockets.count)")")
    }

    func connectVPN() {
        // VPN up with simulation OFF — the tunnel must relay traffic untouched
        // until the user presses "Bật FakeLag" (this was the broken flow).
        var cfg = AppGroupStore.load()
        cfg.enabled = false
        AppGroupStore.save(cfg)
        AppGroupStore.writeExtensionOverride(false)
        AppGroupStore.logAction("VPN_CONNECT", details: "starting tunnel with enabled=false (pure passthrough until FakeLag ON)")

        if let mgr = manager {
            mgr.isEnabled = true
            if let proto = mgr.protocolConfiguration as? NETunnelProviderProtocol {
                proto.providerBundleIdentifier = extBundleID
                proto.serverAddress = "127.0.0.1"
                proto.disconnectOnSleep = false
                // includeAllNetworks=true disables the system's automatic
                // exclusion of the provider's own traffic -> relay sockets loop
                // into our own tunnel -> ENETDOWN -> tunnel dies in seconds.
                proto.includeAllNetworks = false
                if #available(iOS 14.2, *) { proto.enforceRoutes = false }
            }
            mgr.saveToPreferences { [weak self] err in
                DispatchQueue.main.async {
                    if let err = err {
                        self?.lastError = "Save: \(err.localizedDescription)"
                        AppGroupStore.logAction("VPN_SAVE_FAIL", details: "\(err.localizedDescription) (code \((err as NSError).code))", level: "ERROR")
                        return
                    }
                    do {
                        try mgr.connection.startVPNTunnel()
                        AppGroupStore.logAction("VPN_START", details: "startVPNTunnel() called")
                    } catch {
                        self?.lastError = "Start: \(error.localizedDescription)"
                        AppGroupStore.logAction("VPN_START_FAIL", details: error.localizedDescription, level: "ERROR")
                    }
                }
            }
        } else {
            AppGroupStore.logAction("VPN_CONNECT", details: "no manager yet → creating")
            createVPN()
        }
    }

    private func createVPN() {
        let mgr = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = extBundleID
        proto.serverAddress = "HybridFakeLag"
        proto.disconnectOnSleep = false
        // See connectVPN(): includeAllNetworks/enforceRoutes kill the tunnel.
        proto.includeAllNetworks = false
        if #available(iOS 14.2, *) { proto.enforceRoutes = false }
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "Hybrid FakeLag"
        mgr.isEnabled = true
        mgr.saveToPreferences { [weak self] err in
            DispatchQueue.main.async {
                if let err = err {
                    self?.lastError = "Create: \(err.localizedDescription)"
                    AppGroupStore.logAction("VPN_CREATE_FAIL", details: "\(err.localizedDescription) (code \((err as NSError).code))", level: "ERROR")
                    return
                }
                AppGroupStore.logAction("VPN_CREATE", details: "created manager")
                self?.loadVPN()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.connectVPN() }
            }
        }
    }

    func disconnectVPN() {
        manager?.connection.stopVPNTunnel()
        isBlocking = false
        var cfg = AppGroupStore.load()
        cfg.enabled = false
        AppGroupStore.save(cfg)
        AppGroupStore.writeExtensionOverride(false)
        AppGroupStore.logAction("VPN_DISCONNECT", details: "stopVPNTunnel() called, enabled=false saved")
    }

    func toggleBlocking() {
        if isProcessing { return }
        isProcessing = true
        isBlocking.toggle()
        saveConfig()                      // persists enabled=... for the config watcher
        AppGroupStore.writeExtensionOverride(isBlocking)  // instant override file

        // Poke the provider directly so the change applies within ms instead of
        // waiting for the next config-poll tick.
        if let mgr = manager, mgr.connection.status == .connected {
            let session = mgr.connection as? NETunnelProviderSession
            let msg = isBlocking ? "enable" : "disable"
            if let data = msg.data(using: .utf8) {
                do {
                    try session?.sendProviderMessage(data) { reply in
                        let replyStr = reply.flatMap { String(data: $0, encoding: .utf8) } ?? "(no reply)"
                        AppGroupStore.logAction("PROVIDER_MSG", details: "sent '\(msg)' reply=\(replyStr)")
                    }
                } catch {
                    AppGroupStore.logAction("PROVIDER_MSG_FAIL", details: "\(msg): \(error.localizedDescription)", level: "WARN")
                }
            }
        }
        if !isBlocking {
            // Simulation OFF → the extension releases everything it held.
            if let mgr = manager, mgr.connection.status == .connected,
               let session = mgr.connection as? NETunnelProviderSession,
               let data = "disable".data(using: .utf8) {
                try? session.sendProviderMessage(data) { _ in }
            }
        }
        AppGroupStore.logAction(isBlocking ? "BLOCK_ENABLE" : "BLOCK_DISABLE", details: "mode=\(mode) dir=\(direction) proto=\(protoFilter) target=\(selectedProcess?.displayName ?? "GLOBAL")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.isProcessing = false }
    }

    /// Pulls a live stats snapshot from the tunnel (handleAppMessage "getstats").
    func refreshStats() {
        guard let mgr = manager, mgr.connection.status == .connected,
              let session = mgr.connection as? NETunnelProviderSession,
              let data = "getstats".data(using: .utf8) else { return }
        do {
            try session.sendProviderMessage(data) { [weak self] reply in
                guard let self = self, let reply = reply,
                      let str = String(data: reply, encoding: .utf8) else { return }
                DispatchQueue.main.async { self.lastStats = str }
                AppGroupStore.logAction("STATS_POLL", details: str)
            }
        } catch {
            AppGroupStore.logAction("STATS_POLL_FAIL", details: error.localizedDescription, level: "WARN")
        }
    }

    func selectProcess(_ proc: ProcessInfoModel?) {
        selectedProcess = proc
        saveConfig()
        AppGroupStore.logAction("SELECT_PID", details: proc == nil ? "GLOBAL" : "\(proc!.displayName) pid=\(proc!.pid) bundle=\(proc!.bundleID)")
    }
}

// Swift version of ProcessManager for socket dump (proc_pidfdinfo)
class ProcessManagerSwift {
    func dumpSocketsForPID(_ pid: Int32) -> [SocketEntry] {
        var entries: [SocketEntry] = []
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if bufSize <= 0 { return [] }
        let fdCount = bufSize / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
        let actual = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufSize)
        let actualCount = actual / MemoryLayout<proc_fdinfo>.size
        for j in 0..<actualCount {
            if fds[j].proc_fdtype != PROX_FDTYPE_SOCKET { continue }
            var sockInfo = socket_fdinfo()
            let rc = proc_pidfdinfo(pid, fds[j].proc_fd, PROC_PIDFDSOCKETINFO, &sockInfo, Int32(MemoryLayout<socket_fdinfo>.size))
            if rc != MemoryLayout<socket_fdinfo>.size { continue }
            let family = sockInfo.psi.soi_family
            if family != AF_INET { continue }
            let sockType = sockInfo.psi.soi_type
            let protoStr = sockType == SOCK_STREAM ? "tcp" : (sockType == SOCK_DGRAM ? "udp" : "")
            if protoStr.isEmpty { continue }
            let ini = sockInfo.psi.soi_proto.pri_in
            let localPort = UInt16(bigEndian: ini.insi_lport)
            let remotePort = UInt16(bigEndian: ini.insi_fport)
            var remoteIP = ""
            var addr = ini.insi_faddr.ina_46
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
            remoteIP = String(cString: buf)
            if remoteIP.isEmpty || remoteIP == "0.0.0.0" { continue }
            entries.append(SocketEntry(localPort: localPort, remotePort: remotePort, remoteIP: remoteIP, proto: protoStr))
        }
        return entries
    }
}
