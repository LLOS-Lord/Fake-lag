import NetworkExtension
import Darwin
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var isPulseActive = false
    private var isCurrentlyDropping = false
    private var pulseWorkItem: DispatchWorkItem?
    private let processingQueue = DispatchQueue(label: "com.fakelag.packet", qos: .userInteractive)
    private var isRunning = false
    private var lastAppMessageTime = Date()

    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        // Tăng giới hạn tài nguyên (best-effort)
        increaseResourceLimits()
        // Tăng process priority để giảm khả năng bị jetsam kill
        applyAntiKillMechanism()

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
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

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                completionHandler(error)
            } else {
                self?.isRunning = true
                self?.processingQueue.async {
                    self?.startPacketLoop()
                }
                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        isRunning = false
        isPulseActive = false
        isCurrentlyDropping = false
        pulseWorkItem?.cancel()
        pulseWorkItem = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        lastAppMessageTime = Date()

        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler?(Data("error".utf8))
            return
        }

        // Phản hồi ngay để App biết Extension còn sống
        completionHandler?(Data("ok".utf8))

        switch command {
        case "heartbeat":
            break
        case "enableBlocking":
            isPulseActive = true
            isCurrentlyDropping = true
            startPulseLoop()
        case "disableBlocking":
            isPulseActive = false
            isCurrentlyDropping = false
            pulseWorkItem?.cancel()
            pulseWorkItem = nil
        default:
            break
        }
    }

    // MARK: - Resource limits (best-effort, không gây crash nếu thất bại)

    private func increaseResourceLimits() {
        var rlim = rlimit()

        if getrlimit(RLIMIT_NOFILE, &rlim) == 0 {
            rlim.rlim_cur = min(rlim.rlim_max, 65536)
            let _ = setrlimit(RLIMIT_NOFILE, &rlim)
        }

        if getrlimit(RLIMIT_DATA, &rlim) == 0 {
            rlim.rlim_cur = min(rlim.rlim_max, 512 * 1024 * 1024)
            let _ = setrlimit(RLIMIT_DATA, &rlim)
        }

        if getrlimit(RLIMIT_STACK, &rlim) == 0 {
            rlim.rlim_cur = min(rlim.rlim_max, 8 * 1024 * 1024)
            let _ = setrlimit(RLIMIT_STACK, &rlim)
        }
    }

    // MARK: - Anti-kill bằng POSIX setpriority (public API)

    private func applyAntiKillMechanism() {
        let pid = getpid()
        // PRIO_PROCESS = 0, -20 = highest nice value (highest priority)
        let result = setpriority(PRIO_PROCESS, id_t(pid), -20)
        if result == 0 {
            NSLog("[FakeLag] Priority boosted for PID: \(pid)")
        } else {
            NSLog("[FakeLag] setpriority failed, errno: \(errno)")
        }

        // Thử set thread QoS cao nhất
        if #available(iOS 15.0, *) {
            DispatchQueue.global(qos: .userInteractive).async {
                pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
            }
        }
    }

    // MARK: - Pulse Loop (Cơ chế Fake Lag)

    private func startPulseLoop() {
        pulseWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isPulseActive else { return }
            self.isCurrentlyDropping.toggle()
            self.scheduleNextPulse()
        }
        pulseWorkItem = workItem

        // Chu kỳ: DROP 2.5s -> PASS 0.001s -> DROP 2.5s...
        let delay = isCurrentlyDropping ? 2.5 : 0.001
        processingQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scheduleNextPulse() {
        guard isPulseActive else { return }
        startPulseLoop()
    }

    // MARK: - Packet Loop (Tối ưu, không đệ quy)

    private func startPacketLoop() {
        guard isRunning else { return }

        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { return }

            if packets.isEmpty {
                self.processingQueue.async {
                    self.startPacketLoop()
                }
                return
            }

            if !self.isCurrentlyDropping {
                self.forwardPackets(packets: packets, protocols: protocols)
            }
            // Nếu đang dropping -> silently discard (tạo lag)

            self.processingQueue.async {
                self.startPacketLoop()
            }
        }
    }

    private func forwardPackets(packets: [Data], protocols: [NSNumber]) {
        let chunkSize = 64
        let count = packets.count

        for i in stride(from: 0, to: count, by: chunkSize) {
            let end = min(i + chunkSize, count)
            let packetChunk = Array(packets[i..<end])
            let protocolChunk = Array(protocols[i..<end])
            let _ = packetFlow.writePackets(packetChunk, withProtocols: protocolChunk)
        }
    }
}
