import NetworkExtension
import SwiftUI

class VPNManager: ObservableObject {
    @Published var isVPNConnected = false
    @Published var isBlocking = false
    @Published var isProcessingCommand = false
    @Published var lastError: String?
    
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    
   private let extensionBundleID = "com.tenban.PacketBlocker.PacketBlockerExtension" // ← sửa
    
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
            let wasConnected = self.isVPNConnected
            self.isVPNConnected = self.manager?.connection.status == .connected
            if wasConnected && !self.isVPNConnected {
                self.isBlocking = false
                self.isProcessingCommand = false
            }
            // Lưu trạng thái lỗi nếu có
            if let mgr = self.manager, mgr.connection.status == .invalid {
                self.lastError = "VPN configuration invalid. Try reinstalling app."
            }
        }
    }
    
    func loadVPNConfiguration() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.lastError = "Load error: \(error.localizedDescription)"
                return
            }
            self.manager = managers?.first
            self.updateStatus()
            print("Loaded VPN config: \(self.manager != nil ? "exists" : "none")")
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
        lastError = nil
    }
    
    private func startExistingVPN(manager: NETunnelProviderManager) {
        do {
            try manager.connection.startVPNTunnel()
            lastError = nil
            print("Started existing VPN tunnel")
        } catch {
            lastError = "Start error: \(error.localizedDescription)"
            print("❌ \(lastError!)")
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
        
        print("Creating new VPN configuration...")
        
        mgr.saveToPreferences { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.lastError = "Save error: \(error.localizedDescription)"
                print("❌ \(self.lastError!)")
                return
            }
            print("VPN configuration saved.")
            mgr.loadFromPreferences { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.lastError = "Load after save error: \(error.localizedDescription)"
                    print("❌ \(self.lastError!)")
                    return
                }
                self.manager = mgr
                do {
                    try mgr.connection.startVPNTunnel()
                    self.lastError = nil
                    print("✅ startVPNTunnel called successfully")
                } catch {
                    self.lastError = "Start tunnel error: \(error.localizedDescription)"
                    print("❌ \(self.lastError!)")
                }
            }
        }
    }
    
    func toggleBlocking() {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            lastError = "No VPN session"
            return
        }
        guard isVPNConnected else {
            lastError = "VPN not connected"
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
                    if let response = response,
                       let responseString = String(data: response, encoding: .utf8),
                       responseString == "ok" {
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
