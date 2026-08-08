import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var isLagEnabled = false
    private let queue = DispatchQueue(label: "com.fakelag.queue", qos: .userInitiated)
    private var isRunning = false

    // Buffer cho delayed packets
    private struct DelayedPacket {
        let data: Data
        let proto: NSNumber
        let sendTime: DispatchTime
    }
    private var buffer: [DelayedPacket] = []
    private let bufferLock = NSLock()
    private var bufferTimer: DispatchSourceTimer?

    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        // Mặc định TẮT lag — không bao giờ đọc file
        isLagEnabled = false

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1500

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
                return
            }

            self?.isRunning = true
            self?.startPacketLoop()
            self?.startBufferTimer()

            NSLog("[FakeLag] Tunnel started. Lag = OFF")
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        isRunning = false
        isLagEnabled = false
        bufferTimer?.cancel()
        bufferTimer = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler?(Data("err".utf8))
            return
        }

        switch command {
        case "enable":
            isLagEnabled = true
            NSLog("[FakeLag] >>> LAG ENABLED <<<")
            completionHandler?(Data("on".utf8))
        case "disable":
            isLagEnabled = false
            // Flush buffer ngay
            flushBuffer()
            NSLog("[FakeLag] >>> LAG DISABLED <<<")
            completionHandler?(Data("off".utf8))
        default:
            completionHandler?(Data("ok".utf8))
        }
    }

    // MARK: - Packet Loop

    private func startPacketLoop() {
        guard isRunning else { return }

        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { return }

            if packets.isEmpty {
                self.startPacketLoop()
                return
            }

            if self.isLagEnabled {
                self.queue.async {
                    self.bufferPackets(packets: packets, protocols: protocols)
                }
            } else {
                self.forwardNow(packets: packets, protocols: protocols)
            }

            self.startPacketLoop()
        }
    }

    // MARK: - Buffer & Delay

    private func bufferPackets(packets: [Data], protocols: [NSNumber]) {
        let delayMs = 300
        let dropPercent = 15
        let now = DispatchTime.now()
        let delayNanos = UInt64(delayMs) * 1_000_000

        for i in 0..<packets.count {
            // Drop ngẫu nhiên
            if Int.random(in: 0..<100) < dropPercent {
                continue
            }

            let dp = DelayedPacket(
                data: packets[i],
                proto: protocols[i],
                sendTime: now + .nanoseconds(Int(delayNanos))
            )

            bufferLock.lock()
            buffer.append(dp)
            bufferLock.unlock()
        }
    }

    private func startBufferTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.flushBuffer()
        }
        timer.resume()
        bufferTimer = timer
    }

    private func flushBuffer() {
        let now = DispatchTime.now()
        var toSend: [(Data, NSNumber)] = []

        bufferLock.lock()
        let ready = buffer.filter { $0.sendTime <= now }
        buffer.removeAll { $0.sendTime <= now }
        bufferLock.unlock()

        for dp in ready {
            toSend.append((dp.data, dp.proto))
        }

        // Gửi theo chunk
        let chunkSize = 32
        for i in stride(from: 0, to: toSend.count, by: chunkSize) {
            let end = min(i + chunkSize, toSend.count)
            let chunk = Array(toSend[i..<end])
            let datas = chunk.map { $0.0 }
            let protos = chunk.map { $0.1 }
            let _ = packetFlow.writePackets(datas, withProtocols: protos)
        }
    }

    // MARK: - Forward ngay (không lag)

    private func forwardNow(packets: [Data], protocols: [NSNumber]) {
        let chunkSize = 64
        let count = packets.count
        for i in stride(from: 0, to: count, by: chunkSize) {
            let end = min(i + chunkSize, count)
            let _ = packetFlow.writePackets(
                Array(packets[i..<end]),
                withProtocols: Array(protocols[i..<end])
            )
        }
    }
}
