import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var isBlocking = false
    private var packetLoopRunning = false
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        NSLog("🚀 [Provider] startTunnel called")
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = []                    // Ban đầu cho phép tất cả traffic
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                NSLog("❌ [Provider] Set settings failed: \(error.localizedDescription)")
                completionHandler(error)
            } else {
                NSLog("✅ [Provider] Tunnel started successfully")
                completionHandler(nil)
            }
        }
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            NSLog("⚠️ [Provider] Invalid command format")
            completionHandler?(nil)
            return
        }
        
        NSLog("📩 [Provider] Received command: \(command)")
        
        switch command {
        case "enableBlocking":
            enableBlocking { success in
                let response = success ? "ok" : "error"
                completionHandler?(response.data(using: .utf8))
            }
        case "disableBlocking":
            disableBlocking { success in
                let response = success ? "ok" : "error"
                completionHandler?(response.data(using: .utf8))
            }
        default:
            NSLog("⚠️ [Provider] Unknown command: \(command)")
            completionHandler?(nil)
        }
    }
    
    private func enableBlocking(completion: @escaping (Bool) -> Void) {
        guard !isBlocking else {
            completion(true)
            return
        }
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]   // Block tất cả
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                NSLog("❌ [Provider] Enable blocking failed: \(error.localizedDescription)")
                completion(false)
            } else {
                self?.isBlocking = true
                self?.startPacketDropping()
                NSLog("✅ [Provider] Blocking enabled")
                completion(true)
            }
        }
    }
    
    private func disableBlocking(completion: @escaping (Bool) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = []
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            self?.isBlocking = false
            self?.packetLoopRunning = false
            if let error = error {
                NSLog("❌ [Provider] Disable failed: \(error.localizedDescription)")
                completion(false)
            } else {
                NSLog("✅ [Provider] Blocking disabled")
                completion(true)
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
        
        packetFlow.readPackets { [weak self] packets, protocols in
            // Fake lag: drop packets với delay nhỏ
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.008) {
                self?.readPacketsLoop()
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("🛑 [Provider] stopTunnel called - reason: \(reason)")
        isBlocking = false
        packetLoopRunning = false
        completionHandler()
    }
}
