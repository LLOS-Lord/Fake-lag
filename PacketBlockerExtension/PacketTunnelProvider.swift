import NetworkExtension
import os.log

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private let log = OSLog(subsystem: "com.tenban.PacketBlocker.extension", category: "tunnel")
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        os_log("🚀 Bắt đầu khởi động VPN", log: log, type: .info)
        
        // Mặc định khởi động ở Làn 1: Mạng đi tự do, không bị chặn
        switchLane(isBlackhole: false) { [weak self] error in
            if let error = error {
                os_log("❌ Lỗi khởi tạo Tunnel: %@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }
            
            // Khởi động cỗ máy nuốt gói tin chạy ngầm
            self?.startPacketLoop()
            completionHandler(nil)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        
        // 1. Phản hồi "ok" ngay lập tức để UI App không bị báo lỗi Timeout
        completionHandler?("ok".data(using: .utf8))
        
        // 2. Chuyển làn mạng âm thầm ở chế độ nền
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let toBlackhole = (command == "enableBlocking")
            self?.switchLane(isBlackhole: toBlackhole) { _ in }
        }
    }
    
    // MARK: - Cơ chế "2 Làn Ảo" (Routing Switch)
    private func switchLane(isBlackhole: Bool, completion: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        
        if isBlackhole {
            // LÀN 2 (Fake Lag): Chuyển hướng toàn bộ mạng đâm vào VPN để hủy
            ipv4.includedRoutes = [NEIPv4Route.default()]
        } else {
            // LÀN 1 (Bình thường): Bỏ trống tuyến đường, mạng đi thẳng ra ngoài
            ipv4.includedRoutes = []
        }
        
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        
        // Cập nhật luật giao thông ngay lập tức mà không làm đứt kết nối VPN
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                os_log("❌ Lỗi chuyển làn: %@", log: self.log, type: .error, error.localizedDescription)
            } else {
                os_log("✅ Đã chuyển làn. Blackhole (Chặn): %d", log: self.log, type: .info, isBlackhole)
            }
            completion(error)
        }
    }
    
    // MARK: - Cỗ máy nuốt gói tin (Blackhole)
    private func startPacketLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            // Khi gói tin lọt vào Làn 2, nó sẽ rơi vào đây.
            // TUYỆT ĐỐI KHÔNG DÙNG print() HAY os_log() Ở ĐÂY.
            // Hệ thống sẽ tự động hủy các gói tin này (tạo ra Fake Lag).
            
            // Tiếp tục vòng lặp chờ gói tin tiếp theo
            self?.startPacketLoop()
        }
    }
}
