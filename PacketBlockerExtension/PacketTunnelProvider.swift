import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var isPulseActive = false
    private var isCurrentlyDropping = false
    private var timer: Timer?
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        // Cấu hình mạng 1 lần duy nhất khi bắt đầu
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        // Luôn bao gồm route mặc định để bắt mọi gói tin
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        
        let ipv6 = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6
        
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                completionHandler(error)
            } else {
                // Bắt đầu vòng lặp đọc gói tin
                self.startPacketLoop()
                completionHandler(nil)
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        isPulseActive = false
        timer?.invalidate()
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        
        if command == "enableBlocking" {
            isPulseActive = true
            isCurrentlyDropping = true
            startPulseTimer()
        } else {
            isPulseActive = false
            timer?.invalidate()
            isCurrentlyDropping = false
        }
        
        // Phản hồi ngay lập tức để tránh lỗi "did not respond"
        completionHandler?("ok".data(using: .utf8))
    }
    
    private func startPulseTimer() {
        timer?.invalidate()
        // Sử dụng Timer để chính xác hơn và không block thread
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isPulseActive else { return }
            self.isCurrentlyDropping.toggle()
        }
    }
    
    private func startPacketLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            
            if !self.isCurrentlyDropping {
                // Nếu KHÔNG chặn: Gửi gói tin đi bình thường (Làn 1)
                self.packetFlow.writePackets(packets, withProtocols: protocols)
            } else {
                // Nếu ĐANG chặn: "Vứt bỏ" gói tin (Làn 2 - Blackhole)
                // Không gọi writePackets = gói tin bị mất = Lag
            }
            
            // Tiếp tục đọc gói tin tiếp theo
            self.startPacketLoop()
        }
    }
}
