import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var isBlocking = false
    private var isDropping = false
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        NSLog("🚀 PacketTunnelProvider: startTunnel called")
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4Settings = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = []
        settings.ipv4Settings = ipv4Settings
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                NSLog("❌ Set settings failed: \(error.localizedDescription)")
                completionHandler(error)
            } else {
                NSLog("✅ Tunnel started successfully")
                completionHandler(nil)
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("🛑 stopTunnel called with reason: \(reason)")
        isBlocking = false
        isDropping = false
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        
        NSLog("📩 Received command: \(command)")
        
        switch command {
        case "enableBlocking":
            enableBlocking { success in
                let resp = success ? "ok" : "error"
                completionHandler?(resp.data(using: .utf8))
            }
        case "disableBlocking":
            disableBlocking { success in
                let resp = success ? "ok" : "error"
                completionHandler?(resp.data(using: .utf8))
            }
        default:
            completionHandler?(nil)
        }
    }
    
    private func enableBlocking(completion: @escaping (Bool) -> Void) {
        guard !isBlocking else { completion(true); return }
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
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
        
        // CẬP NHẬT 1: Tắt cờ ngay lập tức để ngắt vòng lặp readPacketsLoop
        self.isBlocking = false
        self.isDropping = false
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = []
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                NSLog("❌ Disable failed: \(error.localizedDescription)")
                completion(false)
            } else {
                completion(true)
            }
        }
    }
    
    private func startDroppingPackets() {
        guard !isDropping else { return }
        isDropping = true
        readPacketsLoop()
    }
    
    private func readPacketsLoop() {
        guard isBlocking && isDropping else {
            isDropping = false
            return
        }
        
        // CẬP NHẬT 2: Đọc trực tiếp và không đẩy vào DispatchQueue.main
        packetFlow.readPackets { [weak self] _, _ in
            self?.readPacketsLoop()
        }
    }
}
