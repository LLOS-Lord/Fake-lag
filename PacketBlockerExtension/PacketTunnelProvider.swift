import NetworkExtension
import os.log

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private let log = OSLog(subsystem: "com.tenban.PacketBlocker.extension", category: "tunnel")
    private var isCurrentlyBlocking = false
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        os_log("🚀 startTunnel", log: log, type: .info)
        
        // Khởi tạo ban đầu: KHÔNG chặn (Traffic tự do)
        isCurrentlyBlocking = false
        applySettings(isBlocking: false) { [weak self] error in
            if let error = error {
                os_log("❌ setTunnelNetworkSettings failed: %@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }
            self?.startPacketLoop()
            completionHandler(nil)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("🛑 stopTunnel", log: log, type: .info)
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        
        os_log("📩 Received command: %{public}@", log: log, type: .info, command)
        
        // 1. PHẢN HỒI NGAY LẬP TỨC CHO APP ĐỂ TRÁNH LỖI TIMEOUT UI
        completionHandler?("ok".data(using: .utf8))
        
        // 2. SAU ĐÓ MỚI ÁP DỤNG CÀI ĐẶT NETWORK Ở BACKGROUND THREAD
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if command == "enableBlocking" {
                self?.isCurrentlyBlocking = true
                self?.applySettings(isBlocking: true) { _ in }
            } else if command == "disableBlocking" {
                self?.isCurrentlyBlocking = false
                self?.applySettings(isBlocking: false) { _ in }
            }
        }
    }
    
    private func applySettings(isBlocking: Bool, completion: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        
        // Chỉ dùng IPv4 để tránh xung đột cấu hình nhà mạng
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        
        if isBlocking {
            // Hút toàn bộ traffic vào VPN để Drop
            ipv4.includedRoutes = [NEIPv4Route.default()]
        } else {
            // Bỏ trống để traffic đi tự do ra ngoài (Bypass)
            ipv4.includedRoutes = []
        }
        
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { error in
            if let err = error {
                os_log("❌ Error applying settings: %@", log: self.log, type: .error, err.localizedDescription)
            } else {
                os_log("✅ Settings applied. Blocking: %d", log: self.log, type: .info, isBlocking)
            }
            completion(error)
        }
    }
    
    private func startPacketLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            
            // Chỉ in log và Drop khi đang bật chế độ chặn
            if self.isCurrentlyBlocking {
                os_log("🛑 Dropped %d packets", log: self.log, type: .debug, packets.count)
            }
            
            // Gọi lại chính nó để tiếp tục chờ gói tin (không crash)
            self.startPacketLoop()
        }
    }
}
