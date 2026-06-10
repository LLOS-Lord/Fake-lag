import NetworkExtension
import SwiftUI

class VPNManager: ObservableObject {
    @Published var isVPNConnected = false
    @Published var isBlocking = false
    @Published var isProcessingCommand = false
    @Published var lastError: String?
    
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    
    private let extensionBundleID = "com.tenban.PacketBlocker.PacketBlockerExtension"
    
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
            
            print("📊 VPN Status: \(self.manager?.connection.status.rawValue ?? -1)")
            
            if wasConnected && !self.isVPNConnected {
                self.isBlocking = false
                self.isProcessingCommand = false
            }
            
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
                print("❌ Load error: \(error.localizedDescription)")
                return
            }
            self.manager = managers?.first
            self.updateStatus()
            print("✅ Loaded VPN config: \(self.manager != nil ? "exists" : "none")")
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
        print("🔄 Attempting to start existing VPN...")
        do {
            try manager.connection.startVPNTunnel()
            lastError = nil
            print("✅ startVPNTunnel() called successfully")
        } catch {
            lastError = "Start error: \(error.localizedDescription)"
            print("❌ Start error: \(error.localizedDescription)")
        }
    }
    
    private func createAndStartVPN() {
        print("🔧 Creating new VPN configuration...")
        print("   Extension Bundle ID: \(extensionBundleID)")
        
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
                self.lastError = "❌ Save failed: \(error.localizedDescription)"
                print("❌ Save error: \(error.localizedDescription)")
                return
            }
            
            print("✅ VPN configuration saved")
            
            // Critical: Load the configuration from preferences
            mgr.loadFromPreferences { [weak self] error in
                guard let self = self else { return }
                
                if let error = error {
                    self.lastError = "❌ Load after save failed: \(error.localizedDescription)"
                    print("❌ Load after save error: \(error.localizedDescription)")
                    return
                }
                
                print("✅ VPN configuration loaded from preferences")
                self.manager = mgr
                
                // Now try to start the tunnel
                do {
                    try mgr.connection.startVPNTunnel()
                    print("✅ startVPNTunnel() called successfully")
                } catch {
                    self.lastError = "❌ Connection failed: \(error.localizedDescription)"
                    print("❌ startVPNTunnel() error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func toggleBlocking() {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            lastError = "❌ No VPN session available"
            print("❌ No VPN session")
            return
        }
        
        guard isVPNConnected else {
            lastError = "❌ VPN not connected"
            print("❌ VPN not connected")
            return
        }
        
        guard !isProcessingCommand else {
            print("⏳ Already processing command")
            return
        }
        
        isProcessingCommand = true
        let command = isBlocking ? "disableBlocking" : "enableBlocking"
        
        print("📤 Sending command to extension: \(command)")
        
        do {
            try session.sendProviderMessage(Data(command.utf8)) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isProcessingCommand = false
                    
                    if let response = response,
                       let responseString = String(data: response, encoding: .utf8) {
                        print("📩 Extension response: \(responseString)")
                        
                        if responseString == "ok" {
                            self.isBlocking.toggle()
                            self.lastError = nil
                            print("✅ Command executed successfully")
                        } else {
                            self.lastError = "❌ Extension error: \(responseString)"
                        }
                    } else {
                        self.lastError = "❌ No response from extension"
                        print("❌ No response from extension")
                    }
                }
            }
        } catch {
            self.isProcessingCommand = false
            self.lastError = "❌ Send error: \(error.localizedDescription)"
            print("❌ Send message error: \(error.localizedDescription)")
        }
    }
}
