import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var isPulseActive = false
    private var isCurrentlyDropping = false
    private let queue = DispatchQueue(label: "com.fakelag.packet.processing", qos: .userInteractive)
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
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
                // Chạy vòng lặp trên queue ưu tiên cao
                self.queue.async {
                    self.startPacketLoop()
                }
                completionHandler(nil)
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        isPulseActive = false
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        
        // PHẢN HỒI NGAY LẬP TỨC ĐỂ APP KHÔNG BÁO LỖI
        completionHandler?("ok".data(using: .utf8))
        
        if command == "enableBlocking" {
            isPulseActive = true
            isCurrentlyDropping = true
            startPulseLoop()
        } else {
            isPulseActive = false
            isCurrentlyDropping = false
        }
    }
    
    private func startPulseLoop() {
        guard isPulseActive else { return }
        
        let waitTime = isCurrentlyDropping ? 2.5 : 0.001
        
        // Sử dụng global queue để không block main thread của extension
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + waitTime) { [weak self] in
            guard let self = self, self.isPulseActive else { return }
            self.isCurrentlyDropping.toggle()
            self.startPulseLoop()
        }
    }
    
    private func startPacketLoop() {
        // Sử dụng autoreleasepool để giải phóng RAM ngay lập tức sau mỗi lần đọc gói tin
        // Đây là chìa khóa để chống bị iOS kill do tràn RAM (Extension chỉ có 6-15MB RAM)
        autoreleasepool {
            packetFlow.readPackets { [weak self] packets, protocols in
                guard let self = self else { return }
                
                if !self.isCurrentlyDropping {
                    self.packetFlow.writePackets(packets, withProtocols: protocols)
                }
                
                // Tiếp tục vòng lặp trên queue riêng để tối ưu hiệu năng
                self.queue.async {
                    self.startPacketLoop()
                }
            }
        }
    }
}
