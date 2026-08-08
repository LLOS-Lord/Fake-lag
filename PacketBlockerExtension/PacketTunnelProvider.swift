import NetworkExtension
import Network
import Foundation

// MARK: - IP Checksum
fileprivate func ipChecksum(_ data: Data) -> UInt16 {
    var sum: UInt32 = 0
    let count = data.count
    var i = 0
    while i < count - 1 {
        sum += (UInt32(data[i]) << 8) | UInt32(data[i + 1])
        i += 2
    }
    if i < count {
        sum += UInt32(data[i]) << 8
    }
    while (sum >> 16) != 0 {
        sum = (sum & 0xFFFF) + (sum >> 16)
    }
    return ~UInt16(sum & 0xFFFF)
}

// MARK: - PacketTunnelProvider
class PacketTunnelProvider: NEPacketTunnelProvider {

    // MARK: State
    fileprivate var isLagEnabled = false
    private var lastConfigTimestamp: TimeInterval = 0
    let queue = DispatchQueue(label: "com.fakelag", qos: .userInitiated)
    private var isRunning = false
    private var configTimer: DispatchSourceTimer?
    private var cleanupTimer: DispatchSourceTimer?
    private var isReading = false

    // UDP sessions
    fileprivate var udpSessions: [String: UDPSession] = [:]
    fileprivate let udpLock = NSLock()
    fileprivate let maxUDPSessions = 100

    private var configURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.ban.PacketBlocker"
        ) else {
            NSLog("[FakeLag] ERROR: Cannot get app group container")
            return nil
        }
        return container.appendingPathComponent("fakelag_config.plist")
    }

    // MARK: - Lifecycle

    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[FakeLag] ===== startTunnel called =====")
        isLagEnabled = false
        lastConfigTimestamp = 0
        isReading = false

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1500

        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

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
            NSLog("[FakeLag] ===== Tunnel UP. All traffic routed. Lag=OFF =====")
            self?.startConfigWatcher()
            self?.startCleanupWatcher()
            self?.startReadLoop()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[FakeLag] ===== stopTunnel called. Reason: \(reason.rawValue) =====")
        isRunning = false
        isLagEnabled = false
        isReading = false
        configTimer?.cancel()
        configTimer = nil
        cleanupTimer?.cancel()
        cleanupTimer = nil
        udpLock.lock()
        for (_, session) in udpSessions {
            session.connection.cancel()
        }
        udpSessions.removeAll()
        udpLock.unlock()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(Data("ok".utf8))
    }

    // MARK: - Config Watcher

    private func startConfigWatcher() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.checkConfig()
        }
        timer.resume()
        configTimer = timer
    }

    private func checkConfig() {
        guard let url = configURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return
        }
        let enabled = dict["enabled"] as? Bool ?? false
        let timestamp = dict["timestamp"] as? TimeInterval ?? 0
        guard timestamp > lastConfigTimestamp else { return }
        lastConfigTimestamp = timestamp
        if enabled != isLagEnabled {
            isLagEnabled = enabled
            NSLog("[FakeLag] ===== Config changed: lag=\(isLagEnabled) (ts=\(timestamp)) =====")
        }
    }

    // MARK: - Cleanup Watcher

    private func startCleanupWatcher() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30.0, repeating: 30.0)
        timer.setEventHandler { [weak self] in
            self?.cleanupOldSessions()
        }
        timer.resume()
        cleanupTimer = timer
    }

    private func cleanupOldSessions() {
        let now = Date().timeIntervalSince1970
        udpLock.lock()
        var keysToRemove: [String] = []
        for (key, session) in udpSessions {
            if now - session.lastActivity > 60.0 {
                session.connection.cancel()
                keysToRemove.append(key)
            }
        }
        for key in keysToRemove {
            udpSessions.removeValue(forKey: key)
        }
        let count = udpSessions.count
        udpLock.unlock()
        if !keysToRemove.isEmpty {
            NSLog("[FakeLag] Cleaned up \(keysToRemove.count) UDP sessions, remaining: \(count)")
        }
    }

    // MARK: - Read Loop

    private func startReadLoop() {
        guard isRunning, !isReading else { return }
        isReading = true
        readLoop()
    }

    private func readLoop() {
        guard isRunning else {
            isReading = false
            return
        }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else {
                self?.isReading = false
                return
            }
            for i in 0..<packets.count {
                do {
                    let packet = packets[i]
                    let proto = protocols[i].int32Value
                    try self.handlePacket(packet, proto: proto)
                } catch {
                    NSLog("[FakeLag] Packet handler error: \(error)")
                }
            }
            self.readLoop()
        }
    }

    // MARK: - Packet Handler

    private func handlePacket(_ packet: Data, proto: Int32) throws {
        guard proto == AF_INET else { return }
        guard packet.count >= 20 else { return }
        let version = (packet[0] >> 4) & 0x0F
        guard version == 4 else { return }
        let ihl = Int(packet[0] & 0x0F) * 4
        guard packet.count >= ihl else { return }

        let srcIP = (UInt32(packet[12]) << 24) | (UInt32(packet[13]) << 16) | (UInt32(packet[14]) << 8) | UInt32(packet[15])
        let dstIP = (UInt32(packet[16]) << 24) | (UInt32(packet[17]) << 16) | (UInt32(packet[18]) << 8) | UInt32(packet[19])
        let ipProto = packet[9]

        switch ipProto {
        case 1:
            try handleICMP(packet: packet, srcIP: srcIP, dstIP: dstIP, ihl: ihl)
        case 6:
            // TCP: drop silently to avoid complex proxy crashes
            // Free Fire mainly uses UDP
            break
        case 17:
            try handleUDP(packet: packet, srcIP: srcIP, dstIP: dstIP, ihl: ihl)
        default:
            break
        }
    }

    // MARK: - ICMP Echo Reply

    private func handleICMP(packet: Data, srcIP: UInt32, dstIP: UInt32, ihl: Int) throws {
        guard packet.count >= ihl + 8 else { return }
        let type = packet[ihl]
        guard type == 8 else { return }

        var reply = Data(count: packet.count - ihl)
        reply[0] = 0
        reply[1] = 0
        reply[2] = 0
        reply[3] = 0
        reply[4] = packet[ihl + 4]
        reply[5] = packet[ihl + 5]
        reply[6] = packet[ihl + 6]
        reply[7] = packet[ihl + 7]
        if packet.count > ihl + 8 {
            reply.replaceSubrange(8..<reply.count, with: packet.subdata(in: (ihl + 8)..<packet.count))
        }
        let cksum = ipChecksum(reply)
        reply[2] = UInt8(cksum >> 8)
        reply[3] = UInt8(cksum & 0xFF)

        guard isRunning else { return }
        let ipPacket = buildIPv4Packet(srcIP: dstIP, dstIP: srcIP, protocol: 1, payload: reply)
        let _ = packetFlow.writePackets([ipPacket], withProtocols: [NSNumber(value: AF_INET)])
    }

    // MARK: - UDP Proxy

    private func handleUDP(packet: Data, srcIP: UInt32, dstIP: UInt32, ihl: Int) throws {
        guard packet.count >= ihl + 8 else { return }
        let srcPort = (UInt16(packet[ihl]) << 8) | UInt16(packet[ihl + 1])
        let dstPort = (UInt16(packet[ihl + 2]) << 8) | UInt16(packet[ihl + 3])
        let udpLen = Int((UInt16(packet[ihl + 4]) << 8) | UInt16(packet[ihl + 5]))
        let payloadStart = ihl + 8
        let payloadEnd = min(payloadStart + udpLen - 8, packet.count)
        guard payloadEnd > payloadStart else { return }
        let payload = packet.subdata(in: payloadStart..<payloadEnd)

        let key = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"

        udpLock.lock()
        if let session = udpSessions[key] {
            session.lastActivity = Date().timeIntervalSince1970
            udpLock.unlock()
            forwardUDP(session: session, payload: payload)
        } else {
            // Enforce max sessions limit
            if udpSessions.count >= maxUDPSessions {
                // Remove oldest session
                if let oldestKey = udpSessions.min(by: { $0.value.lastActivity < $1.value.lastActivity })?.key {
                    udpSessions[oldestKey]?.connection.cancel()
                    udpSessions.removeValue(forKey: oldestKey)
                }
            }
            let session = UDPSession(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, provider: self)
            udpSessions[key] = session
            udpLock.unlock()
            forwardUDP(session: session, payload: payload)
        }
    }

    private func forwardUDP(session: UDPSession, payload: Data) {
        if isLagEnabled {
            if Int.random(in: 0..<100) < 15 {
                return // Drop
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak session] in
                session?.send(payload)
            }
        } else {
            session.send(payload)
        }
    }

    func writeUDPResponse(srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, payload: Data) {
        guard isRunning else { return }
        if isLagEnabled {
            if Int.random(in: 0..<100) < 15 {
                return // Drop inbound
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                self?.buildAndWriteUDP(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, payload: payload)
            }
        } else {
            buildAndWriteUDP(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, payload: payload)
        }
    }

    private func buildAndWriteUDP(srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, payload: Data) {
        guard isRunning else { return }
        var udp = Data(count: 8)
        udp[0] = UInt8(srcPort >> 8)
        udp[1] = UInt8(srcPort & 0xFF)
        udp[2] = UInt8(dstPort >> 8)
        udp[3] = UInt8(dstPort & 0xFF)
        let ulen = 8 + payload.count
        udp[4] = UInt8(ulen >> 8)
        udp[5] = UInt8(ulen & 0xFF)
        udp[6] = 0
        udp[7] = 0

        var full = Data()
        full.append(udp)
        full.append(payload)

        let ipPacket = buildIPv4Packet(srcIP: srcIP, dstIP: dstIP, protocol: 17, payload: full)
        let _ = packetFlow.writePackets([ipPacket], withProtocols: [NSNumber(value: AF_INET)])
    }

    // MARK: - IP Packet Builder

    fileprivate func buildIPv4Packet(srcIP: UInt32, dstIP: UInt32, protocol: UInt8, payload: Data) -> Data {
        var packet = Data(count: 20 + payload.count)
        packet[0] = 0x45
        let totalLen = 20 + payload.count
        packet[2] = UInt8(totalLen >> 8)
        packet[3] = UInt8(totalLen & 0xFF)
        packet[4] = 0
        packet[5] = 0
        packet[6] = 0x40
        packet[7] = 0
        packet[8] = 64
        packet[9] = `protocol`
        packet[12] = UInt8(srcIP >> 24)
        packet[13] = UInt8(srcIP >> 16)
        packet[14] = UInt8(srcIP >> 8)
        packet[15] = UInt8(srcIP)
        packet[16] = UInt8(dstIP >> 24)
        packet[17] = UInt8(dstIP >> 16)
        packet[18] = UInt8(dstIP >> 8)
        packet[19] = UInt8(dstIP)

        let cksum = ipChecksum(packet[0..<20])
        packet[10] = UInt8(cksum >> 8)
        packet[11] = UInt8(cksum & 0xFF)

        packet.replaceSubrange(20..<packet.count, with: payload)
        return packet
    }
}

// MARK: - UDP Session
fileprivate class UDPSession {
    let connection: NWConnection
    let srcIP: UInt32, srcPort: UInt16
    let dstIP: UInt32, dstPort: UInt16
    weak var provider: PacketTunnelProvider?
    var lastActivity: TimeInterval

    init(srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, provider: PacketTunnelProvider) {
        self.srcIP = srcIP; self.srcPort = srcPort
        self.dstIP = dstIP; self.dstPort = dstPort
        self.provider = provider
        self.lastActivity = Date().timeIntervalSince1970

        let ipStr = "\(dstIP >> 24).\(dstIP >> 16 & 0xFF).\(dstIP >> 8 & 0xFF).\(dstIP & 0xFF)"
        let host = NWEndpoint.Host(ipStr)
        let port = NWEndpoint.Port(integerLiteral: UInt16(dstPort))
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
        connection = NWConnection(to: endpoint, using: .udp)
        connection.start(queue: provider.queue)
        receive()
    }

    func send(_ data: Data) {
        lastActivity = Date().timeIntervalSince1970
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            self.lastActivity = Date().timeIntervalSince1970
            if let data = data, !data.isEmpty {
                self.provider?.writeUDPResponse(srcIP: self.dstIP, srcPort: self.dstPort, dstIP: self.srcIP, dstPort: self.srcPort, payload: data)
            }
            if error == nil {
                self.receive()
            }
        }
    }
}
