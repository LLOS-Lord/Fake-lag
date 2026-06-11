import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var packetLoopRunning = false
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        NSLog("🚀 startTunnel - BLOCK PACKETS MODE")
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        
        // BLOCK tất cả network packets
        ipv4.includedRoutes = [NEIPv4Route.default()]
        
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                NSLog("❌ Set blocking failed: \(error.localizedDescription)")
                completionHandler(error)
            } else {
                NSLog("✅ Tunnel started + PACKETS BLOCKED")
                self?.startPacketDropping()
                completionHandler(nil)
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
        NSLog("🛑 Tunnel stopped")
        packetLoopRunning = false
        completionHandler()
    }
}