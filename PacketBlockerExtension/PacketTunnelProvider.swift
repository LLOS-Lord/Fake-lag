import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    // MARK: - Properties
    
    private var isBlocking = false
    private var isReadingPackets = false
    
    // MARK: - Tunnel Lifecycle
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        print("🚀 PacketTunnelProvider: startTunnel called")
        
        // Start with non-blocking mode (no routes)
        applyNonBlockingSettings { error in
            if let error = error {
                print("❌ Failed to apply initial settings: \(error.localizedDescription)")
                completionHandler(error)
            } else {
                print("✅ Tunnel started successfully in non-blocking mode")
                completionHandler(nil)
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        print("🛑 PacketTunnelProvider: stopTunnel called with reason: \(reason.rawValue)")
        isReadingPackets = false
        isBlocking = false
        completionHandler()
    }
    
    // MARK: - App Communication
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            print("❌ Invalid message data")
            completionHandler?(nil)
            return
        }
        
        print("📩 Received command from app: \(command)")
        
        switch command {
        case "enableBlocking":
            enableBlocking { success in
                let response = success ? "ok" : "error"
                completionHandler?(Data(response.utf8))
                print("📤 Response sent: \(response)")
            }
            
        case "disableBlocking":
            disableBlocking { success in
                let response = success ? "ok" : "error"
                completionHandler?(Data(response.utf8))
                print("📤 Response sent: \(response)")
            }
            
        default:
            print("❌ Unknown command: \(command)")
            completionHandler?(nil)
        }
    }
    
    // MARK: - Blocking Mode
    
    private func enableBlocking(completion: @escaping (Bool) -> Void) {
        guard !isBlocking else {
            print("⚠️ Already in blocking mode")
            completion(true)
            return
        }
        
        print("🔒 Enabling blocking mode...")
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        
        // IPv4 configuration
        let ipv4Settings = NEIPv4Settings(
            addresses: ["10.8.0.2"],
            subnetMasks: ["255.255.255.0"]
        )
        // Route ALL traffic through TUN interface
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4Settings
        
        // No DNS needed for blocking
        settings.dnsSettings = NEDNSSettings(servers: [])
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                print("❌ Failed to enable blocking: \(error.localizedDescription)")
                completion(false)
            } else {
                print("✅ Blocking mode enabled")
                self?.isBlocking = true
                self?.startDroppingPackets()
                completion(true)
            }
        }
    }
    
    // MARK: - Non-Blocking Mode
    
    private func disableBlocking(completion: @escaping (Bool) -> Void) {
        guard isBlocking else {
            print("⚠️ Already in non-blocking mode")
            completion(true)
            return
        }
        
        print("🔓 Disabling blocking mode...")
        
        applyNonBlockingSettings { [weak self] error in
            if let error = error {
                print("❌ Failed to disable blocking: \(error.localizedDescription)")
                completion(false)
            } else {
                print("✅ Non-blocking mode enabled")
                self?.isBlocking = false
                self?.isReadingPackets = false
                completion(true)
            }
        }
    }
    
    private func applyNonBlockingSettings(completion: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        
        // IPv4 configuration with NO routes
        let ipv4Settings = NEIPv4Settings(
            addresses: ["10.8.0.2"],
            subnetMasks: ["255.255.255.0"]
        )
        // Empty routes = no traffic goes through TUN
        ipv4Settings.includedRoutes = []
        settings.ipv4Settings = ipv4Settings
        
        // No DNS
        settings.dnsSettings = NEDNSSettings(servers: [])
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings, completionHandler: completion)
    }
    
    // MARK: - Packet Dropping
    
    private func startDroppingPackets() {
        guard !isReadingPackets else {
            print("⚠️ Already reading/dropping packets")
            return
        }
        
        print("📦 Starting packet drop loop...")
        isReadingPackets = true
        dropPackets()
    }
    
    private func dropPackets() {
        guard isReadingPackets, isBlocking else {
            print("🛑 Stopping packet drop loop")
            return
        }
        
        packetFlow.readPackets { [weak self] packets, protocols in
            // Drop all packets - just read and discard
            if packets.count > 0 {
                // Optional: log for debugging
                // print("🚫 Dropped \(packets.count) packets")
            }
            
            // Continue reading
            self?.dropPackets()
        }
    }
}