import NetworkExtension
import Network
import Foundation

// ============================================================================
// MARK: - PacketTunnelProvider (Ultra-Light v2)
// ============================================================================
// - Chỉ IPv4 UDP (Free Fire) + IPv4 TCP (web/app cơ bản)
// - Bỏ IPv6, ICMP (giảm tải)
// - Max 20 UDP sessions, 10 TCP sessions
// - Callback readPackets return ngay lập tức
// - Heavy work trên background queue
// ============================================================================

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var isLagEnabled = false
    private var lastConfigTimestamp: TimeInterval = 0
    private let queue = DispatchQueue(label: "com.fakelag", qos: .userInitiated)
    private var isRunning = false
    private var configTimer: DispatchSourceTimer?
    private var cleanupTimer: DispatchSourceTimer?

    // UDP sessions
    private var udpSessions: [String: UDPSession] = [:]
    private let udpLock = NSLock()
    private let maxUDP = 20

    // TCP sessions
    private var tcpSessions: [String: TCPSession] = [:]
    private let tcpLock = NSLock()
    private let maxTCP = 10

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
            NSLog("[FakeLag] Tunnel UP")
            self?.startConfigWatcher()
            self?.startCleanupWatcher()
            self?.startReadLoop()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[FakeLag] stopTunnel reason=\(reason.rawValue)")
        isRunning = false
        configTimer?.cancel(); configTimer = nil
        cleanupTimer?.cancel(); cleanupTimer = nil
        udpLock.lock()
        for (_, s) in udpSessions { s.conn.cancel() }
        udpSessions.removeAll()
        udpLock.unlock()
        tcpLock.lock()
        for (_, s) in tcpSessions { s.conn.cancel() }
        tcpSessions.removeAll()
        tcpLock.unlock()
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

    // MARK: - Cleanup Watcher

    private func startCleanupWatcher() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10.0, repeating: 10.0)
        timer.setEventHandler { [weak self] in self?.cleanup() }
        timer.resume()
        cleanupTimer = timer
    }

    private func cleanup() {
        let now = Date().timeIntervalSince1970
        udpLock.lock()
        var udpRemove: [String] = []
        for (k, s) in udpSessions {
            if now - s.lastActivity > 30.0 {
                s.conn.cancel()
                udpRemove.append(k)
            }
        }
        for k in udpRemove { udpSessions.removeValue(forKey: k) }
        let udpCount = udpSessions.count
        udpLock.unlock()

        tcpLock.lock()
        var tcpRemove: [String] = []
        for (k, s) in tcpSessions {
            var shouldRemove = false
            if case .cancelled = s.conn.state { shouldRemove = true }
            if case .failed = s.conn.state { shouldRemove = true }
            if shouldRemove || now - s.lastActivity > 300.0 {
                s.conn.cancel()
                tcpRemove.append(k)
            }
        }
        for k in tcpRemove { tcpSessions.removeValue(forKey: k) }
        let tcpCount = tcpSessions.count
        tcpLock.unlock()

        if !udpRemove.isEmpty || !tcpRemove.isEmpty {
            NSLog("[FakeLag] cleanup UDP=\(udpCount) TCP=\(tcpCount)")
        }
    }

    // MARK: - Read Loop

    private func startReadLoop() {
        readLoop()
    }

    private func readLoop() {
        guard isRunning else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { return }
            // Enqueue to background queue - callback must return FAST
            self.queue.async {
                autoreleasepool {
                    for i in 0..<packets.count {
                        self.handlePacket(packets[i], proto: protocols[i].int32Value)
                    }
                }
            }
            self.readLoop()
        }
    }

    // MARK: - Packet Handler

    private func handlePacket(_ packet: Data, proto: Int32) {
        guard proto == AF_INET else { return }
        guard packet.count >= 20 else { return }
        guard (packet[0] >> 4) & 0x0F == 4 else { return }
        let ihl = Int(packet[0] & 0x0F) * 4
        guard packet.count >= ihl else { return }

        let srcIP = (UInt32(packet[12]) << 24) | (UInt32(packet[13]) << 16) | (UInt32(packet[14]) << 8) | UInt32(packet[15])
        let dstIP = (UInt32(packet[16]) << 24) | (UInt32(packet[17]) << 16) | (UInt32(packet[18]) << 8) | UInt32(packet[19])
        let ipProto = packet[9]

        switch ipProto {
        case 17: // UDP
            handleUDP(packet: packet, srcIP: srcIP, dstIP: dstIP, ihl: ihl)
        case 6:  // TCP
            handleTCP(packet: packet, srcIP: srcIP, dstIP: dstIP, ihl: ihl)
        default:
            break
        }
    }

    // MARK: - UDP Proxy

    private func handleUDP(packet: Data, srcIP: UInt32, dstIP: UInt32, ihl: Int) {
        guard packet.count >= ihl + 8 else { return }
        let srcPort = (UInt16(packet[ihl]) << 8) | UInt16(packet[ihl + 1])
        let dstPort = (UInt16(packet[ihl + 2]) << 8) | UInt16(packet[ihl + 3])
        let udpLen = Int((UInt16(packet[ihl + 4]) << 8) | UInt16(packet[ihl + 5]))
        let payloadStart = ihl + 8
        let payloadEnd = min(payloadStart + udpLen - 8, packet.count)
        guard payloadEnd > payloadStart else { return }
        let payload = packet.subdata(in: payloadStart..<payloadEnd)

        let key = "\(srcIP):\(srcPort):\(dstIP):\(dstPort)"

        udpLock.lock()
        if let session = udpSessions[key] {
            let conn = session.conn
            udpSessions[key]?.lastActivity = Date().timeIntervalSince1970
            udpLock.unlock()
            forwardUDP(conn: conn, payload: payload)
        } else {
            if udpSessions.count >= maxUDP {
                if let oldest = udpSessions.min(by: { $0.value.lastActivity < $1.value.lastActivity })?.key {
                    udpSessions[oldest]?.conn.cancel()
                    udpSessions.removeValue(forKey: oldest)
                }
            }
            let ipStr = "\(dstIP >> 24).\(dstIP >> 16 & 0xFF).\(dstIP >> 8 & 0xFF).\(dstIP & 0xFF)"
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ipStr), port: NWEndpoint.Port(integerLiteral: UInt16(dstPort)))
            let conn = NWConnection(to: endpoint, using: .udp)
            let session = UDPSession(conn: conn, srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort)
            udpSessions[key] = session
            udpLock.unlock()

            // Setup receive
            startUDPReceive(conn: conn, dstIP: dstIP, dstPort: dstPort, srcIP: srcIP, srcPort: srcPort)
            conn.start(queue: self.queue)
            forwardUDP(conn: conn, payload: payload)
        }
    }

    private func startUDPReceive(conn: NWConnection, dstIP: UInt32, dstPort: UInt16, srcIP: UInt32, srcPort: UInt16) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self = self, self.isRunning else { return }
            if let data = data, !data.isEmpty {
                self.writeUDPResponse(srcIP: dstIP, srcPort: dstPort, dstIP: srcIP, dstPort: srcPort, payload: data)
            }
            if error == nil {
                // Continue receiving
                self.startUDPReceive(conn: conn, dstIP: dstIP, dstPort: dstPort, srcIP: srcIP, srcPort: srcPort)
            }
        }
    }

    private func forwardUDP(conn: NWConnection, payload: Data) {
        if isLagEnabled {
            if Int.random(in: 0..<100) < 15 { return }
            queue.asyncAfter(deadline: .now() + .milliseconds(300)) {
                conn.send(content: payload, completion: .contentProcessed { _ in })
            }
        } else {
            conn.send(content: payload, completion: .contentProcessed { _ in })
        }
    }

    private func writeUDPResponse(srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, payload: Data) {
        guard isRunning else { return }
        if isLagEnabled {
            if Int.random(in: 0..<100) < 15 { return }
            queue.asyncAfter(deadline: .now() + .milliseconds(300)) {
                self.buildAndWriteUDP(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, payload: payload)
            }
        } else {
            buildAndWriteUDP(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, payload: payload)
        }
    }

    private func buildAndWriteUDP(srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, payload: Data) {
        guard isRunning else { return }
        var udp = Data(count: 8)
        udp[0] = UInt8(srcPort >> 8); udp[1] = UInt8(srcPort & 0xFF)
        udp[2] = UInt8(dstPort >> 8); udp[3] = UInt8(dstPort & 0xFF)
        let ulen = 8 + payload.count
        udp[4] = UInt8(ulen >> 8); udp[5] = UInt8(ulen & 0xFF)
        udp[6] = 0; udp[7] = 0
        var full = Data(); full.append(udp); full.append(payload)
        let ipPacket = buildIPv4Packet(srcIP: srcIP, dstIP: dstIP, protocol: 17, payload: full)
        let _ = packetFlow.writePackets([ipPacket], withProtocols: [NSNumber(value: AF_INET)])
    }

    // MARK: - TCP Proxy (Ultra-light)

    private func handleTCP(packet: Data, srcIP: UInt32, dstIP: UInt32, ihl: Int) {
        guard packet.count >= ihl + 20 else { return }
        let srcPort = (UInt16(packet[ihl]) << 8) | UInt16(packet[ihl + 1])
        let dstPort = (UInt16(packet[ihl + 2]) << 8) | UInt16(packet[ihl + 3])
        let seq = (UInt32(packet[ihl + 4]) << 24) | (UInt32(packet[ihl + 5]) << 16) | (UInt32(packet[ihl + 6]) << 8) | UInt32(packet[ihl + 7])
        let ack = (UInt32(packet[ihl + 8]) << 24) | (UInt32(packet[ihl + 9]) << 16) | (UInt32(packet[ihl + 10]) << 8) | UInt32(packet[ihl + 11])
        let dataOffset = Int((packet[ihl + 12] >> 4) & 0x0F) * 4
        let flags = packet[ihl + 13]
        let payloadStart = ihl + dataOffset
        let payload = payloadStart < packet.count ? packet.subdata(in: payloadStart..<packet.count) : Data()

        let key = "\(srcIP):\(srcPort):\(dstIP):\(dstPort)"
        let isSyn = (flags & 0x02) != 0
        let isAck = (flags & 0x10) != 0
        let isFin = (flags & 0x01) != 0
        let isRst = (flags & 0x04) != 0

        tcpLock.lock()
        if let session = tcpSessions[key] {
            session.lastActivity = Date().timeIntervalSince1970
            let conn = session.conn
            let state = session.state
            tcpLock.unlock()

            if isRst || isFin {
                conn.cancel()
                tcpLock.lock(); tcpSessions.removeValue(forKey: key); tcpLock.unlock()
                return
            }
            if isSyn && isAck { return }
            if isAck && state == .synAckSent {
                tcpLock.lock()
                tcpSessions[key]?.state = .established
                tcpLock.unlock()
            }
            if !payload.isEmpty {
                if isLagEnabled {
                    if Int.random(in: 0..<100) < 15 { return }
                    queue.asyncAfter(deadline: .now() + .milliseconds(300)) {
                        conn.send(content: payload, completion: .contentProcessed { _ in })
                    }
                } else {
                    conn.send(content: payload, completion: .contentProcessed { _ in })
                }
            }
        } else if isSyn && !isAck {
            if tcpSessions.count >= maxTCP {
                tcpLock.unlock()
                return
            }
            let ipStr = "\(dstIP >> 24).\(dstIP >> 16 & 0xFF).\(dstIP >> 8 & 0xFF).\(dstIP & 0xFF)"
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ipStr), port: NWEndpoint.Port(integerLiteral: UInt16(dstPort)))
            let conn = NWConnection(to: endpoint, using: .tcp)
            let session = TCPSession(conn: conn, srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, synSeq: seq, synAck: ack)
            tcpSessions[key] = session
            tcpLock.unlock()

            conn.stateUpdateHandler = { [weak self, weak session] state: NWConnection.State in
                guard let self = self, let session = session, self.isRunning else { return }
                switch state {
                case .ready:
                    self.writeTCPResponse(srcIP: dstIP, srcPort: dstPort, dstIP: srcIP, dstPort: srcPort, seq: session.localSeq, ack: session.localAck, flags: 0x12, payload: Data())
                    session.localSeq += 1
                    session.state = .synAckSent
                case .failed, .cancelled:
                    self.tcpLock.lock()
                    self.tcpSessions.removeValue(forKey: key)
                    self.tcpLock.unlock()
                default: break
                }
            }

            // Receive handler
            startTCPReceive(conn: conn, session: session, key: key)
            conn.start(queue: self.queue)
        } else {
            tcpLock.unlock()
        }
    }

    private func startTCPReceive(conn: NWConnection, session: TCPSession, key: String) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self = self, self.isRunning else { return }
            guard session.state == .established || session.state == .synAckSent else { return }
            session.lastActivity = Date().timeIntervalSince1970

            if let data = data, !data.isEmpty {
                if self.isLagEnabled {
                    if Int.random(in: 0..<100) < 15 {
                        // Drop
                    } else {
                        self.queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                            guard let self = self, session.state == .established else { return }
                            self.writeTCPResponse(srcIP: session.dstIP, srcPort: session.dstPort, dstIP: session.srcIP, dstPort: session.srcPort, seq: session.localSeq, ack: session.localAck, flags: 0x18, payload: data)
                            session.localSeq += UInt32(data.count)
                        }
                    }
                } else {
                    self.writeTCPResponse(srcIP: session.dstIP, srcPort: session.dstPort, dstIP: session.srcIP, dstPort: session.srcPort, seq: session.localSeq, ack: session.localAck, flags: 0x18, payload: data)
                    session.localSeq += UInt32(data.count)
                }
            }

            if isComplete || error != nil {
                if session.state != .closed {
                    self.writeTCPResponse(srcIP: session.dstIP, srcPort: session.dstPort, dstIP: session.srcIP, dstPort: session.srcPort, seq: session.localSeq, ack: session.localAck, flags: 0x11, payload: Data())
                    session.state = .closed
                    conn.cancel()
                    self.tcpLock.lock()
                    self.tcpSessions.removeValue(forKey: key)
                    self.tcpLock.unlock()
                }
                return
            }
            self.startTCPReceive(conn: conn, session: session, key: key)
        }
    }

    func writeTCPResponse(srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, seq: UInt32, ack: UInt32, flags: UInt8, payload: Data) {
        guard isRunning else { return }
        var tcp = Data(count: 20)
        tcp[0] = UInt8(srcPort >> 8); tcp[1] = UInt8(srcPort & 0xFF)
        tcp[2] = UInt8(dstPort >> 8); tcp[3] = UInt8(dstPort & 0xFF)
        tcp[4] = UInt8(seq >> 24); tcp[5] = UInt8(seq >> 16); tcp[6] = UInt8(seq >> 8); tcp[7] = UInt8(seq)
        tcp[8] = UInt8(ack >> 24); tcp[9] = UInt8(ack >> 16); tcp[10] = UInt8(ack >> 8); tcp[11] = UInt8(ack)
        tcp[12] = 0x50; tcp[13] = flags; tcp[14] = 0xFF; tcp[15] = 0xFF
        tcp[16] = 0; tcp[17] = 0; tcp[18] = 0; tcp[19] = 0
        if !payload.isEmpty { tcp.append(payload) }
        let cksum = tcpChecksum(srcIP: srcIP, dstIP: dstIP, proto: 6, tcpPacket: tcp)
        tcp[16] = UInt8(cksum >> 8); tcp[17] = UInt8(cksum & 0xFF)
        let ipPacket = buildIPv4Packet(srcIP: srcIP, dstIP: dstIP, protocol: 6, payload: tcp)
        let _ = packetFlow.writePackets([ipPacket], withProtocols: [NSNumber(value: AF_INET)])
    }

    // MARK: - IP Builder

    private func buildIPv4Packet(srcIP: UInt32, dstIP: UInt32, protocol: UInt8, payload: Data) -> Data {
        var packet = Data(count: 20 + payload.count)
        packet[0] = 0x45
        let totalLen = 20 + payload.count
        packet[2] = UInt8(totalLen >> 8); packet[3] = UInt8(totalLen & 0xFF)
        packet[4] = 0; packet[5] = 0; packet[6] = 0x40; packet[7] = 0
        packet[8] = 64; packet[9] = `protocol`
        packet[12] = UInt8(srcIP >> 24); packet[13] = UInt8(srcIP >> 16); packet[14] = UInt8(srcIP >> 8); packet[15] = UInt8(srcIP)
        packet[16] = UInt8(dstIP >> 24); packet[17] = UInt8(dstIP >> 16); packet[18] = UInt8(dstIP >> 8); packet[19] = UInt8(dstIP)
        var sum: UInt32 = 0
        var i = 0
        while i < 20 - 1 {
            sum += (UInt32(packet[i]) << 8) | UInt32(packet[i + 1])
            i += 2
        }
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        let cksum = ~UInt16(sum & 0xFFFF)
        packet[10] = UInt8(cksum >> 8); packet[11] = UInt8(cksum & 0xFF)
        packet.replaceSubrange(20..<packet.count, with: payload)
        return packet
    }

    private func tcpChecksum(srcIP: UInt32, dstIP: UInt32, proto: UInt8, tcpPacket: Data) -> UInt16 {
        var pseudo = Data(count: 12)
        pseudo[0] = UInt8(srcIP >> 24); pseudo[1] = UInt8(srcIP >> 16)
        pseudo[2] = UInt8(srcIP >> 8);  pseudo[3] = UInt8(srcIP)
        pseudo[4] = UInt8(dstIP >> 24); pseudo[5] = UInt8(dstIP >> 16)
        pseudo[6] = UInt8(dstIP >> 8);  pseudo[7] = UInt8(dstIP)
        pseudo[8] = 0; pseudo[9] = proto
        pseudo[10] = UInt8(tcpPacket.count >> 8); pseudo[11] = UInt8(tcpPacket.count & 0xFF)
        var sum: UInt32 = 0
        var i = 0
        while i < pseudo.count - 1 {
            sum += (UInt32(pseudo[i]) << 8) | UInt32(pseudo[i + 1])
            i += 2
        }
        i = 0
        while i < tcpPacket.count - 1 {
            sum += (UInt32(tcpPacket[i]) << 8) | UInt32(tcpPacket[i + 1])
            i += 2
        }
        if tcpPacket.count % 2 == 1 {
            sum += UInt32(tcpPacket[tcpPacket.count - 1]) << 8
        }
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum & 0xFFFF)
    }
}

// MARK: - UDP Session
fileprivate struct UDPSession {
    let conn: NWConnection
    let srcIP: UInt32, srcPort: UInt16
    let dstIP: UInt32, dstPort: UInt16
    var lastActivity: TimeInterval
    init(conn: NWConnection, srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16) {
        self.conn = conn
        self.srcIP = srcIP; self.srcPort = srcPort
        self.dstIP = dstIP; self.dstPort = dstPort
        self.lastActivity = Date().timeIntervalSince1970
    }
}

// MARK: - TCP Session
fileprivate class TCPSession {
    let conn: NWConnection
    let srcIP: UInt32, dstIP: UInt32
    let srcPort: UInt16, dstPort: UInt16
    var localSeq: UInt32
    var localAck: UInt32
    var state: TCPState
    var lastActivity: TimeInterval

    enum TCPState { case synReceived, synAckSent, established, closed }

    init(conn: NWConnection, srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, synSeq: UInt32, synAck: UInt32) {
        self.conn = conn
        self.srcIP = srcIP; self.srcPort = srcPort
        self.dstIP = dstIP; self.dstPort = dstPort
        self.localSeq = UInt32.random(in: 1000..<50000)
        self.localAck = synSeq + 1
        self.state = .synReceived
        self.lastActivity = Date().timeIntervalSince1970
    }
}
