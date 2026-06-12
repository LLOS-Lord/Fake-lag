import NetworkExtension
import os.log

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private let log = OSLog(subsystem: "com.tenban.PacketBlocker.extension", category: "tunnel")
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        os_log("🚀 startTunnel", log: log, type: .info)
        
        // Mặc định khi kết nối: Không chặn (Traffic tự do)
        applySettings(isBlocking: false) { [weak self] error in
            if let error = error {
                os_log("❌ setTunnelNetworkSettings failed", log: self?.log ?? .default, type: .error)
                completionHandler(error)
                return
            }
            // Bắt đầu vòng lặp đọc gói tin (chỉ dùng để drop khi bật chặn)
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
        
        switch command {
        case "enableBlocking":
            os_log("🚫 Blocking ENABLED – routing all traffic to VPN to drop", log: log, type: .info)
            applySettings(isBlocking: true) { error in
                if error == nil {
                    completionHandler?("ok".data(using: .utf8))
                } else {
                    completionHandler?(nil)
                }
            }
            
        case "disableBlocking":
            os_log("✅ Blocking DISABLED – bypassing VPN routes", log: log, type: .info)
            applySettings(isBlocking: false) { error in
                if error == nil {
                    completionHandler?("ok".data(using: .utf8))
                } else {
                    completionHandler?(nil)
                }
            }
            
        default:
            os_log("❓ Unknown command", log: log, type: .error)
            completionHandler?(nil)
        }
    }
    
    // Hàm cập nhật Routing linh hoạt
    private func applySettings(isBlocking: Bool, completion: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        let ipv6 = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
        
        if isBlocking {
            // Hút toàn bộ traffic vào VPN
            ipv4.includedRoutes = [NEIPv4Route.default()]
            ipv6.includedRoutes = [NEIPv6Route.default()]
        } else {
            // Không hút traffic nào (Traffic được đi tự do qua Wi-Fi/4G)
            ipv4.includedRoutes = []
            ipv6.includedRoutes = []
        }
        
        settings.ipv4Settings = ipv4
        settings.ipv6Settings = ipv6
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "8.8.4.4"])
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings, completionHandler: completion)
    }
    
    private func startPacketLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            
            // Nếu có gói tin nào chui vào đây (khi isBlocking = true), DROP sạch sẽ.
            // TUYỆT ĐỐI KHÔNG dùng writePackets để trả về.
            os_log("🛑 Dropped %d packets", log: self.log, type: .debug, packets.count)
            
            // Tiếp tục vòng lặp
            self.startPacketLoop()
        }
    }
}
