import NetworkExtension
import os.log

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private let log = OSLog(subsystem: "com.tenban.PacketBlocker.extension", category: "tunnel")
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        os_log("🚀 startTunnel called", log: log, type: .info)
        
        // Mặc định khởi động VPN nhưng KHÔNG bắt traffic (để internet tự do)
        applySettings(isBlocking: false) { [weak self] error in
            if let error = error {
                os_log("❌ Tunnel init failed: %@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }
            // Khởi động vòng lặp nuốt gói tin (chạy không tải)
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
        
        os_log("📩 App Message: %{public}@", log: log, type: .info, command)
        
        // 1. CHỐT ĐƠN NGAY VỚI APP: Trả lời "ok" liền để App không bị timeout
        completionHandler?("ok".data(using: .utf8))
        
        // 2. XỬ LÝ VIỆC NẶNG Ở BACKGROUND
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let shouldBlock = (command == "enableBlocking")
            self?.applySettings(isBlocking: shouldBlock) { _ in }
        }
    }
    
    private func applySettings(isBlocking: Bool, completion: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        
        // Bật chặn -> Đơm hết mạng vào VPN. Tắt chặn -> Bỏ trống để mạng đi tự do
        ipv4.includedRoutes = isBlocking ? [NEIPv4Route.default()] : []
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { error in
            completion(error)
        }
    }
    
    private func startPacketLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            
            // 🚨 TUYỆT ĐỐI KHÔNG PRINT / OS_LOG Ở ĐÂY 🚨
            // Hàm này sẽ nuốt hàng ngàn gói tin vào hư không. 
            // ARC (Auto Reference Counting) của Swift sẽ tự động giải phóng RAM của 'packets'.
            
            // Tiếp tục vòng lặp
            self.startPacketLoop()
        }
    }
}