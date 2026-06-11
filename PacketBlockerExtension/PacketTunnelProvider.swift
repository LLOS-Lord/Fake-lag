import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var isBlocking = false
    private var packetLoopRunning = false
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        NSLog("🚀 [Provider] startTunnel called - Tunnel Active")
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = []  // Ban đầu cho phép traffic qua tunnel
        
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        
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
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        
        NSLog("📩 [Provider] Received command: \(command)")
        
        // Trả lời NGAY để tránh lỗi "Extension did not respond properly"
        completionHandler?("ok".data(using: .utf8))
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            switch command {
            case "enableBlocking":
                self?.enableBlocking()
            case "disableBlocking":
                self?.disableBlocking()
            default:
                NSLog("⚠️ Unknown command")
            }
        }
    }
    
    private func enableBlocking() {
        guard !isBlocking else { return }
        isBlocking = true
        startPacketDropping()
        NSLog("🔒 Blocking ENABLED - Packets dropped")
    }
    
    private func disableBlocking() {
        isBlocking = false
        packetLoopRunning = false
        NSLog("✅ Blocking DISABLED - Traffic allowed")
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
            // Drop packet + fake lag
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.012) {
                self?.readPacketsLoop()
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("🛑 Tunnel stopped")
        packetLoopRunning = false
        completionHandler()
    }
}
