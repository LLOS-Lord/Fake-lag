import NetworkExtension
import Darwin

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var isPulseActive = false
    private var isCurrentlyDropping = false
    private var pulseWorkItem: DispatchWorkItem?
    private let processingQueue = DispatchQueue(label: "com.fakelag.packet", qos: .userInteractive)
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        // Tăng giới hạn file descriptor và bộ nhớ (chống kill)
        increaseResourceLimits()
        // Yêu cầu hệ thống ưu tiên giữ tiến trình
        applyAntiKillMechanism()
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        settings.mtu = 1280
        
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
    
    // MARK: - Anti-kill functions (cần entitlements mạnh)
    
    private func increaseResourceLimits() {
        var rlim = rlimit()
        getrlimit(RLIMIT_NOFILE, &rlim)
        rlim.rlim_cur = 4096
        rlim.rlim_max = 4096
        setrlimit(RLIMIT_NOFILE, &rlim)
        
        getrlimit(RLIMIT_DATA, &rlim)
        rlim.rlim_cur = 256 * 1024 * 1024   // 256 MB
        rlim.rlim_max = 512 * 1024 * 1024   // 512 MB
        setrlimit(RLIMIT_DATA, &rlim)
    }
    
    private func applyAntiKillMechanism() {
        // Sử dụng private API memorystatus nếu có quyền
        let pid = ProcessInfo.processInfo.processIdentifier
        let command = "memorystatus_control -c 1 -p \(pid)"
        
        // Thực thi lệnh (chỉ hoạt động nếu có quyền root hoặc entitlement com.apple.private.memorystatus)
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", command]
        task.launch()
        task.waitUntilExit()
        
        #if DEBUG
        print("[*] Anti-kill applied for PID: \(pid)")
        #endif
    }
    
    // MARK: - Packet loop
    
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
                    let chunkSize = 100
                    for i in stride(from: 0, to: packets.count, by: chunkSize) {
                        let end = min(i + chunkSize, packets.count)
                        let packetChunk = Array(packets[i..<end])
                        let protocolChunk = Array(protocols[i..<end])
                        self.packetFlow.writePackets(packetChunk, withProtocols: protocolChunk)
                    }
                }
                
                self.processingQueue.async { [weak self] in
                    self?.startPacketLoop()
                }
            }
        }
    }
}
