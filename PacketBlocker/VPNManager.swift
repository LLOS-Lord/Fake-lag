import NetworkExtension
import SwiftUI

class VPNManager: ObservableObject {
    @Published var isVPNConnected = false
    @Published var isBlocking = false
    @Published var isProcessingCommand = false
    @Published var lastError: String?
    
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    
    // ⚠️ SỬA Bundle ID cho đúng project của bạn
    private let extensionBundleID = "com.tenban.PacketBlocker.extension"
    
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
            startExistingVPN(manager: manager)
        } else {
            createAndStartVPN()
        }
    }
    
    func disconnectVPN() {
        manager?.connection.stopVPNTunnel()
        isBlocking = false
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
                    self.lastError = "Load after save error: \(error.localizedDescription)"
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
    
    func toggleBlocking() {
        guard let session = manager?.connection as? NETunnelProviderSession, isVPNConnected else {
            lastError = "VPN chưa kết nối"
            return
        }
        guard !isProcessingCommand else { return }
        
        isProcessingCommand = true
        let command = isBlocking ? "disableBlocking" : "enableBlocking"
        
        do {
            try session.sendProviderMessage(Data(command.utf8)) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isProcessingCommand = false
                    if let response = response, String(data: response, encoding: .utf8) == "ok" {
                        self.isBlocking.toggle()
                        self.lastError = nil
                    } else {
                        self.lastError = "Extension did not respond properly"
                    }
                }
            }
        } catch {
            isProcessingCommand = false
            lastError = "Send message error: \(error.localizedDescription)"
        }
    }
}
