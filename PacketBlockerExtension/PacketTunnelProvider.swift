import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var packetLoopRunning = false
    private var isBlocking = true  // Default block khi start
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        NSLog("🚀 startTunnel called")
        
        configureTunnel(blocking: true, completion: completionHandler)
    }
    
    private func configureTunnel(blocking: Bool, completion: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        
        if blocking {
            ipv4.includedRoutes = [NEIPv4Route.default()]
            NSLog("🔒 Blocking mode")
        } else {
            ipv4.includedRoutes = []
            NSLog("✅ Allowed mode")
        }
        
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                NSLog("❌ Set settings failed: \(error)")
                completion(error)
            } else {
                self?.isBlocking = blocking
                if blocking {
                    self?.startPacketDropping()
                } else {
                    self?.packetLoopRunning = false
                }
                NSLog("✅ Tunnel configured - Blocking: \(blocking)")
                completion(nil)
            }
        }
    }
    
    private func startPacketDropping() {
        guard !packetLoopRunning else { return }
        packetLoopRunning = true
        readPacketsLoop()
    }
    
    private func readPacketsLoop() {
        guard packetLoopRunning else { return }
        
        packetFlow.readPackets { [weak self] _, _ in
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.01) {
                self?.readPacketsLoop()
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        packetLoopRunning = false
        completionHandler()
    }
}