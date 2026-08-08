import NetworkExtension
import Foundation

private struct LagConfig: Codable {
    var enabled: Bool = false
    var timestamp: TimeInterval = 0
}

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var isLagEnabled = false
    private let processingQueue = DispatchQueue(label: "com.fakelag.packet", qos: .userInitiated)
    private var isRunning = false
    private var lastConfigTimestamp: TimeInterval = 0

    private var configFileURL: URL {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.ban.PacketBlocker")!
            .appendingPathComponent("fakelag_config.plist")
    }

    private func readConfig() -> LagConfig {
        guard FileManager.default.fileExists(atPath: configFileURL.path) else {
            return LagConfig()
        }
        do {
            let data = try Data(contentsOf: configFileURL)
            return try PropertyListDecoder().decode(LagConfig.self, from: data)
        } catch {
            return LagConfig()
        }
    }

    private func applyConfig(_ config: LagConfig) {
        lastConfigTimestamp = config.timestamp
        let wasEnabled = isLagEnabled
        isLagEnabled = config.enabled

        if isLagEnabled && !wasEnabled {
            NSLog("[FakeLag] >>> LAG ENABLED <<<")
        } else if !isLagEnabled && wasEnabled {
            NSLog("[FakeLag] >>> LAG DISABLED <<<")
        }
    }

    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        // LUÔN bắt đầu với lag TẮT — để tránh lag ngay khi bật VPN
        isLagEnabled = false

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1500  // MTU chuẩn, tránh fragmentation

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

            // Bắt đầu packet loop
            self?.processingQueue.async {
                self?.startPacketLoop()
            }

            // Theo dõi config
            self?.startConfigWatcher()

            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        isRunning = false
        isLagEnabled = false
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(Data("ok".utf8))
        let config = readConfig()
        applyConfig(config)
    }

    private func startConfigWatcher() {
        guard isRunning else { return }
        let config = readConfig()
        if config.timestamp > lastConfigTimestamp {
            applyConfig(config)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.startConfigWatcher()
        }
    }

    // MARK: - Packet Loop

    private func startPacketLoop() {
        guard isRunning else { return }

        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { return }

            if packets.isEmpty {
                self.processingQueue.async { self.startPacketLoop() }
                return
            }

            if self.isLagEnabled {
                // FAKE LAG: Delay 300ms + drop ngẫu nhiên 15%
                self.applyFakeLag(packets: packets, protocols: protocols)
            } else {
                // NORMAL: Forward ngay lập tức, không delay
                self.forwardPackets(packets: packets, protocols: protocols)
            }

            // Tiếp tục đọc packet mới
            self.processingQueue.async { self.startPacketLoop() }
        }
    }

    private func applyFakeLag(packets: [Data], protocols: [NSNumber]) {
        let delayMs = 300  // Delay 300ms — đủ để game lag nhưng không disconnect
        let dropPercent = 15  // Drop 15% packet — tạo lag spike, teleport

        for i in 0..<packets.count {
            let packet = packets[i]
            let proto = protocols[i]

            // Drop ngẫu nhiên
            let r = Int.random(in: 0..<100)
            if r < dropPercent {
                continue  // Silently drop
            }

            // Delay rồi forward
            let delay = Double(delayMs) / 1000.0
            processingQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.isRunning else { return }
                let _ = self.packetFlow.writePackets([packet], withProtocols: [proto])
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
