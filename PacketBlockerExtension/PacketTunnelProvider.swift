import NetworkExtension
import Network
import Foundation

// ============================================================================
// MARK: - Local Proxy Server (chạy trong extension process)
// ============================================================================
// Server này xử lý TẤT CẢ logic: UDPv4, UDPv6, TCPv4, ICMPv4
// PacketTunnelProvider chỉ forward packets đến/đi từ server này
// ============================================================================

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

// MARK: LocalProxyServer
class LocalProxyServer {

    var isLagEnabled = false
    let queue: DispatchQueue

    // UDPv4
    private var udpV4Sessions: [String: UDPSessionV4] = [:]
    private let udpV4Lock = NSLock()
    private let maxUDPV4 = 100

    // UDPv6
    private var udpV6Sessions: [String: UDPSessionV6] = [:]
    private let udpV6Lock = NSLock()
    private let maxUDPV6 = 100

    // TCPv4
    fileprivate var tcpSessions: [String: TCPSession] = [:]
    fileprivate let tcpLock = NSLock()
    private let maxTCP = 50

    // Callback để gửi packets response về PacketTunnelProvider
    var onWritePackets: (([Data], [NSNumber]) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func stop() {
        udpV4Lock.lock()
        for (_, s) in udpV4Sessions { s.connection.cancel() }
        udpV4Sessions.removeAll()
        udpV4Lock.unlock()

        udpV6Lock.lock()
        for (_, s) in udpV6Sessions { s.connection.cancel() }
        udpV6Sessions.removeAll()
        udpV6Lock.unlock()

        tcpLock.lock()
        for (_, s) in tcpSessions { s.connection.cancel() }
        tcpSessions.removeAll()
        tcpLock.unlock()
    }

    func cleanup() {
        let now = Date().timeIntervalSince1970

        udpV4Lock.lock()
        var v4remove: [String] = []
        for (k, s) in udpV4Sessions { if now - s.lastActivity > 60.0 { s.connection.cancel(); v4remove.append(k) } }
        for k in v4remove { udpV4Sessions.removeValue(forKey: k) }
        let v4count = udpV4Sessions.count
        udpV4Lock.unlock()

        udpV6Lock.lock()
        var v6remove: [String] = []
        for (k, s) in udpV6Sessions { if now - s.lastActivity > 60.0 { s.connection.cancel(); v6remove.append(k) } }
        for k in v6remove { udpV6Sessions.removeValue(forKey: k) }
        let v6count = udpV6Sessions.count
        udpV6Lock.unlock()

        tcpLock.lock()
        var tcpRemove: [String] = []
        for (k, s) in tcpSessions { if now - s.lastActivity > 300.0 { s.connection.cancel(); tcpRemove.append(k) } }
        for k in tcpRemove { tcpSessions.removeValue(forKey: k) }
        let tcpCount = tcpSessions.count
        tcpLock.unlock()

        if !v4remove.isEmpty || !v6remove.isEmpty || !tcpRemove.isEmpty {
            NSLog("[ProxyServer] Cleanup: UDPv4=\(v4count) UDPv6=\(v6count) TCP=\(tcpCount)")
        }
    }

    // MARK: Process Packet
    func processPacket(_ packet: Data, proto: Int32) {
        do {
            if proto == AF_INET {
                try processIPv4(packet)
            } else if proto == AF_INET6 {
                try processIPv6(packet)
            }
        } catch {
            NSLog("[ProxyServer] processPacket error: \(error)")
        }
    }

    // MARK: IPv4
    private func processIPv4(_ packet: Data) throws {
        guard packet.count >= 20 else { return }
        guard (packet[0] >> 4) & 0x0F == 4 else { return }
        let ihl = Int(packet[0] & 0x0F) * 4
        guard packet.count >= ihl else { return }

        let srcIP = (UInt32(packet[12]) << 24) | (UInt32(packet[13]) << 16) | (UInt32(packet[14]) << 8) | UInt32(packet[15])
        let dstIP = (UInt32(packet[16]) << 24) | (UInt32(packet[17]) << 16) | (UInt32(packet[18]) << 8) | UInt32(packet[19])
        let ipProto = packet[9]
        let srcStr = "\(srcIP >> 24).\(srcIP >> 16 & 0xFF).\(srcIP >> 8 & 0xFF).\(srcIP & 0xFF)"
        let dstStr = "\(dstIP >> 24).\(dstIP >> 16 & 0xFF).\(dstIP >> 8 & 0xFF).\(dstIP & 0xFF)"

        switch ipProto {
        case 1:
            try handleICMPv4(packet: packet, srcIP: srcIP, dstIP: dstIP, ihl: ihl)
        case 6:
            try handleTCPv4(packet: packet, srcIP: srcIP, dstIP: dstIP, ihl: ihl, srcStr: srcStr, dstStr: dstStr)
        case 17:
            try handleUDPv4(packet: packet, srcIP: srcIP, dstIP: dstIP, ihl: ihl, srcStr: srcStr, dstStr: dstStr)
        default:
            break
        }
    }

    // MARK: IPv6
    private func processIPv6(_ packet: Data) throws {
        guard packet.count >= 40 else { return }
        guard (packet[0] >> 4) & 0x0F == 6 else { return }
        let nextHeader = packet[6]
        let payloadLen = Int((UInt16(packet[4]) << 8) | UInt16(packet[5]))
        guard packet.count >= 40 + payloadLen else { return }

        let srcIP = packet.subdata(in: 8..<24)
        let dstIP = packet.subdata(in: 24..<40)

        switch nextHeader {
        case 17:
            try handleUDPv6(packet: packet, srcIP: srcIP, dstIP: dstIP)
        case 58:
            break // ICMPv6 - có thể thêm sau
        default:
            break
        }
    }

    // MARK: ICMPv4
    private func handleICMPv4(packet: Data, srcIP: UInt32, dstIP: UInt32, ihl: Int) throws {
        guard packet.count >= ihl + 8 else { return }
        guard packet[ihl] == 8 else { return }
        var reply = Data(count: packet.count - ihl)
        reply[0] = 0; reply[1] = 0; reply[2] = 0; reply[3] = 0
        reply[4] = packet[ihl + 4]; reply[5] = packet[ihl + 5]
        reply[6] = packet[ihl + 6]; reply[7] = packet[ihl + 7]
        if packet.count > ihl + 8 {
            reply.replaceSubrange(8..<reply.count, with: packet.subdata(in: (ihl + 8)..<packet.count))
        }
        let cksum = ipChecksum(reply)
        reply[2] = UInt8(cksum >> 8); reply[3] = UInt8(cksum & 0xFF)
        let ipPacket = buildIPv4Packet(srcIP: dstIP, dstIP: srcIP, protocol: 1, payload: reply)
        onWritePackets?([ipPacket], [NSNumber(value: AF_INET)])
    }

    // MARK: UDPv4
    private func handleUDPv4(packet: Data, srcIP: UInt32, dstIP: UInt32, ihl: Int, srcStr: String, dstStr: String) throws {
        guard packet.count >= ihl + 8 else { return }
        let srcPort = (UInt16(packet[ihl]) << 8) | UInt16(packet[ihl + 1])
        let dstPort = (UInt16(packet[ihl + 2]) << 8) | UInt16(packet[ihl + 3])
        let udpLen = Int((UInt16(packet[ihl + 4]) << 8) | UInt16(packet[ihl + 5]))
        let payloadStart = ihl + 8
        let payloadEnd = min(payloadStart + udpLen - 8, packet.count)
        guard payloadEnd > payloadStart else { return }
        let payload = packet.subdata(in: payloadStart..<payloadEnd)

        let key = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"
        NSLog("[ProxyServer] UDPv4 \(srcStr):\(srcPort) -> \(dstStr):\(dstPort) len=\(payload.count)")

        udpV4Lock.lock()
        if let session = udpV4Sessions[key] {
            session.lastActivity = Date().timeIntervalSince1970
            udpV4Lock.unlock()
            forwardUDPv4(session: session, payload: payload)
        } else {
            if udpV4Sessions.count >= maxUDPV4 {
                if let oldest = udpV4Sessions.min(by: { $0.value.lastActivity < $1.value.lastActivity })?.key {
                    udpV4Sessions[oldest]?.connection.cancel()
                    udpV4Sessions.removeValue(forKey: oldest)
                }
            }
            let session = UDPSessionV4(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, server: self)
            udpV4Sessions[key] = session
            udpV4Lock.unlock()
            forwardUDPv4(session: session, payload: payload)
        }
    }

    private func forwardUDPv4(session: UDPSessionV4, payload: Data) {
        if isLagEnabled {
            if Int.random(in: 0..<100) < 15 { return }
            queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak session] in
                session?.send(payload)
            }
        } else {
            session.send(payload)
        }
    }

    func writeUDPv4Response(srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, payload: Data) {
        if isLagEnabled {
            if Int.random(in: 0..<100) < 15 { return }
            queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                self?.buildAndWriteUDPv4(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, payload: payload)
            }
        } else {
            buildAndWriteUDPv4(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, payload: payload)
        }
    }

    private func buildAndWriteUDPv4(srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, payload: Data) {
        var udp = Data(count: 8)
        udp[0] = UInt8(srcPort >> 8); udp[1] = UInt8(srcPort & 0xFF)
        udp[2] = UInt8(dstPort >> 8); udp[3] = UInt8(dstPort & 0xFF)
        let ulen = 8 + payload.count
        udp[4] = UInt8(ulen >> 8); udp[5] = UInt8(ulen & 0xFF)
        udp[6] = 0; udp[7] = 0
        var full = Data(); full.append(udp); full.append(payload)
        let ipPacket = buildIPv4Packet(srcIP: srcIP, dstIP: dstIP, protocol: 17, payload: full)
        onWritePackets?([ipPacket], [NSNumber(value: AF_INET)])
    }

    // MARK: UDPv6
    private func handleUDPv6(packet: Data, srcIP: Data, dstIP: Data) throws {
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
        NSLog("[ProxyServer] UDPv6 [\(srcHex)]:\(srcPort) -> [\(dstHex)]:\(dstPort) len=\(payload.count)")

        udpV6Lock.lock()
        if let session = udpV6Sessions[key] {
            session.lastActivity = Date().timeIntervalSince1970
            udpV6Lock.unlock()
            forwardUDPv6(session: session, payload: payload)
        } else {
            if udpV6Sessions.count >= maxUDPV6 {
                if let oldest = udpV6Sessions.min(by: { $0.value.lastActivity < $1.value.lastActivity })?.key {
                    udpV6Sessions[oldest]?.connection.cancel()
                    udpV6Sessions.removeValue(forKey: oldest)
                }
            }
            let session = UDPSessionV6(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, server: self)
            udpV6Sessions[key] = session
            udpV6Lock.unlock()
            forwardUDPv6(session: session, payload: payload)
        }
    }

    private func forwardUDPv6(session: UDPSessionV6, payload: Data) {
        if isLagEnabled {
            if Int.random(in: 0..<100) < 15 { return }
            queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak session] in
                session?.send(payload)
            }
        } else {
            session.send(payload)
        }
    }

    func writeUDPv6Response(srcIP: Data, srcPort: UInt16, dstIP: Data, dstPort: UInt16, payload: Data) {
        if isLagEnabled {
            if Int.random(in: 0..<100) < 15 { return }
            queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                self?.buildAndWriteUDPv6(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, payload: payload)
            }
        } else {
            buildAndWriteUDPv6(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, payload: payload)
        }
    }

    private func buildAndWriteUDPv6(srcIP: Data, srcPort: UInt16, dstIP: Data, dstPort: UInt16, payload: Data) {
        var udp = Data(count: 8)
        udp[0] = UInt8(srcPort >> 8); udp[1] = UInt8(srcPort & 0xFF)
        udp[2] = UInt8(dstPort >> 8); udp[3] = UInt8(dstPort & 0xFF)
        let ulen = 8 + payload.count
        udp[4] = UInt8(ulen >> 8); udp[5] = UInt8(ulen & 0xFF)
        udp[6] = 0; udp[7] = 0

        var ip6 = Data(count: 40)
        ip6[0] = 0x60
        ip6[1] = 0; ip6[2] = 0; ip6[3] = 0
        let plen = 8 + payload.count
        ip6[4] = UInt8(plen >> 8); ip6[5] = UInt8(plen & 0xFF)
        ip6[6] = 17
        ip6[7] = 64
        ip6.replaceSubrange(8..<24, with: srcIP)
        ip6.replaceSubrange(24..<40, with: dstIP)

        var full = Data()
        full.append(ip6)
        full.append(udp)
        full.append(payload)

        onWritePackets?([full], [NSNumber(value: AF_INET6)])
    }

    // MARK: TCPv4
    private func handleTCPv4(packet: Data, srcIP: UInt32, dstIP: UInt32, ihl: Int, srcStr: String, dstStr: String) throws {
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

        NSLog("[ProxyServer] TCPv4 \(srcStr):\(srcPort) -> \(dstStr):\(dstPort) flags=0x\(String(flags, radix: 16)) payload=\(payload.count)")

        tcpLock.lock()
        if let session = tcpSessions[key] {
            session.lastActivity = Date().timeIntervalSince1970
            tcpLock.unlock()
            if isRst || isFin {
                session.close()
                return
            }
            if isSyn && isAck { return }
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
            if tcpSessions.count >= maxTCP {
                tcpLock.unlock()
                return
            }
            let session = TCPSession(srcIP: srcIP, dstIP: dstIP, srcPort: srcPort, dstPort: dstPort, synSeq: seq, server: self)
            tcpSessions[key] = session
            tcpLock.unlock()
        } else {
            tcpLock.unlock()
        }
    }

    func writeTCPResponse(srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, seq: UInt32, ack: UInt32, flags: UInt8, payload: Data) {
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
        onWritePackets?([ipPacket], [NSNumber(value: AF_INET)])
    }

    // MARK: IPv4 Builder
    private func buildIPv4Packet(srcIP: UInt32, dstIP: UInt32, protocol: UInt8, payload: Data) -> Data {
        var packet = Data(count: 20 + payload.count)
        packet[0] = 0x45
        let totalLen = 20 + payload.count
        packet[2] = UInt8(totalLen >> 8); packet[3] = UInt8(totalLen & 0xFF)
        packet[4] = 0; packet[5] = 0; packet[6] = 0x40; packet[7] = 0
        packet[8] = 64; packet[9] = `protocol`
        packet[12] = UInt8(srcIP >> 24); packet[13] = UInt8(srcIP >> 16); packet[14] = UInt8(srcIP >> 8); packet[15] = UInt8(srcIP)
        packet[16] = UInt8(dstIP >> 24); packet[17] = UInt8(dstIP >> 16); packet[18] = UInt8(dstIP >> 8); packet[19] = UInt8(dstIP)
        let cksum = ipChecksum(packet[0..<20])
        packet[10] = UInt8(cksum >> 8); packet[11] = UInt8(cksum & 0xFF)
        packet.replaceSubrange(20..<packet.count, with: payload)
        return packet
    }
}

// MARK: - UDPv4 Session
fileprivate class UDPSessionV4 {
    let connection: NWConnection
    let srcIP: UInt32, srcPort: UInt16
    let dstIP: UInt32, dstPort: UInt16
    weak var server: LocalProxyServer?
    var lastActivity: TimeInterval

    init(srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16, server: LocalProxyServer) {
        self.srcIP = srcIP; self.srcPort = srcPort
        self.dstIP = dstIP; self.dstPort = dstPort
        self.server = server
        self.lastActivity = Date().timeIntervalSince1970

        let ipStr = "\(dstIP >> 24).\(dstIP >> 16 & 0xFF).\(dstIP >> 8 & 0xFF).\(dstIP & 0xFF)"
        let host = NWEndpoint.Host(ipStr)
        let port = NWEndpoint.Port(integerLiteral: UInt16(dstPort))
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
        connection = NWConnection(to: endpoint, using: .udp)
        connection.start(queue: server.queue)
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
                self.server?.writeUDPv4Response(srcIP: self.dstIP, srcPort: self.dstPort, dstIP: self.srcIP, dstPort: self.srcPort, payload: data)
            }
            if error == nil { self.receive() }
        }
    }
}

// MARK: - UDPv6 Session
fileprivate class UDPSessionV6 {
    let connection: NWConnection
    let srcIP: Data, dstIP: Data
    let srcPort: UInt16, dstPort: UInt16
    weak var server: LocalProxyServer?
    var lastActivity: TimeInterval

    init(srcIP: Data, srcPort: UInt16, dstIP: Data, dstPort: UInt16, server: LocalProxyServer) {
        self.srcIP = srcIP; self.srcPort = srcPort
        self.dstIP = dstIP; self.dstPort = dstPort
        self.server = server
        self.lastActivity = Date().timeIntervalSince1970

        // Convert 16-byte IPv6 to string format
        let ipStr = Self.ipv6ToString(dstIP)
        let host = NWEndpoint.Host(ipStr)
        let port = NWEndpoint.Port(integerLiteral: UInt16(dstPort))
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
        connection = NWConnection(to: endpoint, using: .udp)
        connection.start(queue: server.queue)
        receive()
    }

    private static func ipv6ToString(_ data: Data) -> String {
        guard data.count == 16 else { return "::" }
        var groups: [String] = []
        for i in stride(from: 0, to: 16, by: 2) {
            let val = (UInt16(data[i]) << 8) | UInt16(data[i + 1])
            groups.append(String(format: "%04x", val))
        }
        // Find longest run of zeros to compress
        var bestStart = -1
        var bestLen = 0
        var currStart = -1
        var currLen = 0
        for (i, g) in groups.enumerated() {
            if g == "0000" {
                if currStart == -1 { currStart = i }
                currLen += 1
                if currLen > bestLen {
                    bestLen = currLen
                    bestStart = currStart
                }
            } else {
                currStart = -1
                currLen = 0
            }
        }
        if bestLen >= 2 {
            let prefix = groups[0..<bestStart].map { $0 }.joined(separator: ":")
            let suffix = groups[(bestStart + bestLen)..<16].map { $0 }.joined(separator: ":")
            if prefix.isEmpty && suffix.isEmpty {
                return "::"
            } else if prefix.isEmpty {
                return "::" + suffix
            } else if suffix.isEmpty {
                return prefix + "::"
            } else {
                return prefix + "::" + suffix
            }
        }
        return groups.joined(separator: ":")
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
                self.server?.writeUDPv6Response(srcIP: self.dstIP, srcPort: self.dstPort, dstIP: self.srcIP, dstPort: self.srcPort, payload: data)
            }
            if error == nil { self.receive() }
        }
    }
}

// MARK: - TCP Session
fileprivate class TCPSession {
    let connection: NWConnection
    let srcIP: UInt32, dstIP: UInt32
    let srcPort: UInt16, dstPort: UInt16
    weak var server: LocalProxyServer?
    var localSeq: UInt32
    var localAck: UInt32
    var state: TCPState = .synReceived
    var lastActivity: TimeInterval

    enum TCPState { case synReceived, synAckSent, established, closed }

    init(srcIP: UInt32, dstIP: UInt32, srcPort: UInt16, dstPort: UInt16, synSeq: UInt32, server: LocalProxyServer) {
        self.srcIP = srcIP; self.dstIP = dstIP
        self.srcPort = srcPort; self.dstPort = dstPort
        self.server = server
        self.localSeq = UInt32.random(in: 1000..<50000)
        self.localAck = synSeq + 1
        self.lastActivity = Date().timeIntervalSince1970

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
                NSLog("[ProxyServer] TCP failed: \(err)")
                self.close()
            case .cancelled:
                self.close()
            default: break
            }
        }

        connection.start(queue: server.queue)
        receiveRemote()
    }

    func sendData(_ data: Data) {
        lastActivity = Date().timeIntervalSince1970
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        guard state != .closed else { return }
        state = .closed
        connection.cancel()
        let key = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"
        server?.tcpLock.lock()
        server?.tcpSessions.removeValue(forKey: key)
        server?.tcpLock.unlock()
    }

    private func sendSynAck() {
        guard state == .synReceived else { return }
        server?.writeTCPResponse(srcIP: dstIP, srcPort: dstPort, dstIP: srcIP, dstPort: srcPort, seq: localSeq, ack: localAck, flags: 0x12, payload: Data())
        localSeq += 1
        state = .synAckSent
    }

    private func receiveRemote() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            guard self.state == .established || self.state == .synAckSent else { return }
            self.lastActivity = Date().timeIntervalSince1970

            if let data = data, !data.isEmpty {
                if self.server?.isLagEnabled == true {
                    if Int.random(in: 0..<100) < 15 {
                        // Drop
                    } else {
                        self.server?.queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                            guard let self = self, self.state == .established else { return }
                            self.server?.writeTCPResponse(srcIP: self.dstIP, srcPort: self.dstPort, dstIP: self.srcIP, dstPort: self.srcPort, seq: self.localSeq, ack: self.localAck, flags: 0x18, payload: data)
                            self.localSeq += UInt32(data.count)
                        }
                    }
                } else {
                    self.server?.writeTCPResponse(srcIP: self.dstIP, srcPort: self.dstPort, dstIP: self.srcIP, dstPort: self.srcPort, seq: self.localSeq, ack: self.localAck, flags: 0x18, payload: data)
                    self.localSeq += UInt32(data.count)
                }
            }

            if isComplete || error != nil {
                if self.state != .closed {
                    self.server?.writeTCPResponse(srcIP: self.dstIP, srcPort: self.dstPort, dstIP: self.srcIP, dstPort: self.srcPort, seq: self.localSeq, ack: self.localAck, flags: 0x11, payload: Data())
                    self.close()
                }
                return
            }
            self.receiveRemote()
        }
    }
}


// ============================================================================
// MARK: - PacketTunnelProvider (chỉ forward packets, KHÔNG xử lý logic)
// ============================================================================
// Extension này chỉ làm 3 việc:
// 1. Setup VPN tunnel (route all traffic)
// 2. Read packets từ iOS → forward đến LocalProxyServer
// 3. Nhận responses từ LocalProxyServer → write lại iOS
// ============================================================================

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var lastConfigTimestamp: TimeInterval = 0
    private let queue = DispatchQueue(label: "com.fakelag", qos: .userInitiated)
    private var isRunning = false
    private var configTimer: DispatchSourceTimer?
    private var cleanupTimer: DispatchSourceTimer?
    private var isReading = false

    // Local Proxy Server chạy trong cùng extension process
    private lazy var proxyServer: LocalProxyServer = {
        let server = LocalProxyServer(queue: queue)
        server.onWritePackets = { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { return }
            self.packetFlow.writePackets(packets, withProtocols: protocols)
        }
        return server
    }()

    private var configURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.ban.PacketBlocker"
        ) else { return nil }
        return container.appendingPathComponent("fakelag_config.plist")
    }

    // MARK: - Lifecycle

    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[FakeLag] ===== startTunnel called =====")
        isRunning = false
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
            guard let self = self else {
                completionHandler(nil)
                return
            }
            if let error = error {
                NSLog("[FakeLag] startTunnel FAILED: \(error)")
                completionHandler(error)
                return
            }
            self.isRunning = true
            NSLog("[FakeLag] ===== Tunnel UP. ProxyServer started. Lag=OFF =====")
            self.startConfigWatcher()
            self.startCleanupWatcher()
            self.startReadLoop()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[FakeLag] ===== stopTunnel called. Reason: \(reason.rawValue) =====")
        isRunning = false
        configTimer?.cancel(); configTimer = nil
        cleanupTimer?.cancel(); cleanupTimer = nil
        proxyServer.stop()
        isReading = false
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
        if enabled != proxyServer.isLagEnabled {
            proxyServer.isLagEnabled = enabled
            NSLog("[FakeLag] ===== Config changed: lag=\(enabled) =====")
        }
    }

    // MARK: - Cleanup Watcher

    private func startCleanupWatcher() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30.0, repeating: 30.0)
        timer.setEventHandler { [weak self] in self?.proxyServer.cleanup() }
        timer.resume()
        cleanupTimer = timer
    }

    // MARK: - Read Loop (chỉ forward đến server)

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
                self.proxyServer.processPacket(packets[i], proto: protocols[i].int32Value)
            }
            self.readLoop()
        }
    }
}
