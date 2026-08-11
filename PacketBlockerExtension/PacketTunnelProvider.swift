import NetworkExtension
import Network
import Foundation

// ============================================================================
// MARK: - PacketTunnelProvider (v5 - Stable)
// ============================================================================
// Fix: Thêm DNS settings (bắt buộc cho iOS tunnel hoạt động)
// Fix: MTU 1280 chuẩn VPN
// Fix: Logging chi tiết để debug
// ============================================================================

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var isLagEnabled = false
    private var lastConfigTimestamp: TimeInterval = 0
    private let queue = DispatchQueue(label: "com.fakelag", qos: .userInitiated)
    private var isRunning = false
    private var configTimer: DispatchSourceTimer?

    private var configURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.ban.PacketBlocker"
        ) else { return nil }
        return container.appendingPathComponent("fakelag_config.plist")
    }

    // MARK: - Lifecycle

    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[FakeLag] startTunnel called")
        isLagEnabled = false
        lastConfigTimestamp = 0

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        settings.mtu = NSNumber(value: 1280)

        // IPv4
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        // IPv6 (bắt buộc phải có để iOS không bỏ qua IPv6 traffic)
        let ipv6 = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6

        // DNS - BẮT BUỘC. Không có thì tunnel không resolve được domain
        let dns = NEDNSSettings(servers: ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888"])
        dns.matchDomains = [""] // Match all domains
        settings.dnsSettings = dns

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                NSLog("[FakeLag] setTunnelNetworkSettings FAILED: \(error)")
                completionHandler(error)
                return
            }
            NSLog("[FakeLag] Tunnel settings applied OK")
            self?.isRunning = true
            self?.startConfigWatcher()
            self?.startReadLoop()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[FakeLag] stopTunnel reason=\(reason.rawValue)")
        isRunning = false
        configTimer?.cancel(); configTimer = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(Data("ok".utf8))
    }

    // MARK: - Config Watcher

    private func startConfigWatcher() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.checkConfig() }
        timer.resume()
        configTimer = timer
    }

    private func checkConfig() {
        guard let url = configURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        let enabled = dict["enabled"] as? Bool ?? false
        let timestamp = dict["timestamp"] as? TimeInterval ?? 0
        guard timestamp > lastConfigTimestamp else { return }
        lastConfigTimestamp = timestamp
        if enabled != isLagEnabled {
            isLagEnabled = enabled
            NSLog("[FakeLag] lag toggled -> \(isLagEnabled)")
        }
    }

    // MARK: - Read Loop

    private func startReadLoop() {
        queue.async { [weak self] in
            self?.readLoop()
        }
    }

    private func readLoop() {
        guard isRunning else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { return }
            self.queue.async {
                for i in 0..<packets.count {
                    self.handlePacket(packets[i], proto: protocols[i].int32Value)
                }
            }
            self.queue.async { [weak self] in
                self?.readLoop()
            }
        }
    }

    // MARK: - Packet Handler

    private func handlePacket(_ packet: Data, proto: Int32) {
        guard isRunning else { return }

        if proto == AF_INET6 {
            passThrough(packet: packet, proto: AF_INET6)
            return
        }
        if proto != AF_INET {
            passThrough(packet: packet, proto: proto)
            return
        }

        guard packet.count >= 20 else {
            passThrough(packet: packet, proto: AF_INET)
            return
        }
        guard (packet[0] >> 4) & 0x0F == 4 else {
            passThrough(packet: packet, proto: AF_INET)
            return
        }

        let ipProto = packet[9]

        if !isLagEnabled {
            passThrough(packet: packet, proto: AF_INET)
            return
        }

        switch ipProto {
        case 17: // UDP
            handleUDPLag(packet: packet, proto: AF_INET)
        case 6:  // TCP
            handleTCPLag(packet: packet, proto: AF_INET)
        default:
            passThrough(packet: packet, proto: AF_INET)
        }
    }

    // MARK: - Pass-through

    private func passThrough(packet: Data, proto: Int32) {
        guard isRunning else { return }
        queue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            let ok = self.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: proto)])
            if !ok {
                NSLog("[FakeLag] writePackets failed proto=\(proto) len=\(packet.count)")
            }
        }
    }

    // MARK: - UDP Lag

    private func handleUDPLag(packet: Data, proto: Int32) {
        if Int.random(in: 0..<100) < 15 {
            return // Drop 15%
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            self?.passThrough(packet: packet, proto: proto)
        }
    }

    // MARK: - TCP Lag

    private func handleTCPLag(packet: Data, proto: Int32) {
        if Int.random(in: 0..<100) < 5 {
            return // Drop 5%
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            self?.passThrough(packet: packet, proto: proto)
        }
    }
}
