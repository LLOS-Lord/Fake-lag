import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var isBlocking = false
    private var packetLoopRunning = false
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        NSLog("🚀 startTunnel called")
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = []   // Ban đầu cho phép traffic (tunnel active)
        
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                NSLog("❌ Set settings failed: \(error)")
                completionHandler(error)
            } else {
                NSLog("✅ Tunnel started - Ready for blocking")
                completionHandler(nil)
            }
        }
    }
    
    // Trả lời siêu nhanh để tránh lỗi "did not respond properly"
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        
        NSLog("📩 Received: \(command)")
        completionHandler?("ok".data(using: .utf8))  // Trả lời ngay lập tức
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            switch command {
            case "enableBlocking":
                self?.enableBlocking()
            case "disableBlocking":
                self?.disableBlocking()
            default:
                break
            }
        }
    }
    
    private func enableBlocking() {
        guard !isBlocking else { return }
        isBlocking = true
        startPacketDropping()
        NSLog("🔒 Blocking ENABLED - Packets are being dropped")
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
        
        // Đọc và DROP packets (fake lag)
        packetFlow.readPackets { [weak self] packets, protocols in
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
