import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var isPulseActive = false
    private var isCurrentlyDropping = false
    private var pulseWorkItem: DispatchWorkItem?
    private let processingQueue = DispatchQueue(label: "com.fakelag.packet", qos: .userInitiated)
    private var isRunning = false
    private var lastConfigTimestamp: TimeInterval = 0

    // MARK: - Config từ file

    private struct Config: Codable {
        var enabled: Bool = false
        var delayMs: Int = 100
        var dropEnabled: Bool = false
        var dropPercent: Int = 30
        var timestamp: TimeInterval = 0
    }

    private var configFileURL: URL {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.ban.PacketBlocker")!
            .appendingPathComponent("fakelag_config.plist")
    }

    private func readConfig() -> Config {
        guard FileManager.default.fileExists(atPath: configFileURL.path) else {
            return Config()
        }
        do {
            let data = try Data(contentsOf: configFileURL)
            return try PropertyListDecoder().decode(Config.self, from: data)
        } catch {
            return Config()
        }
    }

    private func applyConfig(_ config: Config) {
        lastConfigTimestamp = config.timestamp

        if config.enabled {
            if !isPulseActive {
                isPulseActive = true
                isCurrentlyDropping = true
                startPulseLoop()
            }
        } else {
            isPulseActive = false
            isCurrentlyDropping = false
            pulseWorkItem?.cancel()
            pulseWorkItem = nil
        }
    }

    // MARK: - Tunnel Lifecycle

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

            // Đọc config từ file ngay khi khởi động
            let config = self?.readConfig() ?? Config()
            self?.applyConfig(config)

            // Bắt đầu packet loop
            self?.processingQueue.async {
                self?.startPacketLoop()
            }

            // Kiểm tra file config định kỳ (5 giây/lần)
            self?.startConfigWatcher()

            completionHandler(nil)
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
        // LUÔN phản hồi ngay
        completionHandler?(Data("ok".utf8))

        // Đọc lại config từ file
        let config = readConfig()
        applyConfig(config)
    }

    // MARK: - Config Watcher (backup nếu message lỗi)

    private func startConfigWatcher() {
        guard isRunning else { return }

        let config = readConfig()
        if config.timestamp > lastConfigTimestamp {
            applyConfig(config)
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.startConfigWatcher()
        }
    }

    // MARK: - Pulse Loop

    private func startPulseLoop() {
        pulseWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isPulseActive else { return }
            self.isCurrentlyDropping.toggle()
            self.startPulseLoop()
        }
        pulseWorkItem = workItem

        let delay = isCurrentlyDropping ? 2.5 : 0.001
        processingQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // MARK: - Packet Loop

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
