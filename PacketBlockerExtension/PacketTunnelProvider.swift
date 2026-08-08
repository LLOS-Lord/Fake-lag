import NetworkExtension
import Network
import Foundation

// MARK: - IP Checksum Helpers
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

fileprivate func tcpChecksum(srcIP: UInt32, dstIP: UInt32, proto: UInt8, tcpPacket: Data) -> UInt16 {
    var pseudo = Data(count: 12)
    pseudo[0] = UInt8(srcIP >> 24)
    pseudo[1] = UInt8(srcIP >> 16)
    pseudo[2] = UInt8(srcIP >> 8)
    pseudo[3] = UInt8(srcIP)
    pseudo[4] = UInt8(dstIP >> 24)
    pseudo[5] = UInt8(dstIP >> 16)
    pseudo[6] = UInt8(dstIP >> 8)
    pseudo[7] = UInt8(dstIP)
    pseudo[8] = 0
    pseudo[9] = proto
    pseudo[10] = UInt8(tcpPacket.count >> 8)
    pseudo[11] = UInt8(tcpPacket.count & 0xFF)

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

// MARK: - PacketTunnelProvider
class PacketTunnelProvider: NEPacketTunnelProvider {

    // MARK: Config & State
    fileprivate var isLagEnabled = false
    private var lastConfigTimestamp: TimeInterval = 0
    let queue = DispatchQueue(label: "com.fakelag", qos: .userInitiated)
    private var isRunning = false
    private var watchTimer: Timer?
    private var isReading = false

    // UDP sessions: key = "srcIP:srcPort-dstIP:dstPort"
    fileprivate var udpSessions: [String: UDPSession] = [:]
    fileprivate let udpLock = NSLock()

    // TCP sessions
    fileprivate var tcpSessions: [String: TCPSession] = [:]
    fileprivate let tcpLock = NSLock()

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

        applySettings(lagEnabled: false) { [weak self] error in
            if let error = error {
                NSLog("[FakeLag] startTunnel FAILED: \(error)")
                completionHandler(error)
                return
            }
            self?.isRunning = true
            NSLog("[FakeLag] ===== Tunnel UP. Lag=OFF =====")
            self?.startConfigWatcher()
            self?.startReadLoop()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[FakeLag] ===== stopTunnel called. Reason: \(reason.rawValue) =====")
        isRunning = false
        isLagEnabled = false
        isReading = false
        watchTimer?.invalidate()
        watchTimer = nil
        udpLock.lock()
        udpSessions.removeAll()
        udpLock.unlock()
        tcpLock.lock()
        tcpSessions.removeAll()
        tcpLock.unlock()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(Data("ok".utf8))
    }

    // MARK: - Config Watcher

    private func startConfigWatcher() {
        guard isRunning else { return }
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkConfig()
        }
    }

    private func checkConfig() {
        guard let url = configURL else {
            startConfigWatcher()
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            startConfigWatcher()
            return
        }
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            startConfigWatcher()
            return
        }

        let enabled = dict["enabled"] as? Bool ?? false
        let timestamp = dict["timestamp"] as? TimeInterval ?? 0

        guard timestamp > lastConfigTimestamp else {
            startConfigWatcher()
            return
        }
        lastConfigTimestamp = timestamp

        if enabled != isLagEnabled {
            isLagEnabled = enabled
            NSLog("[FakeLag] ===== Config changed: lag=\(isLagEnabled) (ts=\(timestamp)) =====")
            applySettings(lagEnabled: isLagEnabled) { error in
                if let error = error {
                    NSLog("[FakeLag] applySettings error: \(error)")
                }
            }
        }
        startConfigWatcher()
    }

    // MARK: - Settings

    private func applySettings(lagEnabled: Bool, completion: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1500

        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        if lagEnabled {
            ipv4.includedRoutes = [NEIPv4Route.default()]
            NSLog("[FakeLag] Routes: ALL traffic -> tunnel (LAG ON)")
        } else {
            ipv4.includedRoutes = []
            NSLog("[FakeLag] Routes: NO traffic -> tunnel (LAG OFF)")
        }
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
        if lagEnabled {
            ipv6.includedRoutes = [NEIPv6Route.default()]
        } else {
            ipv6.includedRoutes = []
        }
        settings.ipv6Settings = ipv6

        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                NSLog("[FakeLag] setTunnelNetworkSettings FAILED: \(error)")
                completion(error)
                return
            }
            NSLog("[FakeLag] setTunnelNetworkSettings OK")
            completion(nil)
        }
    }

    // MARK: - Read Loop

    private func startReadLoop() {
        guard isRunning, !isReading else {
            NSLog("[FakeLag] startReadLoop skipped: running=\(isRunning), reading=\(isReading)")
            return
        }
        isReading = true
        readLoop()
    }

    private func readLoop() {
        guard isRunning else {
            isReading = false
            NSLog("[FakeLag] readLoop stopped (not running)")
            return
        }

        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            guard self.isRunning else {
                self.isReading = false
                return
            }

            for i in 0..<packets.count {
                let packet = packets[i]
                let proto = protocols[i].int32Value
                self.handlePacket(packet, proto: proto)
            }

            self.readLoop()
        }
    }

    // MARK: - Packet Handler

    private func handlePacket(_ packet: Data, proto: Int32) {
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
            handleICMP(packet: packet, srcIP: srcIP, dstIP: dstIP, ihl: ihl)
        case 6:
            handleTCP(packet: packet, srcIP: srcIP, dstIP: dstIP, ihl: ihl)
        case 17:
            handleUDP(packet: packet, srcIP: srcIP, dstIP: dstIP, ihl: ihl)
        default:
            break
        }
    }

    // MARK: - ICMP Echo Reply

    private func handleICMP(packet: Data, srcIP: UInt32, dstIP: UInt32, ihl: Int) {
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

        let ipPacket = buildIPv4Packet(srcIP: dstIP, dstIP: srcIP, protocol: 1, payload: reply)
        packetFlow.writePackets([ipPacket], withProtocols: [NSNumber(value: AF_INET)])
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

        let key = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"

        udpLock.lock()
        if let session = udpSessions[key] {
            udpLock.unlock()
            forwardUDP(session: session, payload: payload)
        } else {
            let session = UDPSession(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, provider: self)
            udpSessions[key] = session
            udpLock.unlock()
            forwardUDP(session: session, payload: payload)
        }
    }

    private func forwardUDP(session: UDPSession, payload: Data) {
        if isLagEnabled {
            if Int.random(in: 0..<100) < 15 {
                return
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak session] in
                session?.send(payload)
            }
        } else {
            session.send(payload)
        }
    }

    func writeUDPResponse(srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, payload: Data) {
        if isLagEnabled {
            if Int.random(in: 0..<100) < 15 {
                return
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                self?.buildAndWriteUDP(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, payload: payload)
            }
        } else {
            buildAndWriteUDP(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, payload: payload)
        }
    }

    private func buildAndWriteUDP(srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, payload: Data) {
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
        packetFlow.writePackets([ipPacket], withProtocols: [NSNumber(value: AF_INET)])
    }

    // MARK: - TCP Proxy

    private func handleTCP(packet: Data, srcIP: UInt32, dstIP: UInt32, ihl: Int) {
        guard packet.count >= ihl + 20 else { return }
        let srcPort = (UInt16(packet[ihl]) << 8) | UInt16(packet[ihl + 1])
        let dstPort = (UInt16(packet[ihl + 2]) << 8) | UInt16(packet[ihl + 3])
        let seq = (UInt32(packet[ihl + 4]) << 24) | (UInt32(packet[ihl + 5]) << 16) | (UInt32(packet[ihl + 6]) << 8) | UInt32(packet[ihl + 7])
        let _ = (UInt32(packet[ihl + 8]) << 24) | (UInt32(packet[ihl + 9]) << 16) | (UInt32(packet[ihl + 10]) << 8) | UInt32(packet[ihl + 11])
        let dataOffset = Int((packet[ihl + 12] >> 4) & 0x0F) * 4
        let flags = packet[ihl + 13]
        let payloadStart = ihl + dataOffset
        let payload = payloadStart < packet.count ? packet.subdata(in: payloadStart..<packet.count) : Data()

        let key = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"
        let isSyn = (flags & 0x02) != 0
        let isAck = (flags & 0x10) != 0
        let isFin = (flags & 0x01) != 0
        let isRst = (flags & 0x04) != 0

        tcpLock.lock()
        if let session = tcpSessions[key] {
            tcpLock.unlock()
            if isRst || isFin {
                session.close()
                tcpLock.lock()
                tcpSessions.removeValue(forKey: key)
                tcpLock.unlock()
                return
            }
            if isSyn && isAck {
                return
            }
            if isAck && session.state == .synAckSent {
                session.state = .established
            }
            if !payload.isEmpty && session.state == .established {
                if isLagEnabled {
                    if Int.random(in: 0..<100) < 15 { return }
                    queue.asyncAfter(deadline: .now() + .milliseconds(300)) {
                        session.sendData(payload)
                    }
                } else {
                    session.sendData(payload)
                }
            }
        } else if isSyn && !isAck {
            let session = TCPSession(srcIP: srcIP, dstIP: dstIP, srcPort: srcPort, dstPort: dstPort, synSeq: seq, provider: self)
            tcpSessions[key] = session
            tcpLock.unlock()
        } else {
            tcpLock.unlock()
        }
    }

    func writeTCPResponse(srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, seq: UInt32, ack: UInt32, flags: UInt8, payload: Data) {
        var tcp = Data(count: 20)
        tcp[0] = UInt8(srcPort >> 8)
        tcp[1] = UInt8(srcPort & 0xFF)
        tcp[2] = UInt8(dstPort >> 8)
        tcp[3] = UInt8(dstPort & 0xFF)
        tcp[4] = UInt8(seq >> 24)
        tcp[5] = UInt8(seq >> 16)
        tcp[6] = UInt8(seq >> 8)
        tcp[7] = UInt8(seq)
        tcp[8] = UInt8(ack >> 24)
        tcp[9] = UInt8(ack >> 16)
        tcp[10] = UInt8(ack >> 8)
        tcp[11] = UInt8(ack)
        tcp[12] = 0x50
        tcp[13] = flags
        tcp[14] = 0xFF
        tcp[15] = 0xFF
        tcp[16] = 0
        tcp[17] = 0
        tcp[18] = 0
        tcp[19] = 0

        if !payload.isEmpty {
            tcp.append(payload)
        }

        let cksum = tcpChecksum(srcIP: srcIP, dstIP: dstIP, proto: 6, tcpPacket: tcp)
        tcp[16] = UInt8(cksum >> 8)
        tcp[17] = UInt8(cksum & 0xFF)

        let ipPacket = buildIPv4Packet(srcIP: srcIP, dstIP: dstIP, protocol: 6, payload: tcp)
        packetFlow.writePackets([ipPacket], withProtocols: [NSNumber(value: AF_INET)])
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

    init(srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, provider: PacketTunnelProvider) {
        self.srcIP = srcIP; self.srcPort = srcPort
        self.dstIP = dstIP; self.dstPort = dstPort
        self.provider = provider

        let ipStr = "\(dstIP >> 24).\(dstIP >> 16 & 0xFF).\(dstIP >> 8 & 0xFF).\(dstIP & 0xFF)"
        let host = NWEndpoint.Host(ipStr)
        let port = NWEndpoint.Port(integerLiteral: UInt16(dstPort))
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
        connection = NWConnection(to: endpoint, using: .udp)
        connection.start(queue: provider.queue)
        receive()
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.provider?.writeUDPResponse(srcIP: self.dstIP, srcPort: self.dstPort, dstIP: self.srcIP, dstPort: self.srcPort, payload: data)
            }
            if error == nil {
                self.receive()
            }
        }
    }
}

// MARK: - TCP Session
fileprivate class TCPSession {
    let connection: NWConnection
    let srcIP: UInt32, dstIP: UInt32
    let srcPort: UInt16, dstPort: UInt16
    weak var provider: PacketTunnelProvider?

    var localSeq: UInt32
    var localAck: UInt32
    var remoteSeq: UInt32
    var state: TCPState = .synReceived

    enum TCPState {
        case synReceived, synAckSent, established, closing, closed
    }

    init(srcIP: UInt32, dstIP: UInt32, srcPort: UInt16, dstPort: UInt16, synSeq: UInt32, provider: PacketTunnelProvider) {
        self.srcIP = srcIP; self.dstIP = dstIP
        self.srcPort = srcPort; self.dstPort = dstPort
        self.provider = provider
        self.remoteSeq = synSeq
        self.localSeq = UInt32.random(in: 1000..<UInt32.max / 2)
        self.localAck = synSeq + 1

        let ipStr = "\(dstIP >> 24).\(dstIP >> 16 & 0xFF).\(dstIP >> 8 & 0xFF).\(dstIP & 0xFF)"
        let host = NWEndpoint.Host(ipStr)
        let port = NWEndpoint.Port(integerLiteral: UInt16(dstPort))
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
        connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.sendSynAck()
            case .failed(let err):
                NSLog("[FakeLag] TCP conn failed: \(err)")
                self.close()
            case .cancelled:
                self.close()
            default:
                break
            }
        }

        connection.start(queue: provider.queue)
        receiveRemote()
    }

    func sendData(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        state = .closed
        connection.cancel()
        let key = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"
        provider?.tcpLock.lock()
        provider?.tcpSessions.removeValue(forKey: key)
        provider?.tcpLock.unlock()
    }

    private func sendSynAck() {
        guard state == .synReceived else { return }
        provider?.writeTCPResponse(srcIP: dstIP, srcPort: dstPort, dstIP: srcIP, dstPort: srcPort, seq: localSeq, ack: localAck, flags: 0x12, payload: Data())
        localSeq += 1
        state = .synAckSent
    }

    private func receiveRemote() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            guard self.state == .established || self.state == .synAckSent else { return }

            if let data = data, !data.isEmpty {
                if self.provider?.isLagEnabled == true {
                    if Int.random(in: 0..<100) < 15 {
                        // Drop inbound
                    } else {
                        self.provider?.queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                            guard let self = self, self.state == .established else { return }
                            self.provider?.writeTCPResponse(srcIP: self.dstIP, srcPort: self.dstPort, dstIP: self.srcIP, dstPort: self.srcPort, seq: self.localSeq, ack: self.localAck, flags: 0x18, payload: data)
                            self.localSeq += UInt32(data.count)
                        }
                    }
                } else {
                    self.provider?.writeTCPResponse(srcIP: self.dstIP, srcPort: self.dstPort, dstIP: self.srcIP, dstPort: self.srcPort, seq: self.localSeq, ack: self.localAck, flags: 0x18, payload: data)
                    self.localSeq += UInt32(data.count)
                }
            }

            if isComplete || error != nil {
                if self.state != .closed {
                    self.provider?.writeTCPResponse(srcIP: self.dstIP, srcPort: self.dstPort, dstIP: self.srcIP, dstPort: self.srcPort, seq: self.localSeq, ack: self.localAck, flags: 0x11, payload: Data())
                    self.close()
                }
                return
            }
            self.receiveRemote()
        }
    }
}
