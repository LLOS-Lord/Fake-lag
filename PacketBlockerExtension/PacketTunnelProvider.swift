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
                NSLog("❌ Set settings failed: \(error)")
                completionHandler(error)
            } else {
                NSLog("✅ Tunnel started successfully")
                completionHandler(nil)
            }
        }
    }
    
    // ... (stopTunnel và handleAppMessage giữ nguyên)
    
    private func enableBlocking(completion: @escaping (Bool) -> Void) {
        guard !isBlocking else { completion(true); return }
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]  // Route all traffic
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                NSLog("❌ Enable blocking failed: \(error)")
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
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = []
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            self?.isBlocking = false
            self?.isDropping = false
            if let error = error {
                NSLog("❌ Disable failed: \(error)")
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
        
        packetFlow.readPackets { [weak self] packets, protocols in
            // Drop all packets (không forward)
            // Có thể log nếu muốn debug: NSLog("Dropped \(packets.count) packets")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) {  // Nhỏ hơn 0.01 để lag mạnh hơn
                self?.readPacketsLoop()
            }
        }
    }
}
