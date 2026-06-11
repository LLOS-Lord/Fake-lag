import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var isBlocking = false
    private var packetLoopRunning = false
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        NSLog("🚀 [Provider] startTunnel called")
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = []
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                NSLog("❌ Set initial failed: \(error)")
                completionHandler(error)
            } else {
                NSLog("✅ Tunnel ready")
                completionHandler(nil)
            }
        }
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        
        NSLog("📩 Received command: \(command)")
        
        // Trả lời SIÊU NHANH + đồng bộ
        completionHandler?("ok".data(using: .utf8))
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            switch command {
            case "enableBlocking":
                self?.performEnableBlocking()
            case "disableBlocking":
                self?.performDisableBlocking()
            default:
                break
            }
        }
    }
    
    private func performEnableBlocking() {
        guard !isBlocking else { return }
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                NSLog("❌ Enable failed: \(error)")
            } else {
                self?.isBlocking = true
                self?.startPacketDropping()
                NSLog("✅ Blocking ENABLED")
            }
        }
    }
    
    private func performDisableBlocking() {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = []
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            self?.isBlocking = false
            self?.packetLoopRunning = false
            NSLog(error == nil ? "✅ Blocking DISABLED" : "❌ Disable failed: \(String(describing: error))")
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
        
        packetFlow.readPackets { [weak self] packets, _ in
            // Giảm tải CPU
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.01) {
                self?.readPacketsLoop()
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("🛑 Stop tunnel: \(reason)")
        isBlocking = false
        packetLoopRunning = false
        completionHandler()
    }
}
