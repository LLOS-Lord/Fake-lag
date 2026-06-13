import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var isPulseActive = false
    private var isCurrentlyDropping = false
    private var isBlockSimActive = false
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        // Lúc mới bật VPN: Cho mạng đi tự do (Làn 1)
        applyRouting(drop: false, completion: completionHandler)
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        isPulseActive = false
        completionHandler()
    }
    
    // MARK: - Nhận lệnh từ App để Chuyển Làn Ngầm (Không ngắt VPN)
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        
        // Báo cáo hoàn thành ngay để không bị lỗi Timeout UI
        completionHandler?("ok".data(using: .utf8))
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            switch command {
            case "enableBlocking":
                self?.isPulseActive = true
                self?.isCurrentlyDropping = true
                self?.applyRouting(drop: true) { _ in
                    self?.startPacketLoop()
                    self?.scheduleNextPulse()
                }
            case "disableBlocking":
                self?.isPulseActive = false
                self?.applyRouting(drop: false) { _ in }
            case "enableBlockSim":
                self?.isBlockSimActive = true
                // Khi chặn file simulate, ta có thể dùng cơ chế routing hoặc packet filter
                // Ở đây ta sử dụng routing để chặn toàn bộ nếu cần, hoặc xử lý trong packet loop
                // Tuy nhiên, việc chặn 1 file cụ thể trên iOS qua VPN Tunnel thường là chặn domain hoặc IP liên quan.
                // Nếu là file local preferences, VPN không can thiệp trực tiếp được vào file system.
                // Nhưng nếu ý người dùng là chặn traffic mà "Network Link Conditioner" tạo ra:
                self?.applyRouting(drop: true) { _ in
                    self?.startPacketLoop()
                }
            case "disableBlockSim":
                self?.isBlockSimActive = false
                self?.applyRouting(drop: false) { _ in }
            default:
                break
            }
        }
    }
    
    // MARK: - Động cơ Pulse Lag
    private func scheduleNextPulse() {
        guard isPulseActive else { return }
        
        let waitTime = isCurrentlyDropping ? 2.5 : 0.001
        
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + waitTime) { [weak self] in
            guard let self = self, self.isPulseActive else { return }
            
            self.isCurrentlyDropping.toggle()
            self.applyRouting(drop: self.isCurrentlyDropping) { _ in
                self.scheduleNextPulse()
            }
        }
    }
    
    // MARK: - Định tuyến Core (IPv4 + IPv6)
    private func applyRouting(drop: Bool, completion: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = drop ? [NEIPv4Route.default()] : []
        settings.ipv4Settings = ipv4
        
        let ipv6 = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
        ipv6.includedRoutes = drop ? [NEIPv6Route.default()] : []
        settings.ipv6Settings = ipv6
        
        settings.mtu = 1500
        setTunnelNetworkSettings(settings, completionHandler: completion)
    }
    
    private func startPacketLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            self?.startPacketLoop()
        }
    }
}
