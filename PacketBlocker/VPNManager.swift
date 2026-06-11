import NetworkExtension
import SwiftUI

class VPNManager: ObservableObject {
    @Published var isVPNConnected = false
    @Published var lastError: String?
    
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    
    private let extensionBundleID = "com.tenban.PacketBlocker.extension"  // ← SỬA THEO PROJECT CỦA BẠN
    
    init() {
        loadVPNConfiguration()
        setupStatusObserver()
    }
    
    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setupStatusObserver() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateStatus()
        }
    }
    
    private func updateStatus() {
        DispatchQueue.main.async { [weak self] in
            self?.isVPNConnected = self?.manager?.connection.status == .connected
        }
    }
    
    private func loadVPNConfiguration() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.lastError = "Load error: \(error.localizedDescription)"
                return
            }
            self.manager = managers?.first
            self.updateStatus()
        }
    }
    
    func connectVPN() {
        if let manager = manager {
            startExistingVPN(manager: manager)
        } else {
            createAndStartVPN()
        }
    }
    
    // Nút Block sẽ reconnect để áp dụng block packets
    func toggleBlocking() {
        guard isVPNConnected else {
            lastError = "Connect VPN trước"
            return
        }
        disconnectVPN()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.connectVPN()
        }
    }
    
    func disconnectVPN() {
        manager?.connection.stopVPNTunnel()
        lastError = nil
    }
    
    private func startExistingVPN(manager: NETunnelProviderManager) {
        do {
            try manager.connection.startVPNTunnel()
            lastError = nil
        } catch {
            lastError = "Start error: \(error.localizedDescription)"
        }
    }
    
    private func createAndStartVPN() {
        let mgr = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        
        proto.providerBundleIdentifier = extensionBundleID
        proto.serverAddress = "PacketBlocker"
        proto.disconnectOnSleep = false
        
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "Packet Blocker"
        mgr.isEnabled = true
        
        mgr.saveToPreferences { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.lastError = "Save error: \(error.localizedDescription)"
                return
            }
            
            mgr.loadFromPreferences { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.lastError = "Load error: \(error.localizedDescription)"
                    return
                }
                self.manager = mgr
                do {
                    try mgr.connection.startVPNTunnel()
                } catch {
                    self.lastError = "Start tunnel error: \(error.localizedDescription)"
                }
            }
        }
    }
}