import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        
        // 1. Đọc trạng thái từ cấu hình App truyền sang (từ VPNManager)
        let config = (self.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let isBlackhole = config?["isBlocking"] as? Bool ?? false
        
        // 2. Thiết lập cấu hình mạng (Cơ chế 2 Làn Ảo)
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        
        // LÀN 2 (Fake Lag) thì hút mạng vào. LÀN 1 (Tự do) thì bỏ trống.
        ipv4.includedRoutes = isBlackhole ? [NEIPv4Route.default()] : []
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            // Chỉ khi nào đang ở Làn 2 (Chặn) và không có lỗi, mới bật máy nuốt gói tin
            if error == nil && isBlackhole {
                self?.startPacketLoop()
            }
            completionHandler(error)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    
    private func startPacketLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            // Nuốt gói tin vào hư không. 
            // KHÔNG DÙNG print() hay os_log() Ở ĐÂY ĐỂ TRÁNH TRÀN 15MB RAM.
            self?.startPacketLoop()
        }
    }
}
