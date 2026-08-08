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
        // Tăng giới hạn tài nguyên
        increaseResourceLimits()
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
            // Chỉ cập nhật timestamp, không làm gì khác
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

    // MARK: - Anti-kill functions

    private func increaseResourceLimits() {
        var rlim = rlimit()

        getrlimit(RLIMIT_NOFILE, &rlim)
        rlim.rlim_cur = 65536
        rlim.rlim_max = 65536
        setrlimit(RLIMIT_NOFILE, &rlim)

        getrlimit(RLIMIT_DATA, &rlim)
        rlim.rlim_cur = 512 * 1024 * 1024
        rlim.rlim_max = 1024 * 1024 * 1024
        setrlimit(RLIMIT_DATA, &rlim)

        getrlimit(RLIMIT_STACK, &rlim)
        rlim.rlim_cur = 8 * 1024 * 1024
        rlim.rlim_max = 16 * 1024 * 1024
        setrlimit(RLIMIT_STACK, &rlim)
    }

    private func applyAntiKillMechanism() {
        // Đánh dấu process quan trọng để hệ thống không kill
        let pid = getpid()
        var priority = Int32(JETSAM_PRIORITY_FOREGROUND)
        let result = memorystatus_control(
            UInt32(MEMORYSTATUS_CMD_SET_JETSAM_PRIORITY),
            pid,
            0,
            &priority,
            MemoryLayout<Int32>.size
        )
        if result == 0 {
            NSLog("[FakeLag] Anti-kill applied. PID: \(pid), Priority: \(priority)")
        } else {
            NSLog("[FakeLag] Anti-kill failed with errno: \(errno)")
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
                // Tiếp tục loop ngay nếu không có packet
                self.processingQueue.async {
                    self.startPacketLoop()
                }
                return
            }

            if !self.isCurrentlyDropping {
                // Forward packets theo chunk để tránh block
                self.forwardPackets(packets: packets, protocols: protocols)
            }
            // Nếu đang dropping -> silently discard (tạo lag)

            // Tiếp tục loop
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

            // writePackets trả về Bool, không cần completion
            let _ = packetFlow.writePackets(packetChunk, withProtocols: protocolChunk)
        }
    }
}
