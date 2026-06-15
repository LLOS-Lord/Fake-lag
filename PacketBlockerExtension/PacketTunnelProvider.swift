import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var isPulseActive = false
    private var isCurrentlyDropping = false
    private var pulseWorkItem: DispatchWorkItem?
    private let processingQueue = DispatchQueue(label: "com.fakelag.packet", qos: .userInteractive)
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        settings.mtu = 1280  // Giảm MTU để tiết kiệm bộ nhớ
        
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        
        let ipv6 = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6
        
        let dns = NEDNSSettings(servers: ["8.8.8.8", "1.1.1.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                completionHandler(error)
            } else {
                self.processingQueue.async {
                    self.startPacketLoop()
                }
                completionHandler(nil)
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        isPulseActive = false
        pulseWorkItem?.cancel()
        pulseWorkItem = nil
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler?("error".data(using: .utf8))
            return
        }
        
        // Phản hồi ngay lập tức – tránh timeout từ app
        completionHandler?("ok".data(using: .utf8))
        
        if command == "enableBlocking" {
            isPulseActive = true
            isCurrentlyDropping = true
            startPulseLoop()
        } else if command == "disableBlocking" {
            isPulseActive = false
            isCurrentlyDropping = false
            pulseWorkItem?.cancel()
            pulseWorkItem = nil
        }
    }
    
    private func startPulseLoop() {
        pulseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isPulseActive else { return }
            self.isCurrentlyDropping.toggle()
            self.startPulseLoop()
        }
        pulseWorkItem = workItem
        
        let delay = isCurrentlyDropping ? 2.5 : 0.001
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    
    private func startPacketLoop() {
        autoreleasepool {
            packetFlow.readPackets { [weak self] packets, protocols in
                guard let self = self else { return }
                
                if !self.isCurrentlyDropping {
                    self.packetFlow.writePackets(packets, withProtocols: protocols)
                }
                
                self.processingQueue.async {
                    self.startPacketLoop()
                }
            }
        }
    }
}
