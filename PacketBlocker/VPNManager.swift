import NetworkExtension
import SwiftUI

class VPNManager: ObservableObject {
    static let shared = VPNManager()
    
    @Published var isVPNConnected = false
    @Published var isBlocking = false
    @Published var isProcessing = false
    @Published var lastError: String?
    @Published var selectedProcess: ProcessInfoModel?
    
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
        let main = Bundle.main.bundleIdentifier ?? "com.ban.PacketBlocker"
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
            cfg.targetSockets = [
                SocketEntry(localPort: 54321, remotePort: 443, remoteIP: "8.8.8.8", proto: "tcp"),
                SocketEntry(localPort: 54322, remotePort: 443, remoteIP: "1.1.1.1", proto: "udp")
            ]
        } else {
            cfg.targetBundleID = ""
            cfg.targetPID = 0
            cfg.targetSockets = []
        }
        AppGroupStore.save(cfg)
        AppGroupStore.logAction("CONFIG_SAVE", details: "mode=\(mode) dir=\(direction) proto=\(protoFilter) target=\(cfg.targetBundleID) pid=\(cfg.targetPID) latency=\(latencyMs) ratio=\(captureRatio)")
    }
    
    func connectVPN() {
        var cfg = AppGroupStore.load()
        cfg.enabled = false
        AppGroupStore.save(cfg)
        
        if let mgr = manager {
            mgr.isEnabled = true
            if let proto = mgr.protocolConfiguration as? NETunnelProviderProtocol {
                proto.providerBundleIdentifier = extBundleID
                proto.serverAddress = "127.0.0.1"
                proto.disconnectOnSleep = false
                if #available(iOS 14.2, *) {
                    proto.includeAllNetworks = true
                    proto.excludeLocalNetworks = false
                    proto.enforceRoutes = true
                }
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
        if #available(iOS 14.2, *) {
            proto.includeAllNetworks = true
            proto.excludeLocalNetworks = false
            proto.enforceRoutes = true
        }
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
