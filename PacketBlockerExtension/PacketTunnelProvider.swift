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

    fileprivate var isLagEnabled = false
    private var lastConfigTimestamp: TimeInterval = 0
    let queue = DispatchQueue(label: "com.fakelag", qos: .userInitiated)
    private var isRunning = false
    private var configTimer: DispatchSourceTimer?
    private var cleanupTimer: DispatchSourceTimer?
    private var isReading = false

    // Per-flow UDP sessions (1 per src-dst pair) - REQUIRED for proper 2-way tracking
    fileprivate var udpV4: [String: UDPSessionV4] = [:]
    fileprivate let udpV4Lock = NSLock()
    fileprivate let maxUdpV4 = 50

    fileprivate var udpV6: [String: UDPSessionV6] = [:]
    fileprivate let udpV6Lock = NSLock()
    fileprivate let maxUdpV6 = 30

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
            guard let self = self else { completionHandler(nil); return }
            if let error = error {
                NSLog("[FakeLag] startTunnel FAILED: \(error)")
                completionHandler(error)
                return
            }
            self.isRunning = true
            NSLog("[FakeLag] Tunnel UP")
            self.startConfigWatcher()
            self.startCleanupWatcher()
            self.startReadLoop()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[FakeLag] stopTunnel reason=\(reason.rawValue)")
        isRunning = false
        isLagEnabled = false
        isReading = false
        configTimer?.cancel(); configTimer = nil
        cleanupTimer?.cancel(); cleanupTimer = nil

        udpV4Lock.lock()
        for (_, s) in udpV4 { s.connection.cancel() }
        udpV4.removeAll()
        udpV4Lock.unlock()

        udpV6Lock.lock()
        for (_, s) in udpV6 { s.connection.cancel() }
        udpV6.removeAll()
        udpV6Lock.unlock()

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

    // MARK: - Cleanup Watcher (every 5 seconds, aggressive)

    private func startCleanupWatcher() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0)
        timer.setEventHandler { [weak self] in self?.cleanup() }
        timer.resume()
        cleanupTimer = timer
    }

    private func cleanup() {
        let now = Date().timeIntervalSince1970

        udpV4Lock.lock()
        var v4r: [String] = []
        for (k, s) in udpV4 { if now - s.lastActivity > 15.0 { s.connection.cancel(); v4r.append(k) } }
        for k in v4r { udpV4.removeValue(forKey: k) }
        let v4c = udpV4.count
        udpV4Lock.unlock()

        udpV6Lock.lock()
        var v6r: [String] = []
        for (k, s) in udpV6 { if now - s.lastActivity > 15.0 { s.connection.cancel(); v6r.append(k) } }
        for k in v6r { udpV6.removeValue(forKey: k) }
        let v6c = udpV6.count
        udpV6Lock.unlock()

        if !v4r.isEmpty || !v6r.isEmpty {
            NSLog("[FakeLag] cleanup v4=\(v4c) v6=\(v6c)")
        }
    }

    // MARK: - Read Loop

    private func startReadLoop() {
        guard isRunning, !isReading else { return }
        isReading = true
        readLoop()
    }

    private func readLoop() {
        guard isRunning else { isReading = false; return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { self?.isReading = false; return }
            for i in 0..<packets.count {
                self.handlePacket(packets[i], proto: protocols[i].int32Value)
            }
            self.readLoop()
        }
    }

    // MARK: - Packet Handler

    private func handlePacket(_ packet: Data, proto: Int32) {
        if proto == AF_INET {
            handleIPv4(packet)
        } else if proto == AF_INET6 {
            handleIPv6(packet)
        }
    }

    // MARK: - IPv4

    private func handleIPv4(_ packet: Data) {
        guard packet.count >= 20 else { return }
        guard (packet[0] >> 4) & 0x0F == 4 else { return }
        let ihl = Int(packet[0] & 0x0F) * 4
        guard packet.count >= ihl else { return }

        let srcIP = (UInt32(packet[12]) << 24) | (UInt32(packet[13]) << 16) | (UInt32(packet[14]) << 8) | UInt32(packet[15])
        let dstIP = (UInt32(packet[16]) << 24) | (UInt32(packet[17]) << 16) | (UInt32(packet[18]) << 8) | UInt32(packet[19])
        let proto = packet[9]

        switch proto {
        case 1:
            handleICMPv4(packet: packet, srcIP: srcIP, dstIP: dstIP, ihl: ihl)
        case 6:
            sendTCPReset(srcIP: dstIP, dstIP: srcIP, packet: packet, ihl: ihl)
        case 17:
            handleUDPv4(packet: packet, srcIP: srcIP, dstIP: dstIP, ihl: ihl)
        default:
            break
        }
    }

    // MARK: - IPv6

    private func handleIPv6(_ packet: Data) {
        guard packet.count >= 40 else { return }
        guard (packet[0] >> 4) & 0x0F == 6 else { return }

        let nextHeader = packet[6]
        let payloadLen = Int((UInt16(packet[4]) << 8) | UInt16(packet[5]))
        guard packet.count >= 40 + payloadLen else { return }

        let srcIP = packet.subdata(in: 8..<24)
        let dstIP = packet.subdata(in: 24..<40)

        switch nextHeader {
        case 17:
            handleUDPv6(packet: packet, srcIP: srcIP, dstIP: dstIP)
        case 6:
            break
        case 58:
            if packet.count >= 41 && packet[40] == 128 {
                sendICMPv6EchoReply(packet: packet, srcIP: srcIP, dstIP: dstIP)
            }
        default:
            break
        }
    }

    // MARK: - ICMPv4 Echo Reply

    private func handleICMPv4(packet: Data, srcIP: UInt32, dstIP: UInt32, ihl: Int) {
        guard packet.count >= ihl + 8, packet[ihl] == 8 else { return }
        var reply = Data(count: packet.count - ihl)
        reply[0] = 0; reply[1] = 0; reply[2] = 0; reply[3] = 0
        reply[4] = packet[ihl + 4]; reply[5] = packet[ihl + 5]
        reply[6] = packet[ihl + 6]; reply[7] = packet[ihl + 7]
        if packet.count > ihl + 8 {
            reply.replaceSubrange(8..<reply.count, with: packet.subdata(in: (ihl + 8)..<packet.count))
        }
        let cksum = ipChecksum(reply)
        reply[2] = UInt8(cksum >> 8); reply[3] = UInt8(cksum & 0xFF)
        guard isRunning else { return }
        let ipPacket = buildIPv4(srcIP: dstIP, dstIP: srcIP, proto: 1, payload: reply)
        let _ = packetFlow.writePackets([ipPacket], withProtocols: [NSNumber(value: AF_INET)])
    }

    // MARK: - ICMPv6 Echo Reply

    private func sendICMPv6EchoReply(packet: Data, srcIP: Data, dstIP: Data) {
        guard isRunning, packet.count >= 41 else { return }
        var reply = Data(count: packet.count - 40)
        reply[0] = 129; reply[1] = 0; reply[2] = 0; reply[3] = 0
        if packet.count > 41 {
            reply.replaceSubrange(4..<reply.count, with: packet.subdata(in: 41..<packet.count))
        }
        var ip6 = Data(count: 40)
        ip6[0] = 0x60
        ip6[4] = UInt8(reply.count >> 8); ip6[5] = UInt8(reply.count & 0xFF)
        ip6[6] = 58; ip6[7] = 64
        ip6.replaceSubrange(8..<24, with: srcIP)
        ip6.replaceSubrange(24..<40, with: dstIP)
        var full = Data(); full.append(ip6); full.append(reply)
        let _ = packetFlow.writePackets([full], withProtocols: [NSNumber(value: AF_INET6)])
    }

    // MARK: - TCP Reset (IPv4)

    private func sendTCPReset(srcIP: UInt32, dstIP: UInt32, packet: Data, ihl: Int) {
        guard packet.count >= ihl + 20 else { return }
        let srcPort = (UInt16(packet[ihl]) << 8) | UInt16(packet[ihl + 1])
        let dstPort = (UInt16(packet[ihl + 2]) << 8) | UInt16(packet[ihl + 3])
        let ack = (UInt32(packet[ihl + 4]) << 24) | (UInt32(packet[ihl + 5]) << 16) | (UInt32(packet[ihl + 6]) << 8) | UInt32(packet[ihl + 7])

        var tcp = Data(count: 20)
        tcp[0] = UInt8(dstPort >> 8); tcp[1] = UInt8(dstPort & 0xFF)
        tcp[2] = UInt8(srcPort >> 8); tcp[3] = UInt8(srcPort & 0xFF)
        tcp[4] = 0; tcp[5] = 0; tcp[6] = 0; tcp[7] = 0
        tcp[8] = UInt8((ack + 1) >> 24); tcp[9] = UInt8((ack + 1) >> 16)
        tcp[10] = UInt8((ack + 1) >> 8); tcp[11] = UInt8((ack + 1) & 0xFF)
        tcp[12] = 0x50; tcp[13] = 0x14
        tcp[14] = 0; tcp[15] = 0; tcp[16] = 0; tcp[17] = 0; tcp[18] = 0; tcp[19] = 0

        guard isRunning else { return }
        let ipPacket = buildIPv4(srcIP: srcIP, dstIP: dstIP, proto: 6, payload: tcp)
        let _ = packetFlow.writePackets([ipPacket], withProtocols: [NSNumber(value: AF_INET)])
    }

    // MARK: - UDPv4 (Per-flow, lightweight)

    private func handleUDPv4(packet: Data, srcIP: UInt32, dstIP: UInt32, ihl: Int) {
        guard packet.count >= ihl + 8 else { return }
        let srcPort = (UInt16(packet[ihl]) << 8) | UInt16(packet[ihl + 1])
        let dstPort = (UInt16(packet[ihl + 2]) << 8) | UInt16(packet[ihl + 3])
        let udpLen = Int((UInt16(packet[ihl + 4]) << 8) | UInt16(packet[ihl + 5]))
        let payloadStart = ihl + 8
        let payloadEnd = min(payloadStart + udpLen - 8, packet.count)
        guard payloadEnd > payloadStart else { return }
        let payload = packet.subdata(in: payloadStart..<payloadEnd)

        let key = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"

        udpV4Lock.lock()
        if let session = udpV4[key] {
            session.lastActivity = Date().timeIntervalSince1970
            udpV4Lock.unlock()
            session.send(payload, lag: isLagEnabled)
        } else {
            if udpV4.count >= maxUdpV4 {
                // Drop new packet if at limit - don't create more connections
                udpV4Lock.unlock()
                return
            }
            udpV4Lock.unlock()

            // Build endpoint string
            let ipStr = "\(dstIP >> 24).\(dstIP >> 16 & 0xFF).\(dstIP >> 8 & 0xFF).\(dstIP & 0xFF)"
            let host = NWEndpoint.Host(ipStr)
            guard let port = NWEndpoint.Port(rawValue: UInt16(dstPort)) else { return }
            let endpoint = NWEndpoint.hostPort(host: host, port: port)
            let conn = NWConnection(to: endpoint, using: .udp)
            let session = UDPSessionV4(key: key, connection: conn, srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, provider: self)

            udpV4Lock.lock()
            udpV4[key] = session
            udpV4Lock.unlock()

            conn.start(queue: queue)
            session.beginReceive()
            session.send(payload, lag: isLagEnabled)
        }
    }

    func writeUdpV4Response(srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, payload: Data) {
        guard isRunning else { return }
        if isLagEnabled {
            if Int.random(in: 0..<100) < 15 { return }
            queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                self?.buildAndWriteUdpV4(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, payload: payload)
            }
        } else {
            buildAndWriteUdpV4(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, payload: payload)
        }
    }

    private func buildAndWriteUdpV4(srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, payload: Data) {
        guard isRunning else { return }
        var udp = Data(count: 8)
        udp[0] = UInt8(srcPort >> 8); udp[1] = UInt8(srcPort & 0xFF)
        udp[2] = UInt8(dstPort >> 8); udp[3] = UInt8(dstPort & 0xFF)
        let ulen = 8 + payload.count
        udp[4] = UInt8(ulen >> 8); udp[5] = UInt8(ulen & 0xFF)
        udp[6] = 0; udp[7] = 0
        var full = Data(); full.append(udp); full.append(payload)
        let ipPacket = buildIPv4(srcIP: srcIP, dstIP: dstIP, proto: 17, payload: full)
        let _ = packetFlow.writePackets([ipPacket], withProtocols: [NSNumber(value: AF_INET)])
    }

    // MARK: - UDPv6 (Per-flow, lightweight)

    private func handleUDPv6(packet: Data, srcIP: Data, dstIP: Data) {
        guard packet.count >= 48 else { return }
        let srcPort = (UInt16(packet[40]) << 8) | UInt16(packet[41])
        let dstPort = (UInt16(packet[42]) << 8) | UInt16(packet[43])
        let udpLen = Int((UInt16(packet[44]) << 8) | UInt16(packet[45]))
        let payloadStart = 48
        let payloadEnd = min(payloadStart + udpLen - 8, packet.count)
        guard payloadEnd > payloadStart else { return }
        let payload = packet.subdata(in: payloadStart..<payloadEnd)

        let srcHex = srcIP.map { String(format: "%02x", $0) }.joined()
        let dstHex = dstIP.map { String(format: "%02x", $0) }.joined()
        let key = "\(srcHex):\(srcPort)-\(dstHex):\(dstPort)"

        udpV6Lock.lock()
        if let session = udpV6[key] {
            session.lastActivity = Date().timeIntervalSince1970
            udpV6Lock.unlock()
            session.send(payload, lag: isLagEnabled)
        } else {
            if udpV6.count >= maxUdpV6 {
                udpV6Lock.unlock()
                return
            }
            udpV6Lock.unlock()

            let ipStr = ipv6String(dstIP)
            guard !ipStr.isEmpty else { return }
            let host = NWEndpoint.Host(ipStr)
            guard let port = NWEndpoint.Port(rawValue: UInt16(dstPort)) else { return }
            let endpoint = NWEndpoint.hostPort(host: host, port: port)
            let conn = NWConnection(to: endpoint, using: .udp)
            let session = UDPSessionV6(key: key, connection: conn, srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, provider: self)

            udpV6Lock.lock()
            udpV6[key] = session
            udpV6Lock.unlock()

            conn.start(queue: queue)
            session.beginReceive()
            session.send(payload, lag: isLagEnabled)
        }
    }

    func writeUdpV6Response(srcIP: Data, srcPort: UInt16, dstIP: Data, dstPort: UInt16, payload: Data) {
        guard isRunning else { return }
        if isLagEnabled {
            if Int.random(in: 0..<100) < 15 { return }
            queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                self?.buildAndWriteUdpV6(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, payload: payload)
            }
        } else {
            buildAndWriteUdpV6(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, payload: payload)
        }
    }

    private func buildAndWriteUdpV6(srcIP: Data, srcPort: UInt16, dstIP: Data, dstPort: UInt16, payload: Data) {
        guard isRunning else { return }
        var udp = Data(count: 8)
        udp[0] = UInt8(srcPort >> 8); udp[1] = UInt8(srcPort & 0xFF)
        udp[2] = UInt8(dstPort >> 8); udp[3] = UInt8(dstPort & 0xFF)
        let ulen = 8 + payload.count
        udp[4] = UInt8(ulen >> 8); udp[5] = UInt8(ulen & 0xFF)
        udp[6] = 0; udp[7] = 0

        var ip6 = Data(count: 40)
        ip6[0] = 0x60
        ip6[4] = UInt8(ulen >> 8); ip6[5] = UInt8(ulen & 0xFF)
        ip6[6] = 17; ip6[7] = 64
        ip6.replaceSubrange(8..<24, with: srcIP)
        ip6.replaceSubrange(24..<40, with: dstIP)

        var full = Data()
        full.append(ip6)
        full.append(udp)
        full.append(payload)
        let _ = packetFlow.writePackets([full], withProtocols: [NSNumber(value: AF_INET6)])
    }

    // MARK: - IPv4 Builder

    fileprivate func buildIPv4(srcIP: UInt32, dstIP: UInt32, proto: UInt8, payload: Data) -> Data {
        var packet = Data(count: 20 + payload.count)
        packet[0] = 0x45
        let totalLen = 20 + payload.count
        packet[2] = UInt8(totalLen >> 8); packet[3] = UInt8(totalLen & 0xFF)
        packet[4] = 0; packet[5] = 0; packet[6] = 0x40; packet[7] = 0
        packet[8] = 64; packet[9] = proto
        packet[12] = UInt8(srcIP >> 24); packet[13] = UInt8(srcIP >> 16); packet[14] = UInt8(srcIP >> 8); packet[15] = UInt8(srcIP)
        packet[16] = UInt8(dstIP >> 24); packet[17] = UInt8(dstIP >> 16); packet[18] = UInt8(dstIP >> 8); packet[19] = UInt8(dstIP)
        let cksum = ipChecksum(packet[0..<20])
        packet[10] = UInt8(cksum >> 8); packet[11] = UInt8(cksum & 0xFF)
        packet.replaceSubrange(20..<packet.count, with: payload)
        return packet
    }

    // MARK: - IPv6 String

    fileprivate func ipv6String(_ bytes: Data) -> String {
        guard bytes.count == 16 else { return "" }
        var parts: [String] = []
        for i in stride(from: 0, to: 16, by: 2) {
            let val = (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
            parts.append(String(format: "%04x", val))
        }
        return parts.joined(separator: ":")
    }
}

// MARK: - UDPv4 Session (Per-flow)
fileprivate class UDPSessionV4 {
    let key: String
    let connection: NWConnection
    let srcIP: UInt32, srcPort: UInt16
    let dstIP: UInt32, dstPort: UInt16
    weak var provider: PacketTunnelProvider?
    var lastActivity: TimeInterval
    private var isReceiving = false

    init(key: String, connection: NWConnection, srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, provider: PacketTunnelProvider) {
        self.key = key; self.connection = connection
        self.srcIP = srcIP; self.srcPort = srcPort
        self.dstIP = dstIP; self.dstPort = dstPort
        self.provider = provider
        self.lastActivity = Date().timeIntervalSince1970
    }

    func beginReceive() {
        guard !isReceiving else { return }
        isReceiving = true
        receive()
    }

    func send(_ payload: Data, lag: Bool) {
        lastActivity = Date().timeIntervalSince1970
        if lag {
            if Int.random(in: 0..<100) < 15 { return }
            provider?.queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                self?.sendNow(payload)
            }
        } else {
            sendNow(payload)
        }
    }

    private func sendNow(_ payload: Data) {
        lastActivity = Date().timeIntervalSince1970
        connection.send(content: payload, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            self.lastActivity = Date().timeIntervalSince1970
            if let data = data, !data.isEmpty {
                self.provider?.writeUdpV4Response(srcIP: self.dstIP, srcPort: self.dstPort, dstIP: self.srcIP, dstPort: self.srcPort, payload: data)
            }
            if error == nil {
                self.receive()
            }
        }
    }
}

// MARK: - UDPv6 Session (Per-flow)
fileprivate class UDPSessionV6 {
    let key: String
    let connection: NWConnection
    let srcIP: Data, dstIP: Data
    let srcPort: UInt16, dstPort: UInt16
    weak var provider: PacketTunnelProvider?
    var lastActivity: TimeInterval
    private var isReceiving = false

    init(key: String, connection: NWConnection, srcIP: Data, srcPort: UInt16, dstIP: Data, dstPort: UInt16, provider: PacketTunnelProvider) {
        self.key = key; self.connection = connection
        self.srcIP = srcIP; self.srcPort = srcPort
        self.dstIP = dstIP; self.dstPort = dstPort
        self.provider = provider
        self.lastActivity = Date().timeIntervalSince1970
    }

    func beginReceive() {
        guard !isReceiving else { return }
        isReceiving = true
        receive()
    }

    func send(_ payload: Data, lag: Bool) {
        lastActivity = Date().timeIntervalSince1970
        if lag {
            if Int.random(in: 0..<100) < 15 { return }
            provider?.queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                self?.sendNow(payload)
            }
        } else {
            sendNow(payload)
        }
    }

    private func sendNow(_ payload: Data) {
        lastActivity = Date().timeIntervalSince1970
        connection.send(content: payload, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            self.lastActivity = Date().timeIntervalSince1970
            if let data = data, !data.isEmpty {
                self.provider?.writeUdpV6Response(srcIP: self.dstIP, srcPort: self.dstPort, dstIP: self.srcIP, dstPort: self.srcPort, payload: data)
            }
            if error == nil {
                self.receive()
            }
        }
    }
}
