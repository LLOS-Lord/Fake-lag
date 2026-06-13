import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var isPulseActive = false
    private var isCurrentlyDropping = false
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        
        let config = (self.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let isBlackhole = config?["isBlocking"] as? Bool ?? false
        
        if isBlackhole {
            isPulseActive = true
            isCurrentlyDropping = true 
            
            applyRouting(drop: true) { [weak self] error in
                if error == nil {
                    self?.startPacketLoop()
                    self?.scheduleNextPulse()
                }
                completionHandler(error)
            }
        } else {
            isPulseActive = false
            applyRouting(drop: false, completion: completionHandler)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        isPulseActive = false
        completionHandler()
    }
    
    // MARK: - Bộ Điều Tốc (Đã tăng thời gian để ép Ngưng Đọng)
    private func scheduleNextPulse() {
        guard isPulseActive else { return }
        
        // ⏱ THÔNG SỐ ĐÃ ĐƯỢC CHỈNH LẠI:
        // - 2.5 giây Đóng băng (Phá vỡ cơ chế trượt của game, ép mọi sự kiện phải đứng im)
        // - 0.5 giây Thông mạch (Giữ cho ping không bị 999+ và chống văng)
        let waitTime = isCurrentlyDropping ? 3 : 0.0001
        
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + waitTime) { [weak self] in
            guard let self = self, self.isPulseActive else { return }
            
            self.isCurrentlyDropping.toggle()
            
            self.applyRouting(drop: self.isCurrentlyDropping) { _ in
                self.scheduleNextPulse()
            }
        }
    }
    
    // MARK: - Core Routing (Đã khóa chặt cả IPv4 và IPv6)
    private func applyRouting(drop: Bool, completion: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        
        // Cấu hình IPv4
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = drop ? [NEIPv4Route.default()] : []
        settings.ipv4Settings = ipv4
        
        // Cấu hình IPv6 (Bịt lỗ hổng chống rò rỉ data Game)
        let ipv6 = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
        ipv6.includedRoutes = drop ? [NEIPv6Route.default()] : []
        settings.ipv6Settings = ipv6
        
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings, completionHandler: completion)
    }
    
    // MARK: - Hố Đen Nuốt Gói Tin
    private func startPacketLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            // Gói tin chui vào đây sẽ bị hủy hoàn toàn (Drop)
            self?.startPacketLoop()
        }
    }
}
