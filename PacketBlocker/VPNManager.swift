import NetworkExtension
import SwiftUI

class VPNManager: ObservableObject {
    @Published var isVPNConnected = false
    @Published var isBlocking = false
    @Published var isProcessingCommand = false
    
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    
    init() {
        loadVPNConfiguration()
        setupStatusObserver()
    }
    
    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Setup
    
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
            
            // Reset blocking state when VPN disconnects
            if wasConnected && !self.isVPNConnected {
                self.isBlocking = false
                self.isProcessingCommand = false
            }
        }
    }
    
    // MARK: - VPN Configuration
    
    func loadVPNConfiguration() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ Load VPN config error: \(error.localizedDescription)")
                return
            }
            
            if let managers = managers, !managers.isEmpty {
                self.manager = managers.first
                print("✅ Loaded existing VPN configuration")
            } else {
                print("ℹ️ No existing VPN configuration found")
            }
            
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
        guard let manager = manager else { return }
        manager.connection.stopVPNTunnel()
        print("🔌 VPN disconnecting...")
    }
    
    private func startExistingVPN(manager: NETunnelProviderManager) {
        do {
            try manager.connection.startVPNTunnel()
            print("🔌 Starting existing VPN...")
        } catch {
            print("❌ Failed to start VPN: \(error.localizedDescription)")
        }
    }
    
    private func createAndStartVPN() {
        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        
        // IMPORTANT: Change this to your actual extension bundle ID
        proto.providerBundleIdentifier = "com.yourcompany.PacketBlocker.extension"
        proto.serverAddress = "PacketBlocker"
        proto.disconnectOnSleep = false
        
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Packet Blocker"
        manager.isEnabled = true
        
        print("🛠 Creating new VPN configuration...")
        
        manager.saveToPreferences { [weak self] error in
            if let error = error {
                print("❌ Save VPN config error: \(error.localizedDescription)")
                return
            }
            
            print("✅ VPN configuration saved")
            
            manager.loadFromPreferences { [weak self] error in
                if let error = error {
                    print("❌ Load VPN config error: \(error.localizedDescription)")
                    return
                }
                
                self?.manager = manager
                self?.startExistingVPN(manager: manager)
            }
        }
    }
    
    // MARK: - Blocking Control
    
    func toggleBlocking() {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            print("❌ No VPN session available")
            return
        }
        
        guard isVPNConnected else {
            print("❌ VPN not connected")
            return
        }
        
        guard !isProcessingCommand else {
            print("⚠️ Already processing a command")
            return
        }
        
        isProcessingCommand = true
        
        let command = isBlocking ? "disableBlocking" : "enableBlocking"
        print("📤 Sending command: \(command)")
        
        do {
            try session.sendProviderMessage(Data(command.utf8)) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isProcessingCommand = false
                    
                    if let response = response,
                       let responseString = String(data: response, encoding: .utf8),
                       responseString == "ok" {
                        self.isBlocking.toggle()
                        print("✅ Command successful: \(command)")
                    } else {
                        print("❌ Command failed: \(command)")
                    }
                }
            }
        } catch {
            isProcessingCommand = false
            print("❌ Send message error: \(error.localizedDescription)")
        }
    }
}