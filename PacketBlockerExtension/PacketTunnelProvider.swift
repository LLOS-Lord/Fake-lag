import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var isBlocking = false
    private var isReadingPackets = false
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        NSLog("PacketTunnelProvider: startTunnel called")
        
        // Khởi tạo cấu hình mặc định (không chặn)
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4Settings = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = []   // Không route gì, để không ảnh hưởng mạng
        settings.ipv4Settings = ipv4Settings
        settings.dnsSettings = NEDNSSettings(servers: [])
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                NSLog("❌ Failed to set tunnel network settings: \(error.localizedDescription)")
                completionHandler(error)
            } else {
                NSLog("✅ Tunnel settings applied successfully")
                self.isBlocking = false
                completionHandler(nil)
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("PacketTunnelProvider: stopTunnel reason=\(reason.rawValue)")
        isReadingPackets = false
        isBlocking = false
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        NSLog("Received command: \(command)")
        
        switch command {
        case "enableBlocking":
            enableBlocking { success in
                completionHandler?(Data(success ? "ok" : "error".utf8))
            }
        case "disableBlocking":
            disableBlocking { success in
                completionHandler?(Data(success ? "ok" : "error".utf8))
            }
        default:
            completionHandler?(nil)
        }
    }
    
    private func enableBlocking(completion: @escaping (Bool) -> Void) {
        guard !isBlocking else { completion(true); return }
        NSLog("Enabling blocking...")
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4Settings = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4Settings
        settings.dnsSettings = NEDNSSettings(servers: [])
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                NSLog("❌ Enable blocking failed: \(error.localizedDescription)")
                completion(false)
            } else {
                self?.isBlocking = true
                self?.startDroppingPackets()
                completion(true)
            }
        }
    }
    
    private func disableBlocking(completion: @escaping (Bool) -> Void) {
        guard isBlocking else { completion(true); return }
        NSLog("Disabling blocking...")
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4Settings = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = []
        settings.ipv4Settings = ipv4Settings
        settings.dnsSettings = NEDNSSettings(servers: [])
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                NSLog("❌ Disable blocking failed: \(error.localizedDescription)")
                completion(false)
            } else {
                self?.isBlocking = false
                self?.isReadingPackets = false
                completion(true)
            }
        }
    }
    
    private func startDroppingPackets() {
        guard !isReadingPackets else { return }
        isReadingPackets = true
        dropPackets()
    }
    
    private func dropPackets() {
        guard isReadingPackets, isBlocking else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            // Bỏ qua mọi gói tin -> drop
            self?.dropPackets()
        }
    }
}