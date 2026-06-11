import NetworkExtension
import SwiftUI

class VPNManager: ObservableObject {
    @Published var isVPNConnected = false
    @Published var isBlocking = true      // Mặc định là Block khi connect
    @Published var lastError: String?
    
    private var manager: NETunnelProviderManager?
    private let extensionBundleID = "com.tenban.PacketBlocker.extension"  // ← SỬA THEO PROJECT CỦA BẠN
    
    init() {
        loadVPNConfiguration()
        setupStatusObserver()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupStatusObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateStatus),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }
    
    @objc private func updateStatus() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isVPNConnected = self.manager?.connection.status == .connected
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
            startExistingVPN(manager: manager, blocking: true)
        } else {
            createAndStartVPN(blocking: true)
        }
    }
    
    func toggleBlocking() {
        guard let manager = manager, isVPNConnected else {
            lastError = "VPN chưa kết nối"
            return
        }
        
        let newBlocking = !isBlocking
        disconnectVPN()  // Ngắt trước
        
        // Đợi một chút rồi tạo lại với chế độ mới
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.createAndStartVPN(blocking: newBlocking)
        }
    }
    
    func disconnectVPN() {
        manager?.connection.stopVPNTunnel()
        lastError = nil
    }
    
    private func startExistingVPN(manager: NETunnelProviderManager, blocking: Bool) {
        do {
            try manager.connection.startVPNTunnel()
            self.isBlocking = blocking
            lastError = nil
        } catch {
            lastError = "Start error: \(error.localizedDescription)"
        }
    }
    
    private func createAndStartVPN(blocking: Bool) {
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
                self.isBlocking = blocking
                do {
                    try mgr.connection.startVPNTunnel()
                    self.lastError = nil
                } catch {
                    self.lastError = "Start tunnel error: \(error.localizedDescription)"
                }
            }
        }
    }
}