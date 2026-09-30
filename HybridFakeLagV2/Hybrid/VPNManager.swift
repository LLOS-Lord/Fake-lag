import NetworkExtension
import SwiftUI

class VPNManager: ObservableObject {
    static let shared = VPNManager()
    
    @Published var isVPNConnected = false
    @Published var isBlocking = false
    @Published var isProcessing = false
    @Published var lastError: String?
    @Published var selectedProcess: ProcessInfoModel?
    
    // Config
    @Published var mode: String = "hold"
    @Published var direction: String = "both"
    @Published var protoFilter: String = "both"
    @Published var latencyMs: Int = 350
    @Published var jitterMs: Int = 80
    @Published var bandwidthKbps: Int = 0
    @Published var captureRatio: Int = 100
    
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    
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
        loadVPN()
        setupObserver()
    }
    
    private func setupObserver() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateStatus()
        }
    }
    
    private func updateStatus() {
        DispatchQueue.main.async {
            let st = self.manager?.connection.status ?? .invalid
            self.isVPNConnected = (st == .connected)
            if !self.isVPNConnected { self.isBlocking = false }
        }
    }
    
    func loadVPN() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let e = error { self.lastError = "Load: \(e.localizedDescription)"; return }
            self.manager = managers?.first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.extBundleID }) ?? managers?.first
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
            let pm = ProcessManagerSwift()
            cfg.targetSockets = pm.dumpSocketsForPID(proc.pid)
        } else {
            cfg.targetBundleID = ""
            cfg.targetPID = 0
            cfg.targetSockets = []
        }
        AppGroupStore.save(cfg)
        AppGroupStore.logAction("CONFIG_SAVE", details: "mode=\(mode) dir=\(direction) proto=\(protoFilter) target=\(cfg.targetBundleID) pid=\(cfg.targetPID) latency=\(latencyMs) ratio=\(captureRatio)")
    }
    
    func connectVPN() {
        // Start with disabled to avoid immediate lag
        var cfg = AppGroupStore.load()
        cfg.enabled = false
        AppGroupStore.save(cfg)
        
        if let mgr = manager {
            mgr.isEnabled = true
            if let proto = mgr.protocolConfiguration as? NETunnelProviderProtocol {
                proto.providerBundleIdentifier = extBundleID
                proto.serverAddress = "127.0.0.1"
                proto.disconnectOnSleep = false
                proto.includeAllNetworks = true
                proto.excludeLocalNetworks = false
                proto.enforceRoutes = true
            }
            mgr.saveToPreferences { [weak self] err in
                DispatchQueue.main.async {
                    if let err = err { self?.lastError = "Save: \(err.localizedDescription)"; return }
                    do {
                        try mgr.connection.startVPNTunnel()
                        AppGroupStore.logAction("VPN_CONNECT", details: "starting tunnel")
                    } catch {
                        self?.lastError = "Start: \(error.localizedDescription)"
                        AppGroupStore.logAction("VPN_CONNECT_FAIL", details: error.localizedDescription)
                    }
                }
            }
        } else {
            createVPN()
        }
    }
    
    private func createVPN() {
        let mgr = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = extBundleID
        proto.serverAddress = "HybridFakeLag"
        proto.disconnectOnSleep = false
        proto.includeAllNetworks = true
        proto.excludeLocalNetworks = false
        proto.enforceRoutes = true
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "Hybrid FakeLag"
        mgr.isEnabled = true
        mgr.saveToPreferences { [weak self] err in
            DispatchQueue.main.async {
                if let err = err { self?.lastError = "Create: \(err.localizedDescription)"; return }
                AppGroupStore.logAction("VPN_CREATE", details: "created manager")
                self?.loadVPN()
                DispatchQueue.main.asyncAfter(deadline: .now()+0.6) { self?.connectVPN() }
            }
        }
    }
    
    func disconnectVPN() {
        manager?.connection.stopVPNTunnel()
        isBlocking = false
        var cfg = AppGroupStore.load()
        cfg.enabled = false
        AppGroupStore.save(cfg)
        AppGroupStore.logAction("VPN_DISCONNECT", details: "stopped tunnel")
    }
    
    func toggleBlocking() {
        if isProcessing { return }
        isProcessing = true
        isBlocking.toggle()
        saveConfig()
        if let mgr = manager, mgr.connection.status == .connected {
            let session = mgr.connection as? NETunnelProviderSession
            let msg = isBlocking ? "enable" : "disable"
            if let data = msg.data(using: .utf8) {
                try? session?.sendProviderMessage(data) { _ in }
            }
        }
        AppGroupStore.logAction(isBlocking ? "BLOCK_ENABLE" : "BLOCK_DISABLE", details: "mode=\(mode) target=\(selectedProcess?.displayName ?? "GLOBAL")")
        DispatchQueue.main.asyncAfter(deadline: .now()+0.3) { self.isProcessing = false }
    }
    
    func selectProcess(_ proc: ProcessInfoModel?) {
        selectedProcess = proc
        saveConfig()
        AppGroupStore.logAction("SELECT_PID", details: proc == nil ? "GLOBAL" : "\(proc!.displayName) pid=\(proc!.pid) bundle=\(proc!.bundleID)")
    }
}

// Swift version of ProcessManager for socket dump
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
