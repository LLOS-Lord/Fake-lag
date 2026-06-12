import NetworkExtension
import os.log

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var isBlocking = false
    private let log = OSLog(subsystem: "com.tenban.PacketBlocker.extension", category: "tunnel")
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        os_log("🚀 startTunnel", log: log, type: .info)
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        
        // Cấu hình IPv4: route toàn bộ 0.0.0.0/0
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        
        // Cấu hình IPv6: route toàn bộ ::/0
        let ipv6 = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6
        
        // DNS (quan trọng – nếu thiếu sẽ không có internet)
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "8.8.4.4"])
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                os_log("❌ setTunnelNetworkSettings failed: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }
            os_log("✅ Tunnel settings applied – VPN is now connected", log: self?.log ?? .default, type: .info)
            
            // Bắt đầu vòng lặp đọc/ghi gói tin ngay lập tức
            self?.startPacketLoop()
            completionHandler(nil)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("🛑 stopTunnel", log: log, type: .info)
        isBlocking = false
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
            isBlocking = true
            os_log("🚫 Blocking ENABLED – all packets will be dropped", log: log, type: .info)
            completionHandler?("ok".data(using: .utf8))
            
        case "disableBlocking":
            isBlocking = false
            os_log("✅ Blocking DISABLED – packets will flow normally", log: log, type: .info)
            completionHandler?("ok".data(using: .utf8))
            
        default:
            os_log("❓ Unknown command", log: log, type: .error)
            completionHandler?(nil)
        }
    }
    
    private func startPacketLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            
            if self.isBlocking {
                // DROP: không ghi lại gói tin → mất mạng hoàn toàn
                os_log("🛑 Dropped %d packets", log: self.log, type: .debug, packets.count)
            } else {
                // FORWARD: ghi lại gói tin như bình thường
                self.packetFlow.writePackets(packets, withProtocols: protocols)
            }
            
            // Gọi lại chính nó để tiếp tục đọc gói tin tiếp theo (vòng lặp vô hạn)
            self.startPacketLoop()
        }
    }
}