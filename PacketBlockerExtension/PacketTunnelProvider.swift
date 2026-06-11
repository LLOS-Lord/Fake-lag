import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var isBlocking = false
    private var packetLoopRunning = false
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        NSLog("🚀 [Provider] startTunnel called")
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = []  // Ban đầu cho phép traffic
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                NSLog("❌ [Provider] Set initial settings failed: \(error.localizedDescription)")
                completionHandler(error)
            } else {
                NSLog("✅ [Provider] Tunnel started")
                completionHandler(nil)
            }
        }
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            NSLog("⚠️ Invalid command")
            completionHandler?(nil)
            return
        }
        
        NSLog("📩 [Provider] Received: \(command)")
        
        // Trả lời NGAY để tránh lỗi "did not respond properly"
        let response = "ok".data(using: .utf8)
        completionHandler?(response)
        
        // Xử lý command sau khi đã trả lời
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            switch command {
            case "enableBlocking":
                self?.enableBlocking()
            case "disableBlocking":
                self?.disableBlocking()
            default:
                NSLog("⚠️ Unknown command: \(command)")
            }
        }
    }
    
    private func enableBlocking() {
        guard !isBlocking else { return }
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]  // Block all
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                NSLog("❌ Enable blocking failed: \(error.localizedDescription)")
            } else {
                self?.isBlocking = true
                self?.startPacketDropping()
                NSLog("✅ Blocking ENABLED")
            }
        }
    }
    
    private func disableBlocking() {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = []
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            self?.isBlocking = false
            self?.packetLoopRunning = false
            if let error = error {
                NSLog("❌ Disable failed: \(error.localizedDescription)")
            } else {
                NSLog("✅ Blocking DISABLED")
            }
        }
    }
    
    private func startPacketDropping() {
        guard !packetLoopRunning else { return }
        packetLoopRunning = true
        readPacketsLoop()
    }
    
    private func readPacketsLoop() {
        guard packetLoopRunning && isBlocking else {
            packetLoopRunning = false
            return
        }
        
        packetFlow.readPackets { [weak self] _, _ in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.008) {
                self?.readPacketsLoop()
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("🛑 stopTunnel - reason: \(reason)")
        isBlocking = false
        packetLoopRunning = false
        completionHandler()
    }
}
