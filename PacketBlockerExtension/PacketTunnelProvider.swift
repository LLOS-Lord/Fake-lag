import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    // Các biến kiểm soát nhịp Lag
    private var isPulseActive = false
    private var isCurrentlyDropping = false
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        
        // 1. Đọc trạng thái từ App
        let config = (self.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let isBlackhole = config?["isBlocking"] as? Bool ?? false
        
        if isBlackhole {
            // LÀN 2 (FAKE LAG): Kích hoạt chế độ Pulse Lag (Chặn/Thả liên tục)
            isPulseActive = true
            isCurrentlyDropping = true // Bắt đầu bằng việc chặn ngay lập tức
            
            applyRouting(drop: true) { [weak self] error in
                if error == nil {
                    self?.startPacketLoop() // Bật máy nuốt gói tin
                    self?.scheduleNextPulse() // Khởi động nhịp tim
                }
                completionHandler(error)
            }
        } else {
            // LÀN 1 (BÌNH THƯỜNG): Tắt nhấp nháy, mạng đi tự do
            isPulseActive = false
            applyRouting(drop: false, completion: completionHandler)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        // Dừng vòng lặp Pulse Lag khi tắt VPN
        isPulseActive = false
        completionHandler()
    }
    
    // MARK: - Bộ Điều Tốc (Pulse Lag Engine)
    private func scheduleNextPulse() {
        guard isPulseActive else { return }
        
        // ⏱ THÔNG SỐ ĐỘ CHẾ (BẠN CÓ THỂ TỰ CHỈNH Ở ĐÂY):
        // waitTime là thời gian giữ trạng thái trước khi chuyển đổi
        // - 1.0 giây Đóng băng (gây lag nặng)
        // - 0.5 giây Thông mạch (chống văng game 999+)
        let waitTime = isCurrentlyDropping ? 1.0 : 0.5
        
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + waitTime) { [weak self] in
            guard let self = self, self.isPulseActive else { return }
            
            // Đảo ngược trạng thái (Đang chặn -> Thả, Đang thả -> Chặn)
            self.isCurrentlyDropping.toggle()
            
            // Áp dụng luật mới và hẹn giờ nhịp tiếp theo
            self.applyRouting(drop: self.isCurrentlyDropping) { _ in
                self.scheduleNextPulse()
            }
        }
    }
    
    // MARK: - Core Routing
    private func applyRouting(drop: Bool, completion: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        
        // Cập nhật biển báo: Hút vào VPN hoặc thả tự do
        ipv4.includedRoutes = drop ? [NEIPv4Route.default()] : []
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings, completionHandler: completion)
    }
    
    // MARK: - Hố Đen Nuốt Gói Tin
    private func startPacketLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            // Nuốt gói tin vào cõi hư vô (không in log)
            self?.startPacketLoop()
        }
    }
}
