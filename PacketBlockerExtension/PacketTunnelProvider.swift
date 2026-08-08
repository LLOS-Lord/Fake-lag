import NetworkExtension
import Foundation

private struct LagConfig: Codable {
    var enabled: Bool = false
    var delayMs: Int = 150
    var timestamp: TimeInterval = 0
}

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var isLagEnabled = false
    private var currentDelayMs: Int = 150
    private let processingQueue = DispatchQueue(label: "com.fakelag.packet", qos: .userInitiated)
    private var isRunning = false
    private var lastConfigTimestamp: TimeInterval = 0
    private var packetCount: UInt64 = 0

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
        isLagEnabled = config.enabled
        currentDelayMs = config.delayMs
        if isLagEnabled {
            NSLog("[FakeLag] ENABLED - delay \(currentDelayMs)ms")
        } else {
            NSLog("[FakeLag] DISABLED")
        }
    }

    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
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
                return
            }

            self?.isRunning = true
            let config = self?.readConfig() ?? LagConfig()
            self?.applyConfig(config)

            self?.processingQueue.async {
                self?.startPacketLoop()
            }

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

    // MARK: - Packet Loop với DELAY THỰC SỰ

    private func startPacketLoop() {
        guard isRunning else { return }

        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { return }

            if packets.isEmpty {
                self.processingQueue.async { self.startPacketLoop() }
                return
            }

            self.packetCount += UInt64(packets.count)

            if self.isLagEnabled && self.currentDelayMs > 0 {
                // DELAY THỰC SỰ: đưa vào queue, forward sau delay
                let delay = Double(self.currentDelayMs) / 1000.0
                self.processingQueue.asyncAfter(deadline: .now() + delay) {
                    self.forwardPackets(packets: packets, protocols: protocols)
                }
            } else {
                // Không delay: forward ngay
                self.forwardPackets(packets: packets, protocols: protocols)
            }

            // Đọc tiếp packet mới ngay — không block
            self.processingQueue.async { self.startPacketLoop() }
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
