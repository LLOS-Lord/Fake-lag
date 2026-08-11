import NetworkExtension
import Network
import Foundation

// ============================================================================
// MARK: - PacketTunnelProvider (Ultra-Light v4 - Stable Pass-through)
// ============================================================================
// Logic: Đọc packet → delay/drop (nếu lag ON) → write lại
// Không proxy qua NWConnection → không giới hạn session, không crash
// Đã fix: IPv6 pass-through, async write tránh deadlock, đúng protocol
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
        NSLog("[FakeLag] startTunnel")
        isLagEnabled = false
        lastConfigTimestamp = 0

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1500

        // IPv4: route all
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        // IPv6: route all (pass-through, không xử lý sâu)
        let ipv6 = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                NSLog("[FakeLag] startTunnel FAILED: \(error)")
                completionHandler(error)
                return
            }
            self?.isRunning = true
            NSLog("[FakeLag] Tunnel UP")
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
            NSLog("[FakeLag] lag=\(isLagEnabled)")
        }
    }

    // MARK: - Read Loop (Non-blocking)

    private func startReadLoop() {
        queue.async { [weak self] in
            self?.readLoop()
        }
    }

    private func readLoop() {
        guard isRunning else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { return }
            // Tránh xử lý nặng trong callback → schedule lên queue
            self.queue.async {
                for i in 0..<packets.count {
                    self.handlePacket(packets[i], proto: protocols[i].int32Value)
                }
            }
            // Schedule read tiếp theo async → không đệ quy đồng bộ
            self.queue.async { [weak self] in
                self?.readLoop()
            }
        }
    }

    // MARK: - Packet Handler

    private func handlePacket(_ packet: Data, proto: Int32) {
        guard isRunning else { return }

        // IPv6: pass-through ngay, không xử lý sâu
        if proto == AF_INET6 {
            passThrough(packet: packet, proto: AF_INET6)
            return
        }

        // Không phải IPv4/IPv6: pass-through
        if proto != AF_INET {
            passThrough(packet: packet, proto: proto)
            return
        }

        // IPv4
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
            // Không lag → pass-through async (tránh deadlock với readPackets callback)
            passThrough(packet: packet, proto: AF_INET)
            return
        }

        // Lag enabled
        switch ipProto {
        case 17: // UDP
            handleUDPLag(packet: packet, proto: AF_INET)
        case 6:  // TCP
            handleTCPLag(packet: packet, proto: AF_INET)
        default:
            // ICMP, v.v. → pass-through
            passThrough(packet: packet, proto: AF_INET)
        }
    }

    // MARK: - Pass-through

    /// Ghi packet lại tunnel. Luôn async trên queue để tránh block/block readPackets callback.
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
        // Drop 15% UDP packet
        if Int.random(in: 0..<100) < 15 {
            return // Drop silently
        }
        // Delay 300ms cho 85% còn lại
        queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            self?.passThrough(packet: packet, proto: proto)
        }
    }

    // MARK: - TCP Lag

    private func handleTCPLag(packet: Data, proto: Int32) {
        // TCP nhạy cảm: chỉ drop 5%, delay 300ms
        if Int.random(in: 0..<100) < 5 {
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            self?.passThrough(packet: packet, proto: proto)
        }
    }
}
