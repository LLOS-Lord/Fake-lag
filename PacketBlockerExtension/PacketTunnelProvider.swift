import NetworkExtension
import Foundation
import Network

// =============================================================================
//  PacketTunnelProvider — FIXED FLOW (bug #3)
//
//  OLD (broken) flow: read packet from TUN → (optionally hold/drop) → write it
//  back into the SAME packetFlow. Nothing was ever forwarded to the real
//  network, so the moment the VPN came up ALL TCP/UDP died — even with the
//  fake-lag simulation OFF ("bật VPN cũng bị chặn tầng TCP/UDP").
//
//  NEW (fixed) flow:
//    TUN read (outbound IP packet from apps)
//      → UDP : full userspace NAT relay via NWConnection (provider's own
//              traffic is routed OUTSIDE its tunnel by iOS) ; replies are
//              rebuilt as IP/UDP packets (ports+IPs swapped, checksums fixed)
//              and written back to the TUN so the app receives them.
//      → TCP : minimal userspace SYN-proxy: answer the handshake locally,
//              open a REAL TCP connection to the destination, splice bytes
//              both ways with seq/ack rewriting + retransmit buffer.
//      → ICMP: echo requests answered locally so "ping" still works.
//    Fake-lag (hold/drop/delay) is applied ONLY to packets that match the
//    configured rules AND only while enabled=true. With VPN ON + FakeLag OFF
//    every packet is relayed untouched.
//
//  Routing fix: the tunnel now advertises IPv4 default route ONLY (IPv6
//  packets used to be looped back / held, breaking the stack even harder).
// =============================================================================

private let kFIN: UInt8 = 0x01, kSYN: UInt8 = 0x02, kRST: UInt8 = 0x04, kPSH: UInt8 = 0x08, kACK: UInt8 = 0x10
private let kTCP: UInt8 = 6, kUDP: UInt8 = 17, kICMP: UInt8 = 1
private let kMTU = 1280
private let kMSS: UInt16 = UInt16(kMTU - 40)        // 1240
private let kMaxHeld = 512
private let kMaxDelayed = 1024

// Same JSON schema as the app's HybridConfig (PacketBlocker/AppGroup.swift).
struct HybridConfig: Codable {
    var enabled: Bool = false
    var mode: String = "hold"
    var direction: String = "both"
    var protoFilter: String = "both"
    var captureRatio: Int = 100
    var downloadRatio: Int = 100
    var uploadRatio: Int = 100
    var latencyMs: Int = 350
    var jitterMs: Int = 80
    var bandwidthKbps: Int = 0
    var duplicatePercent: Int = 0
    var autoFlushSeconds: Int = 12
    var dropUDPPercent: Int = 15
    var dropTCPPercent: Int = 5
    var targetBundleID: String = ""
    var targetPID: Int32 = 0
    var targetProcessName: String = ""
    var targetSockets: [SocketEntry] = []
    var floatingSize: Float = 58
    var floatingOpacity: Float = 0.94
    var floatingEdgeSnap: Bool = true
    var floatingLockPosition: Bool = false
    var floatingHaptic: Bool = true
    var floatingPosX: Float = 310
    var floatingPosY: Float = 220
    var timestamp: TimeInterval = 0
    var preset: String = "custom"
}

struct SocketEntry: Codable {
    var localPort: UInt16
    var remotePort: UInt16
    var remoteIP: String
    var proto: String
}

// ── Flow table keys ──────────────────────────────────────────────────────────
struct FlowKey: Hashable {
    var proto: UInt8
    var src: [UInt8]   // 4 bytes IPv4
    var sport: UInt16
    var dst: [UInt8]   // 4 bytes IPv4
    var dport: UInt16

    func hash(into hasher: inout Hasher) {
        hasher.combine(proto); hasher.combine(sport); hasher.combine(dport)
        hasher.combine(src); hasher.combine(dst)
    }
    static func == (a: FlowKey, b: FlowKey) -> Bool {
        a.proto == b.proto && a.sport == b.sport && a.dport == b.dport && a.src == b.src && a.dst == b.dst
    }
    var srcString: String { "\(src[0]).\(src[1]).\(src[2]).\(src[3])" }
    var dstString: String { "\(dst[0]).\(dst[1]).\(dst[2]).\(dst[3])" }
    var describe: String { "\(srcString):\(sport) → \(dstString):\(dport) \(proto == kTCP ? "tcp" : "udp")" }
}

// ── UDP NAT flow ─────────────────────────────────────────────────────────────
final class UDPFlow {
    let key: FlowKey
    var conn: NWConnection?
    var ready = false
    var pending: [[UInt8]] = []
    var lastSeen: UInt64
    init(key: FlowKey, now: UInt64) { self.key = key; self.lastSeen = now }
}

// ── TCP SYN-proxy flow ───────────────────────────────────────────────────────
final class TCPFlow {
    enum Phase: String { case synReceived, established, closed }
    var phase: Phase = .synReceived
    var clientIsn: UInt32 = 0
    var clientNext: UInt32 = 0          // next client seq we expect
    var serverIsn: UInt32 = 0           // our ISN shown to the client
    var serverNext: UInt32 = 0          // our next seq to send to client
    var conn: NWConnection?
    var connReady = false
    var pendingToServer: [Data] = []    // client payloads buffered before conn ready
    var clientFin = false
    var clientFinSent = false
    var serverFin = false
    var unacked: [(seq: UInt32, len: Int, seg: [UInt8], time: UInt64)] = []
    var dupAcks = 0
    var lastAck: UInt32 = 0
    var receivePaused = false
    var lastSeen: UInt64
    init(now: UInt64) { self.lastSeen = now }
}

// =============================================================================
class PacketTunnelProvider: NEPacketTunnelProvider {
    private var isRunning = false
    private var config = HybridConfig()
    private var lastConfigTS: TimeInterval = -1

    private let readQueue = DispatchQueue(label: "com.hybrid.read", qos: .userInitiated)
    private let engineQueue = DispatchQueue(label: "com.hybrid.engine", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "com.hybrid.write", qos: .userInitiated)
    private let configQueue = DispatchQueue(label: "com.hybrid.config", qos: .utility)

    private var configTimer: DispatchSourceTimer?
    private var delayTimer: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?
    private var maintenanceTimer: DispatchSourceTimer?

    private var udpFlows: [FlowKey: UDPFlow] = [:]
    private var tcpFlows: [FlowKey: TCPFlow] = [:]

    // (packet, proto, outbound) — hold mode / delay mode both store raw packets.
    private struct StoredPacket { var pkt: [UInt8]; var proto: Int32; var outbound: Bool; var dueMs: UInt64 }
    private var heldQueue: [StoredPacket] = []
    private var delayedQueue: [StoredPacket] = []
    private let queuesLock = NSLock()

    private var passed: UInt64 = 0
    private var dropped: UInt64 = 0
    private var relayedIn: UInt64 = 0
    private var relayedOut: UInt64 = 0
    private var flowCounter: UInt64 = 0
    private var startedAt = Date()

    private var groupURL: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ban.PacketBlocker") }
    private var configURL: URL? { groupURL?.appendingPathComponent("hybrid_config.json") }
    private var legacyURL: URL? { groupURL?.appendingPathComponent("fakelag_config.plist") }
    private var logURL: URL? { groupURL?.appendingPathComponent("hybrid_actions.log") }
    private var overrideURL: URL? { groupURL?.appendingPathComponent("hybrid_ext_override.json") }
    private let cachesConfig = "/var/mobile/Library/Caches/hybrid_config.json"
    private let cachesOverride = "/var/mobile/Library/Caches/hybrid_ext_override.json"

    // ═══════════════════════════════ lifecycle ═══════════════════════════════

    override func startTunnel(options: [String: NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[Hybrid] startTunnel FIXED-FLOW (relay engine) starting")
        isRunning = true
        loadConfig()

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        settings.mtu = NSNumber(value: kMTU)
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        // NOTE: no IPv6 routes on purpose — the relay engine is IPv4-only;
        // advertising IPv6 here would loop IPv6 packets back into the TUN
        // (part of the original "VPN blocks everything" bug).
        let dns = NEDNSSettings(servers: ["8.8.8.8", "1.1.1.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        setTunnelNetworkSettings(settings) { [weak self] err in
            guard let self = self else { completionHandler(nil); return }
            if let err = err {
                self.log("TUN_FAIL", "setTunnelNetworkSettings error: \(err)")
                completionHandler(err)
                return
            }
            self.startConfigWatcher()
            self.startDelayFlusher()
            self.startStatsTimer()
            self.startMaintenanceTimer()
            self.readQueue.async { self.readLoop() }
            self.log("TUN_START", "relay engine up — mtu=\(kMTU) ipv4-default-route enabled=\(self.config.enabled) mode=\(self.config.mode) target=\(self.config.targetBundleID.isEmpty ? "GLOBAL" : self.config.targetBundleID)")
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[Hybrid] stop reason %d passed=%llu dropped=%llu", reason.rawValue, passed, dropped)
        isRunning = false
        configTimer?.cancel(); configTimer = nil
        delayTimer?.cancel(); delayTimer = nil
        statsTimer?.cancel(); statsTimer = nil
        maintenanceTimer?.cancel(); maintenanceTimer = nil
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            self.flushHeld(bypassGates: true)
            self.flushDelayedNow()
            for f in self.udpFlows.values { f.conn?.cancel() }
            for f in self.tcpFlows.values { f.conn?.cancel() }
            self.udpFlows.removeAll()
            self.tcpFlows.removeAll()
        }
        log("TUN_STOP", "reason=\(reason.rawValue)")
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let msg = String(data: messageData, encoding: .utf8) ?? ""
        NSLog("[Hybrid] appMessage %@", msg)

        // NEPacketTunnelProvider calls this on the extension's main thread, while
        // the packet path runs on engineQueue. Answering from here — even just
        // loadConfig()/statsString() — reads config, tcpFlows and udpFlows
        // concurrently with the engine, which is how clientTCPSegment kept
        // trapping. Hand EVERYTHING to engineQueue and reply from there.
        engineQueue.async { [weak self] in
            guard let self = self else {
                completionHandler?(Data("ok".utf8))
                return
            }
            var reply = "ok"
            switch msg {
            case "enable", "disable":
                // FIXED: the old code mutated a local copy and threw it away.
                // Persist an override so loadSync() picks the new state instantly.
                let wantEnable = (msg == "enable")
                self.writeOverride(enabled: wantEnable)
                if !wantEnable {
                    self.flushHeld(bypassGates: true)
                    self.flushDelayedNow()
                }
                self.log(wantEnable ? "MSG_ENABLE" : "MSG_DISABLE",
                         "override written enabled=\(wantEnable)")
                reply = wantEnable ? "ok enabled" : "ok disabled"
            case "getstats":
                reply = self.statsString()
            default:
                self.loadConfigNow()
                reply = "ok"
            }
            completionHandler?(Data(reply.utf8))
        }
    }

    // ═══════════════════════════ config & logging ════════════════════════════

    private func startConfigWatcher() {
        let t = DispatchSource.makeTimerSource(queue: configQueue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.8)
        t.setEventHandler { [weak self] in self?.loadConfig() }
        t.resume(); configTimer = t
    }

    private func loadConfig() {
        // Parse on configQueue, APPLY on engineQueue. `config` is a struct
        // holding reference-counted fields (mode/direction/protoFilter/
        // targetBundleID/targetSockets): assigning it releases the old String
        // buffers. The packet path reads `config` on engineQueue, so applying
        // it from configQueue raced — a torn reference surfaces as a Swift
        // runtime trap (EXC_BREAKPOINT) inside whatever function happened to be
        // running, e.g. clientTCPSegment. Everything that touches config,
        // tcpFlows or udpFlows now runs on engineQueue, and only there.
        let cfg = loadSync()
        guard cfg.timestamp > lastConfigTS else { return }
        engineQueue.async { [weak self] in
            guard let self = self, cfg.timestamp > self.lastConfigTS else { return }
            self.applyConfig(cfg)
        }
    }

    /// engineQueue only — mutates `config` and flushes held/delayed queues.
    private func applyConfig(_ cfg: HybridConfig) {
        let wasEnabled = config.enabled
        let previousMode = config.mode
        lastConfigTS = cfg.timestamp
        config = cfg
        NSLog("[Hybrid] cfg enabled=%d mode=%@ target=%@ sockets=%d ratio=%d latency=%dms",
              cfg.enabled ? 1 : 0, cfg.mode, cfg.targetBundleID, cfg.targetSockets.count, cfg.captureRatio, cfg.latencyMs)
            log("CONFIG", "enabled=\(cfg.enabled) mode=\(cfg.mode) dir=\(cfg.direction) proto=\(cfg.protoFilter) ratio=\(cfg.captureRatio)% dl=\(cfg.downloadRatio)% ul=\(cfg.uploadRatio)% latency=\(cfg.latencyMs)ms jitter=\(cfg.jitterMs)ms autoFlush=\(cfg.autoFlushSeconds)s target=\(cfg.targetBundleID.isEmpty ? "GLOBAL" : "\(cfg.targetBundleID)/pid=\(cfg.targetPID) sockets=\(cfg.targetSockets.count)")")
        // F8: release everything stuck in the queues when the simulation
        // turns OFF or the mode no longer matches the queued packets.
        if !cfg.enabled && wasEnabled {
            flushHeld(bypassGates: true)
            flushDelayedNow()
        } else if cfg.enabled && previousMode == "delay" && cfg.mode != "delay" {
            flushDelayedNow()
        }
    }

    /// Apply a fresh config on the CURRENT queue. Only valid on engineQueue —
    /// the async sibling exists precisely so other queues cannot do this.
    private func loadConfigNow() {
        let cfg = loadSync()
        guard cfg.timestamp > lastConfigTS else { return }
        applyConfig(cfg)
    }

    private func loadSync() -> HybridConfig {
        var cfg = HybridConfig()
        var loaded = false
        if let url = configURL, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(HybridConfig.self, from: data) {
            cfg = decoded; loaded = true
        } else if let data = try? Data(contentsOf: URL(fileURLWithPath: cachesConfig)),
                  let decoded = try? JSONDecoder().decode(HybridConfig.self, from: data) {
            // FIXED: the app writes this Caches copy when the App Group container
            // is unavailable to the extension — the old code never read it.
            cfg = decoded; loaded = true
        } else if let lurl = legacyURL, let dict = NSDictionary(contentsOf: lurl) as? [String: Any] {
            cfg.enabled = dict["enabled"] as? Bool ?? false
            cfg.timestamp = dict["timestamp"] as? TimeInterval ?? 0
            loaded = true
        }
        // Provider-message override (enable/disable) wins when newer.
        // Read from the App Group container first, then the Caches fallback
        // (the root HUD daemon writes the Caches copy when it toggles).
        var overrideTS: TimeInterval = -1
        var overrideEnabled: Bool?
        for oPath in [overrideURL?.path, cachesOverride].compactMap({ $0 }) {
            if let oData = FileManager.default.contents(atPath: oPath),
               let dict = try? JSONSerialization.jsonObject(with: oData) as? [String: Any],
               let ts = dict["timestamp"] as? TimeInterval, ts > overrideTS,
               let en = dict["enabled"] as? Bool {
                overrideTS = ts
                overrideEnabled = en
            }
        }
        if let en = overrideEnabled, overrideTS > cfg.timestamp {
            cfg.enabled = en
            cfg.timestamp = overrideTS
        }
        // Stay at defaults ONLY when nothing at all was loaded (no config file
        // AND no override) — resetting the timestamp after applying an override
        // would make the next poll ignore that override entirely (0 > ts fails).
        if !loaded && overrideEnabled == nil { cfg.timestamp = 0 }
        return cfg
    }

    /// engineQueue only — assigns `config` and `lastConfigTS`.
    private func writeOverride(enabled: Bool) {
        let ts = Date().timeIntervalSince1970
        let dict: [String: Any] = ["enabled": enabled, "timestamp": ts]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        if let url = overrideURL {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
        }
        // Mirror into Caches so the root HUD daemon + app fallback can see it.
        let caches = URL(fileURLWithPath: cachesOverride)
        try? data.write(to: caches, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: caches.path)
        config.enabled = enabled
        config.timestamp = ts
        lastConfigTS = ts
    }

    private func log(_ action: String, _ details: String) {
        let line = "[\(Date())] [EXT] [\(action)] \(details) | passed=\(passed) dropped=\(dropped) held=\(heldCount()) delayed=\(delayedCount())\n"
        if let url = logURL {
            if FileManager.default.fileExists(atPath: url.path),
               let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
            }
        }
        // Mirror into Caches so LogsView works even without the App Group.
        let fallback = "/var/mobile/Library/Caches/hybrid_actions.log"
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: fallback)) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(toFile: fallback, atomically: true, encoding: .utf8)
        }
    }

    private func heldCount() -> Int { queuesLock.lock(); defer { queuesLock.unlock() }; return heldQueue.count }
    private func delayedCount() -> Int { queuesLock.lock(); defer { queuesLock.unlock() }; return delayedQueue.count }

    private func statsString() -> String {
        let udp = udpFlows.count, tcp = tcpFlows.count
        return "uptime=\(Int(Date().timeIntervalSince(startedAt)))s passed=\(passed) dropped=\(dropped) relayedIn=\(relayedIn) relayedOut=\(relayedOut) held=\(heldCount()) delayed=\(delayedCount()) udpFlows=\(udp) tcpFlows=\(tcp) enabled=\(config.enabled) mode=\(config.mode)"
    }

    // ═══════════════════════════════ read loop ═══════════════════════════════

    private func readLoop() {
        guard isRunning else { return }
        packetFlow.readPackets { [weak self] packets, protos in
            guard let self = self else { return }
            let protoArr = protos.map { $0.int32Value }
            let pkts = packets
            self.engineQueue.async {
                guard self.isRunning else { return }
                for i in 0..<pkts.count {
                    self.handleOutbound([UInt8](pkts[i]), proto: protoArr[i], bypassGates: false)
                }
            }
            self.readQueue.async { self.readLoop() }   // keep the pipe drained
        }
    }

    // ═══════════════════════════ outbound path ═══════════════════════════════

    private func handleOutbound(_ pkt: [UInt8], proto: Int32, bypassGates: Bool) {
        guard isRunning else { return }

        guard proto == AF_INET else {
            // IPv6 (or exotic) — no routes are advertised for it, so this is
            // unexpected. NEVER write it back (the old code looped it).
            dropped &+= 1
            return
        }
        guard pkt.count >= 20, (pkt[0] >> 4) == 4 else { dropped &+= 1; return }

        let ihl = Int(pkt[0] & 0x0F) * 4
        guard pkt.count > ihl else { dropped &+= 1; return }
        let ipProto = pkt[9]
        let src: [UInt8] = [pkt[12], pkt[13], pkt[14], pkt[15]]
        let dst: [UInt8] = [pkt[16], pkt[17], pkt[18], pkt[19]]

        // ICMP: answer pings locally so basic connectivity checks still work.
        if ipProto == kICMP {
            handleICMP(pkt, ihl: ihl, src: src, dst: dst)
            return
        }
        guard ipProto == kTCP || ipProto == kUDP else { dropped &+= 1; return } // GRE etc. — cannot relay

        guard pkt.count >= ihl + 4 else { dropped &+= 1; return }
        let sport = (UInt16(pkt[ihl]) << 8) | UInt16(pkt[ihl + 1])
        let dport = (UInt16(pkt[ihl + 2]) << 8) | UInt16(pkt[ihl + 3])

        let key = FlowKey(proto: ipProto, src: src, sport: sport, dst: dst, dport: dport)

        // ── Fake-lag gates (only when simulation is ON) ──
        if !bypassGates && config.enabled && lagMatches(key: key, isUpload: true) {
            switch config.mode {
            case "hold":
                enqueueHeld(StoredPacket(pkt: pkt, proto: proto, outbound: true, dueMs: nowMs()))
                return
            case "drop":
                // Never drop TCP SYN/RST — killing handshakes breaks reconnects.
                let isSyn = ipProto == kTCP && pkt.count > ihl + 13 && (pkt[ihl + 13] & kSYN) != 0
                if !isSyn {
                    // TCP upload: neither forward nor ACK → the client's TCP
                    // retransmits later (real loss semantics). UDP: silent loss.
                    dropped &+= 1
                    return
                }
            case "delay":
                // Delay the UDP datagram itself. For TCP upload, delaying the
                // raw packet risks double-forwarding if the client's RTO fires
                // mid-delay (min RTO is 1s, delay can be up to 1.5s) — TCP
                // upload is therefore relayed immediately; the DOWNLOAD side
                // carries the delay (that is what players feel most).
                if key.proto == kUDP {
                    let due = nowMs() &+ UInt64(config.latencyMs + Int.random(in: 0...max(0, config.jitterMs)))
                    enqueueDelayed(StoredPacket(pkt: pkt, proto: proto, outbound: true, dueMs: due))
                    return
                }
            default:
                break
            }
        }

        relayOutbound(key: key, pkt: pkt, ihl: ihl)
    }

    private func relayOutbound(key: FlowKey, pkt: [UInt8], ihl: Int) {
        let l4HeaderLen = key.proto == kTCP ? tcpHeaderLen(pkt, ihl: ihl) : 8
        let start = ihl + l4HeaderLen
        guard start <= pkt.count else { dropped &+= 1; return }
        let payload = Array(pkt[start...])
        if key.proto == kUDP {
            udpSend(key: key, payload: payload)
            passed &+= 1
            relayedOut &+= 1
        } else {
            clientTCPSegment(key: key, pkt: pkt, ihl: ihl)
        }
    }

    // ── UDP NAT ──────────────────────────────────────────────────────────────

    private func udpSend(key: FlowKey, payload: [UInt8]) {
        let now = nowMs()
        var flow = udpFlows[key]
        if flow == nil {
            flow = UDPFlow(key: key, now: now)
            udpFlows[key] = flow
            sampleLog("UDP_NEW", "\(key.describe) — NAT flow opened (table=\(udpFlows.count))")
            openUDPConn(for: flow!)
        }
        flow!.lastSeen = now
        guard let conn = flow!.conn, flow!.ready else {
            if flow!.pending.count < 64 { flow!.pending.append(payload) }
            return
        }
        sendUDP(key: key, conn: conn, payload: payload)
    }

    /// Relay sockets must leave through the physical interface, never through
    /// the tunnel we just brought up.
    ///
    /// The old code did `prohibitedInterfaceTypes = [.other]`, which is wrong in
    /// BOTH directions: on iOS the utun interface backing a PacketTunnel is not
    /// classified `.other` in every configuration, and prohibiting a whole class
    /// rather than the specific interface leaves NWConnection with nowhere to
    /// bind. That is exactly what the device reported —
    /// `POSIXErrorCode(rawValue: 50): Network is down` on the FIRST connection,
    /// immediately after TCP_EST, under any packet load.
    ///
    /// ponytail: the airtight way to pin the egress interface is to resolve the
    /// route's interface (NWPathMonitor → NWInterface.name) and set
    /// `requiredInterface`. Do that when the relay ever needs to survive a
    /// second VPN (double-VPN users), which is the only case this leaves open.
    private static func makeRelayParams(_ base: NWParameters) -> NWParameters {
        base.includePeerToPeer = false
        return base
    }

    private func openUDPConn(for flow: UDPFlow) {
        let key = flow.key
        guard let port = NWEndpoint.Port(rawValue: key.dport) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(key.dstString), port: port,
                                using: PacketTunnelProvider.makeRelayParams(.udp))
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self, self.isRunning else { return }
            switch state {
            case .ready:
                flow.ready = true
                let buffered = flow.pending
                flow.pending.removeAll()
                for payload in buffered { self.sendUDP(key: key, conn: conn, payload: payload) }
                self.udpReceive(key: key, conn: conn)
            case .failed(let error):
                self.log("UDP_FAIL", "\(key.describe) \(error)")
                self.udpFlows[key] = nil
            case .cancelled:
                self.udpFlows[key] = nil
            default:
                break
            }
        }
        flow.conn = conn
        conn.start(queue: engineQueue)
    }

    private func sendUDP(key: FlowKey, conn: NWConnection, payload: [UInt8]) {
        conn.send(content: Data(payload), completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.sampleLog("UDP_SEND_ERR", "\(key.describe) \(error)")
            }
        })
    }

    private func udpReceive(key: FlowKey, conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self = self, self.isRunning else { return }
            if let data = data, !data.isEmpty {
                let payload = [UInt8](data)
                // Build the reply the app expects: src = original destination.
                let seg = IP.buildUDP(src: key.dst, sport: key.dport, dst: key.src, dport: key.sport, payload: payload)
                let reply = IP.buildIPv4(proto: kUDP, src: key.dst, dst: key.src, l4: seg)

                // F6: gates apply to the DOWNLOAD direction for UDP as well
                // (direction=download + udp used to be a silent no-op).
                var gated = false
                if config.enabled && lagMatches(key: key, isUpload: false) {
                    switch config.mode {
                    case "hold":
                        enqueueHeld(StoredPacket(pkt: reply, proto: AF_INET, outbound: false, dueMs: nowMs()))
                        gated = true
                    case "drop":
                        dropped &+= 1   // silent reply loss
                        gated = true
                    case "delay":
                        let due = nowMs() &+ UInt64(config.latencyMs + Int.random(in: 0...max(0, config.jitterMs)))
                        enqueueDelayed(StoredPacket(pkt: reply, proto: AF_INET, outbound: false, dueMs: due))
                        gated = true
                    default:
                        break
                    }
                }
                if !gated {
                    deliverInbound(reply)
                }
                passed &+= 1
                relayedIn &+= 1
            }
            if error == nil {
                self.udpReceive(key: key, conn: conn)
            } else {
                self.udpFlows[key] = nil
            }
        }
    }

    // ── TCP SYN-proxy ────────────────────────────────────────────────────────

    private func tcpHeaderLen(_ pkt: [UInt8], ihl: Int) -> Int {
        guard pkt.count > ihl + 12 else { return 20 }
        return Int(pkt[ihl + 12] >> 4) * 4
    }

    private func clientTCPSegment(key: FlowKey, pkt: [UInt8], ihl: Int) {
        let th = ihl
        guard pkt.count >= th + 20 else { return }
        let seq = IP.rU32(pkt, th + 4)
        let ack = IP.rU32(pkt, th + 8)
        let flags = pkt[th + 13]
        let dataOff = Int(pkt[th + 12] >> 4) * 4
        let payloadStart = th + dataOff
        let payload = payloadStart <= pkt.count ? Array(pkt[payloadStart...]) : []

        var flow = tcpFlows[key]
        let now = nowMs()
        if flow == nil {
            flow = TCPFlow(now: now)
            tcpFlows[key] = flow
        }
        flow!.lastSeen = now

        // ── Handshake step 1: client SYN ──
        if (flags & kSYN) != 0 && (flags & kACK) == 0 {
            flow!.clientIsn = seq
            flow!.clientNext = seq &+ 1
            flow!.serverIsn = UInt32.random(in: 1...UInt32.max)
            flow!.serverNext = flow!.serverIsn &+ 1
            flow!.phase = .synReceived
            flow!.unacked.removeAll()
            flow!.dupAcks = 0
            sampleLog("TCP_NEW", "\(key.describe) SYN — opening real connection (table=\(tcpFlows.count))")
            let synAck = IP.tcpSegment(src: key.dst, sport: key.dport, dst: key.src, dport: key.sport,
                                       seq: flow!.serverIsn, ack: flow!.clientNext,
                                       flags: kSYN | kACK, window: 65535, payload: [], mss: kMSS)
            deliverInboundDirect(IP.buildIPv4(proto: kTCP, src: key.dst, dst: key.src, l4: synAck))
            openTCPConn(for: flow!, key: key)
            passed &+= 1
            return
        }

        // ── RST: teardown ──
        if (flags & kRST) != 0 {
            sampleLog("TCP_RST", "\(key.describe) client reset — tearing down")
            flow!.conn?.cancel()
            tcpFlows[key] = nil
            return
        }

        // ── Handshake step 2: final ACK of our SYN-ACK ──
        if flow!.phase == .synReceived {
            if (flags & kACK) != 0 && ack == flow!.serverIsn &+ 1 {
                flow!.phase = .established
                flow!.clientNext = seq
                sampleLog("TCP_EST", "\(key.describe) established (proxy)")
            }
            // fallthrough: payload piggybacked on the handshake ACK is handled below
        }

        guard flow!.phase == .established else { return }

        // ── ACK processing: trim retransmit buffer, detect dup-acks ──
        if (flags & kACK) != 0 {
            // F4: wraparound-safe trim. The old test
            // `UInt32(ack &- entry.seq) >= UInt32(entry.len)` UNDERFLOWED whenever
            // the cumulative ack was below an entry's seq — the wrapped difference
            // is huge, so the FIRST partial ack wiped the whole retransmit buffer.
            flow!.unacked.removeAll { !IP.seqBefore(ack, $0.seq &+ UInt32($0.len)) }
            if payload.isEmpty && ack == flow!.lastAck {
                flow!.dupAcks += 1
                if flow!.dupAcks >= 3 { retransmit(flow!, key: key) }
            } else if !payload.isEmpty || ack != flow!.lastAck {
                flow!.dupAcks = 0
            }
            flow!.lastAck = ack
        }

        // ── Payload (client → server) ──
        if !payload.isEmpty {
            if seq == flow!.clientNext {
                flow!.clientNext = seq &+ UInt32(payload.count)
                forwardToServer(flow!, key: key, payload: payload)
                if (flags & kFIN) != 0 {
                    flow!.clientNext &+= 1
                    flow!.clientFin = true
                    finishClientSide(flow!, key: key)
                }
                let ackSeg = IP.buildIPv4(proto: kTCP, src: key.dst, dst: key.src,
                                          l4: IP.tcpSegment(src: key.dst, sport: key.dport, dst: key.src, dport: key.sport,
                                                            seq: flow!.serverNext, ack: flow!.clientNext,
                                                            flags: kACK, window: 64240, payload: [], mss: nil))
                // F7: in delay mode the upload is felt by delaying the synthetic
                // ACK (cumulative ACK at flush time is still correct even if the
                // client kept sending). Payload itself is already forwarded.
                var ackDelayed = false
                if config.enabled && config.mode == "delay" && lagMatches(key: key, isUpload: true) {
                    let due = nowMs() &+ UInt64(config.latencyMs + Int.random(in: 0...max(0, config.jitterMs)))
                    enqueueDelayed(StoredPacket(pkt: ackSeg, proto: AF_INET, outbound: false, dueMs: due))
                    ackDelayed = true
                }
                if !ackDelayed { deliverInboundDirect(ackSeg) }
            } else {
                // Retransmission (seq < clientNext) or gap (we lost a segment):
                // re-ACK so the client retransmits the missing bytes — never
                // re-forward old data.
                let ackSeg = IP.tcpSegment(src: key.dst, sport: key.dport, dst: key.src, dport: key.sport,
                                           seq: flow!.serverNext, ack: flow!.clientNext,
                                           flags: kACK, window: 64240, payload: [], mss: nil)
                deliverInboundDirect(IP.buildIPv4(proto: kTCP, src: key.dst, dst: key.src, l4: ackSeg))
            }
            passed &+= 1
            relayedOut &+= 1
            return
        }

        // ── Bare FIN (no payload) ──
        if (flags & kFIN) != 0 && seq == flow!.clientNext {
            flow!.clientNext &+= 1
            flow!.clientFin = true
            finishClientSide(flow!, key: key)
            let ackSeg = IP.tcpSegment(src: key.dst, sport: key.dport, dst: key.src, dport: key.sport,
                                       seq: flow!.serverNext, ack: flow!.clientNext,
                                       flags: kACK, window: 64240, payload: [], mss: nil)
            deliverInboundDirect(IP.buildIPv4(proto: kTCP, src: key.dst, dst: key.src, l4: ackSeg))
        }
    }

    private func openTCPConn(for flow: TCPFlow, key: FlowKey) {
        guard let port = NWEndpoint.Port(rawValue: key.dport) else { return }
        let params = PacketTunnelProvider.makeRelayParams(NWParameters.tcp)
        let conn = NWConnection(host: NWEndpoint.Host(key.dstString), port: port, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self, self.isRunning else { return }
            switch state {
            case .ready:
                flow.connReady = true
                let buffered = flow.pendingToServer
                flow.pendingToServer.removeAll()
                for data in buffered { self.sendToServer(flow, key: key, data: data, final: false) }
                if flow.clientFin { finishClientSide(flow, key: key) }
                self.tcpReceive(flow, key: key)
            case .failed(let error):
                self.log("TCP_FAIL", "\(key.describe) \(error)")
                self.sendRSTToClient(key, flow: flow)
                self.tcpFlows[key] = nil
            case .cancelled:
                self.tcpFlows[key] = nil
            case .waiting(let error):
                self.sampleLog("TCP_WAIT", "\(key.describe) \(error)")
            default:
                break
            }
        }
        flow.conn = conn
        conn.start(queue: engineQueue)
    }

    private func forwardToServer(_ flow: TCPFlow, key: FlowKey, payload: [UInt8]) {
        let data = Data(payload)
        guard flow.connReady, let conn = flow.conn else {
            if flow.pendingToServer.count < 128 { flow.pendingToServer.append(data) }
            return
        }
        sendToServer(flow, key: key, data: data, final: false)
    }

    private func sendToServer(_ flow: TCPFlow, key: FlowKey, data: Data, final: Bool) {
        guard let conn = flow.conn else { return }
        if final {
            conn.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        } else {
            conn.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error = error { self?.sampleLog("TCP_SEND_ERR", "\(key.describe) \(error)") }
            })
        }
    }

    private func finishClientSide(_ flow: TCPFlow, key: FlowKey) {
        guard flow.connReady, let conn = flow.conn, !flow.clientFinSent else { return }
        flow.clientFinSent = true
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func tcpReceive(_ flow: TCPFlow, key: FlowKey) {
        guard isRunning, flow.phase != .closed else { return }
        guard !flow.receivePaused else { return }
        flow.conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, self.isRunning else { return }
            if let data = data, !data.isEmpty {
                self.spliceServerToClient(flow, key: key, data: [UInt8](data))
            }
            if isComplete {
                // Real server closed its side → FIN to the client.
                flow.serverFin = true
                let fin = IP.tcpSegment(src: key.dst, sport: key.dport, dst: key.src, dport: key.sport,
                                        seq: flow.serverNext, ack: flow.clientNext,
                                        flags: kFIN | kACK, window: 64240, payload: [], mss: nil)
                flow.serverNext &+= 1
                self.deliverInboundDirect(IP.buildIPv4(proto: kTCP, src: key.dst, dst: key.src, l4: fin))
                self.sampleLog("TCP_FIN", "\(key.describe) server closed")
                if flow.clientFin { flow.phase = .closed; flow.conn?.cancel(); self.tcpFlows[key] = nil }
                return
            }
            if let error = error {
                self.sendRSTToClient(key, flow: flow)
                self.tcpFlows[key] = nil
                self.sampleLog("TCP_RECV_ERR", "\(key.describe) \(error)")
                return
            }
            if flow.unacked.count < 128 {
                self.tcpReceive(flow, key: key)
            } else {
                flow.receivePaused = true   // maintenance timer resumes it
            }
        }
    }

    private func spliceServerToClient(_ flow: TCPFlow, key: FlowKey, data: [UInt8]) {
        var offset = 0
        var batch: [[UInt8]] = []
        var segs: [(seq: UInt32, len: Int, seg: [UInt8], time: UInt64)] = []
        while offset < data.count {
            let chunk = Array(data[offset..<min(offset + Int(kMSS), data.count)])
            offset += chunk.count
            let seg = IP.tcpSegment(src: key.dst, sport: key.dport, dst: key.src, dport: key.sport,
                                    seq: flow.serverNext, ack: flow.clientNext,
                                    flags: kPSH | kACK, window: 64240, payload: chunk, mss: nil)
            let entrySeq = flow.serverNext
            flow.serverNext &+= UInt32(chunk.count)
            segs.append((seq: entrySeq, len: chunk.count, seg: seg, time: nowMs()))
            batch.append(IP.buildIPv4(proto: kTCP, src: key.dst, dst: key.src, l4: seg))
        }

        // ── Fake-lag gates for the DOWNLOAD direction ──
        var gated = false
        if config.enabled && lagMatches(key: key, isUpload: false) {
            switch config.mode {
            case "hold":
                for pkt in batch { enqueueHeld(StoredPacket(pkt: pkt, proto: AF_INET, outbound: false, dueMs: nowMs())) }
                gated = true
            case "delay":
                let due = nowMs() &+ UInt64(config.latencyMs + Int.random(in: 0...max(0, config.jitterMs)))
                for pkt in batch { enqueueDelayed(StoredPacket(pkt: pkt, proto: AF_INET, outbound: false, dueMs: due)) }
                gated = true
            case "drop":
                // Inbound TCP loss cannot be signalled to the real server through
                // NWConnection, so "drop" degrades to hold (stall until released).
                for pkt in batch { enqueueHeld(StoredPacket(pkt: pkt, proto: AF_INET, outbound: false, dueMs: nowMs())) }
                sampleLog("TCP_DROP", "inbound drop→hold degradation (TCP loss not expressible in userspace splice)")
                gated = true
            default:
                break
            }
        }
        // F5: gated segments are NOT registered in the retransmit buffer —
        // otherwise the 400ms maintenance retransmit (and 3-dupack retransmit)
        // would deliver "held"/"delayed" data early and the flush would then
        // deliver it AGAIN (duplicate segments, hold mode visually broken).
        if !gated {
            flow.unacked.append(contentsOf: segs)
            writePacketsBatch(batch)
            passed &+= UInt64(batch.count)
            relayedIn &+= UInt64(batch.count)
        } else {
            // still counts as relayed from the real server's perspective
            relayedOut &+= UInt64(batch.count)
        }
    }

    private func retransmit(_ flow: TCPFlow, key: FlowKey) {
        let now = nowMs()
        var batch: [[UInt8]] = []
        for entry in flow.unacked where now &- entry.time > 300 {
            batch.append(IP.buildIPv4(proto: kTCP, src: key.dst, dst: key.src, l4: entry.seg))
            if batch.count >= 8 { break }
        }
        if !batch.isEmpty {
            writePacketsBatch(batch)
            flow.dupAcks = 0
            sampleLog("TCP_RETX", "\(key.describe) retransmitted \(batch.count) segment(s)")
        }
    }

    private func sendRSTToClient(_ key: FlowKey, flow: TCPFlow) {
        let rst = IP.tcpSegment(src: key.dst, sport: key.dport, dst: key.src, dport: key.sport,
                                seq: flow.serverNext, ack: flow.clientNext,
                                flags: kRST | kACK, window: 0, payload: [], mss: nil)
        deliverInboundDirect(IP.buildIPv4(proto: kTCP, src: key.dst, dst: key.src, l4: rst))
    }

    // ── ICMP ─────────────────────────────────────────────────────────────────

    private func handleICMP(_ pkt: [UInt8], ihl: Int, src: [UInt8], dst: [UInt8]) {
        let icmpStart = ihl
        guard pkt.count >= icmpStart + 8 else { dropped &+= 1; return }
        let type = pkt[icmpStart]
        guard type == 8 else { dropped &+= 1; return } // echo request only
        let reply = IP.icmpEchoReply(pkt, ihl: ihl)
        deliverInboundDirect(reply)
        passed &+= 1
    }

    // ═══════════════════════ inbound / gates / queues ════════════════════════

    /// Writes crafted response packets to the TUN (download direction),
    /// applying hold/drop/delay when the simulation matches.
    private func deliverInbound(_ pkt: [UInt8]) {
        // (Gates were already applied by spliceServerToClient for TCP; UDP
        // responses are pure pass-through in this design — the lag was applied
        // to the request direction, which is what games feel.)
        writePacketsBatch([pkt])
    }

    /// Direct write used for handshake/synthetic packets — never lagged.
    private func deliverInboundDirect(_ pkt: [UInt8]) {
        writePacketsBatch([pkt])
    }

    private func writePacketsBatch(_ pkts: [[UInt8]]) {
        guard !pkts.isEmpty, isRunning else { return }
        let data = pkts.map { Data($0) }
        let protos = pkts.map { _ in NSNumber(value: AF_INET) }
        writeQueue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.packetFlow.writePackets(data, withProtocols: protos)
        }
    }

    /// Rule match for the fake-lag engine (direction + ratio; protocol filter
    /// and per-target socket match happen here too).
    private func lagMatches(key: FlowKey, isUpload: Bool) -> Bool {
        // Protocol filter
        if config.protoFilter == "tcp" && key.proto != kTCP { return false }
        if config.protoFilter == "udp" && key.proto != kUDP { return false }
        // Direction filter
        if config.direction == "upload" && !isUpload { return false }
        if config.direction == "download" && isUpload { return false }
        // Per-target match (socket dump from the app)
        if !matchTarget(key: key) { return false }
        // Capture ratio (master × directional)
        let ratio = isUpload ? config.uploadRatio : config.downloadRatio
        let eff = (config.captureRatio * ratio) / 100
        if eff >= 100 { return true }
        if eff <= 0 { return false }
        return Int.random(in: 0..<100) < eff
    }

    private func matchTarget(key: FlowKey) -> Bool {
        if config.targetBundleID.isEmpty && config.targetPID == 0 { return true }
        if config.targetSockets.isEmpty { return true }
        let dstIP = key.dstString
        let srcIP = key.srcString
        let protoStr = (key.proto == kTCP) ? "tcp" : "udp"
        for s in config.targetSockets {
            if s.remoteIP == dstIP || s.remoteIP == srcIP {
                if s.remotePort == key.dport || s.remotePort == key.sport || s.localPort == key.sport || s.localPort == key.dport {
                    if s.proto == protoStr { return true }
                }
            }
            if s.remotePort == key.dport || s.remotePort == key.sport {
                if s.proto == protoStr { return true }
            }
        }
        return false
    }

    private func enqueueHeld(_ p: StoredPacket) {
        queuesLock.lock()
        if heldQueue.count >= kMaxHeld {
            heldQueue.removeFirst()
            dropped &+= 1
        }
        heldQueue.append(p)
        queuesLock.unlock()
    }

    private func enqueueDelayed(_ p: StoredPacket) {
        queuesLock.lock()
        if delayedQueue.count >= kMaxDelayed {
            delayedQueue.removeFirst()
            dropped &+= 1
        }
        delayedQueue.append(p)
        queuesLock.unlock()
    }

    private func flushHeld(bypassGates: Bool) {
        queuesLock.lock()
        let toFlush = heldQueue
        heldQueue.removeAll()
        queuesLock.unlock()
        guard !toFlush.isEmpty else { return }
        log("FLUSH", "releasing \(toFlush.count) held packet(s) (bypass=\(bypassGates))")

        // Dedupe TCP upload retransmits captured while held (client RTO may
        // have queued the same seq multiple times — forwarding both would
        // corrupt the spliced stream). UDP datagrams cannot be deduped by seq
        // and duplicates are harmless there.
        var seenTCPSeq = Set<String>()
        var released = 0
        for p in toFlush {
            if p.outbound && p.proto == AF_INET && p.pkt.count >= 24 && (p.pkt[9] == kTCP) {
                let ihl = Int(p.pkt[0] & 0x0F) * 4
                if ihl + 4 <= p.pkt.count {
                    let src = "\(p.pkt[12]).\(p.pkt[13]).\(p.pkt[14]).\(p.pkt[15])"
                    let dst = "\(p.pkt[16]).\(p.pkt[17]).\(p.pkt[18]).\(p.pkt[19])"
                    let sport = (UInt16(p.pkt[ihl]) << 8) | UInt16(p.pkt[ihl + 1])
                    let dport = (UInt16(p.pkt[ihl + 2]) << 8) | UInt16(p.pkt[ihl + 3])
                    let seq = IP.rU32(p.pkt, ihl + 4)
                    let id = "\(src):\(sport)>\(dst):\(dport)#\(seq)"
                    if !seenTCPSeq.insert(id).inserted { continue }
                }
            }
            released += 1
            if p.outbound {
                handleOutbound(p.pkt, proto: p.proto, bypassGates: true)
            } else {
                writePacketsBatch([p.pkt])
                passed &+= 1
            }
        }
        if released < toFlush.count {
            log("FLUSH_DEDUPE", "dropped \(toFlush.count - released) duplicate held TCP segment(s)")
        }
    }

    /// F8: emergency release of the delay queue (used when the simulation is
    /// disabled or the mode changes away from "delay" — without this the
    /// periodic flusher's guard would leave packets stuck forever).
    private func flushDelayedNow() {
        queuesLock.lock()
        let ready = delayedQueue
        delayedQueue.removeAll()
        queuesLock.unlock()
        guard !ready.isEmpty else { return }
        log("FLUSH_DELAYED", "releasing \(ready.count) delayed packet(s) immediately")
        for p in ready {
            if p.outbound {
                handleOutbound(p.pkt, proto: p.proto, bypassGates: true)
            } else {
                writePacketsBatch([p.pkt])
                passed &+= 1
            }
        }
    }

    private func startDelayFlusher() {
        let t = DispatchSource.makeTimerSource(queue: engineQueue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.flushDelayed() }
        t.resume(); delayTimer = t
    }

    private func flushDelayed() {
        guard isRunning, config.enabled, config.mode == "delay" else { return }
        let now = nowMs()
        queuesLock.lock()
        var readyPackets: [StoredPacket] = []
        var remain: [StoredPacket] = []
        for p in delayedQueue { if now >= p.dueMs { readyPackets.append(p) } else { remain.append(p) } }
        delayedQueue = remain
        queuesLock.unlock()
        for p in readyPackets {
            if p.outbound {
                handleOutbound(p.pkt, proto: p.proto, bypassGates: true)
            } else {
                writePacketsBatch([p.pkt])
                passed &+= 1
                relayedIn &+= 1
            }
        }
    }

    // ═══════════════════════ timers & maintenance ════════════════════════════

    private func startStatsTimer() {
        // engineQueue, not configQueue: statsString() reads config AND
        // tcpFlows/udpFlows, which are engineQueue-only state.
        let t = DispatchSource.makeTimerSource(queue: engineQueue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.log("STATS", self.statsString())
        }
        t.resume(); statsTimer = t
    }

    private func startMaintenanceTimer() {
        let t = DispatchSource.makeTimerSource(queue: engineQueue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.maintenance() }
        t.resume(); maintenanceTimer = t
    }

    private func maintenance() {
        guard isRunning else { return }
        let now = nowMs()

        // F9: auto-release packets held longer than autoFlushSeconds (0 = keep
        // holding until the user releases manually). Mirrors the reference
        // payload's 12s safety valve so a forgotten hold doesn't kill the app.
        if config.enabled && config.mode == "hold" && config.autoFlushSeconds > 0 {
            let cutoff = now &- UInt64(config.autoFlushSeconds) * 1000
            var due: [StoredPacket] = []
            var keep: [StoredPacket] = []
            queuesLock.lock()
            for p in heldQueue { if p.dueMs <= cutoff { due.append(p) } else { keep.append(p) } }
            if !due.isEmpty { heldQueue = keep }
            queuesLock.unlock()
            if !due.isEmpty {
                log("AUTO_FLUSH", "releasing \(due.count) packet(s) held ≥\(config.autoFlushSeconds)s")
                for p in due {
                    if p.outbound {
                        handleOutbound(p.pkt, proto: p.proto, bypassGates: true)
                    } else {
                        writePacketsBatch([p.pkt])
                        passed &+= 1
                    }
                }
            }
        }

        // Retransmit stuck server→client segments (400ms guard).
        for (key, flow) in tcpFlows where !flow.unacked.isEmpty {
            let stuck = flow.unacked.first { now &- $0.time > 400 }
            if stuck != nil { retransmit(flow, key: key) }
        }

        // Resume paused TCP receives.
        for (key, flow) in tcpFlows where flow.receivePaused && flow.unacked.count < 64 {
            flow.receivePaused = false
            tcpReceive(flow, key: key)
        }

        // Idle-flow cleanup + table bounds (collect keys first — never mutate
        // a dictionary while iterating it).
        // &- (wrap-safe) everywhere: a plain UInt64 − here underflowed and
        // crashed the provider whenever the monotonic base was smaller than a
        // stale lastSeen (belt & braces on top of the monotonic nowMs()).
        var deadUDP: [FlowKey] = []
        for (key, flow) in udpFlows where now &- flow.lastSeen > 60_000 { deadUDP.append(key) }
        for key in deadUDP { udpFlows[key]?.conn?.cancel(); udpFlows[key] = nil }

        var deadTCP: [FlowKey] = []
        for (key, flow) in tcpFlows {
            let idleLimit: UInt64 = (flow.phase == .established) ? 900_000 : 30_000
            if now &- flow.lastSeen > idleLimit { deadTCP.append(key) }
        }
        for key in deadTCP { tcpFlows[key]?.conn?.cancel(); tcpFlows[key] = nil }

        while udpFlows.count > 512 {
            guard let first = udpFlows.keys.first else { break }
            udpFlows[first]?.conn?.cancel()
            udpFlows[first] = nil
        }
        while tcpFlows.count > 256 {
            guard let first = tcpFlows.keys.first else { break }
            tcpFlows[first]?.conn?.cancel()
            tcpFlows[first] = nil
        }
    }

    // ═══════════════════════════════ helpers ═════════════════════════════════

    /// Monotonic milliseconds since boot — NEVER use Date() here.
    /// Root cause of the "~15-17s tunnel death": nowMs() used the wall clock,
    /// and when iOS NTP/NITZ stepped the clock BACKWARD after the tunnel gave
    /// the device connectivity, the plain UInt64 subtraction with lastSeen
    /// underflowed inside maintenance() → SIGTRAP → the extension died
    /// instantly with no TUN_STOP log and the system tore the VPN down.
    /// DispatchTime is immune.
    private func nowMs() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }

    /// Log the first N flow events in detail, then every 100th (detail without spam).
    private func sampleLog(_ action: String, _ details: String) {
        flowCounter &+= 1
        if flowCounter <= 24 || flowCounter % 100 == 0 {
            log(action, "\(details) [flow#\(flowCounter)]")
        }
    }
}

// ═══════════════════════════ IP/TCP/UDP packet kit ═══════════════════════════

private enum IP {
    static func seqBefore(_ a: UInt32, _ b: UInt32) -> Bool { Int32(a &- b) < 0 }

    static func rU16(_ b: [UInt8], _ i: Int) -> UInt16 { (UInt16(b[i]) << 8) | UInt16(b[i + 1]) }
    static func rU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }

    static func checksum(_ bytes: [UInt8], start: Int, length: Int) -> UInt16 {
        var sum: UInt32 = 0
        var i = start
        let end = start + length
        while i + 1 < end {
            sum &+= (UInt32(bytes[i]) << 8) | UInt32(bytes[i + 1])
            i += 2
        }
        if i < end { sum &+= UInt32(bytes[i]) << 8 }
        while (sum >> 16) != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
        return UInt16(~sum & 0xFFFF)
    }

    static func l4Checksum(src: [UInt8], dst: [UInt8], proto: UInt8, seg: [UInt8]) -> UInt16 {
        var pseudo: [UInt8] = []
        pseudo.reserveCapacity(12 + seg.count + 1)
        pseudo.append(contentsOf: src)
        pseudo.append(contentsOf: dst)
        pseudo.append(0)
        pseudo.append(proto)
        pseudo.append(UInt8((seg.count >> 8) & 0xFF))
        pseudo.append(UInt8(seg.count & 0xFF))
        pseudo.append(contentsOf: seg)
        if pseudo.count % 2 != 0 { pseudo.append(0) }
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < pseudo.count {
            sum &+= (UInt32(pseudo[i]) << 8) | UInt32(pseudo[i + 1])
            i += 2
        }
        while (sum >> 16) != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
        return UInt16(~sum & 0xFFFF)
    }

    static func buildIPv4(proto: UInt8, src: [UInt8], dst: [UInt8], l4: [UInt8]) -> [UInt8] {
        var pkt = [UInt8](repeating: 0, count: 20 + l4.count)
        let totalLen = UInt16(20 + l4.count)
        pkt[0] = 0x45
        pkt[1] = 0x00
        pkt[2] = UInt8((totalLen >> 8) & 0xFF)
        pkt[3] = UInt8(totalLen & 0xFF)
        let ident = UInt16.random(in: 1...UInt16.max)
        pkt[4] = UInt8((ident >> 8) & 0xFF)
        pkt[5] = UInt8(ident & 0xFF)
        pkt[6] = 0x40 // DF
        pkt[7] = 0x00
        pkt[8] = 64
        pkt[9] = proto
        pkt[10] = 0; pkt[11] = 0
        pkt[12] = src[0]; pkt[13] = src[1]; pkt[14] = src[2]; pkt[15] = src[3]
        pkt[16] = dst[0]; pkt[17] = dst[1]; pkt[18] = dst[2]; pkt[19] = dst[3]
        let ck = checksum(pkt, start: 0, length: 20)
        pkt[10] = UInt8((ck >> 8) & 0xFF)
        pkt[11] = UInt8(ck & 0xFF)
        if !l4.isEmpty {
            pkt.replaceSubrange(20..<pkt.count, with: l4)
        }
        return pkt
    }

    static func tcpSegment(src: [UInt8], sport: UInt16, dst: [UInt8], dport: UInt16,
                           seq: UInt32, ack: UInt32, flags: UInt8, window: UInt16,
                           payload: [UInt8], mss: UInt16?) -> [UInt8] {
        var options: [UInt8] = []
        if let m = mss {
            options = [0x02, 0x04, UInt8((m >> 8) & 0xFF), UInt8(m & 0xFF)]
        }
        while options.count % 4 != 0 { options.append(0) }
        let headerLen = 20 + options.count
        var seg = [UInt8](repeating: 0, count: headerLen + payload.count)

        seg[0] = UInt8((sport >> 8) & 0xFF); seg[1] = UInt8(sport & 0xFF)
        seg[2] = UInt8((dport >> 8) & 0xFF); seg[3] = UInt8(dport & 0xFF)
        seg[4] = UInt8((seq >> 24) & 0xFF); seg[5] = UInt8((seq >> 16) & 0xFF)
        seg[6] = UInt8((seq >> 8) & 0xFF); seg[7] = UInt8(seq & 0xFF)
        seg[8] = UInt8((ack >> 24) & 0xFF); seg[9] = UInt8((ack >> 16) & 0xFF)
        seg[10] = UInt8((ack >> 8) & 0xFF); seg[11] = UInt8(ack & 0xFF)
        seg[12] = UInt8((headerLen / 4) << 4)
        seg[13] = flags
        seg[14] = UInt8((window >> 8) & 0xFF); seg[15] = UInt8(window & 0xFF)
        seg[16] = 0; seg[17] = 0 // checksum placeholder
        seg[18] = 0; seg[19] = 0 // urgent
        if !options.isEmpty {
            seg.replaceSubrange(20..<headerLen, with: options)
        }
        if !payload.isEmpty {
            seg.replaceSubrange(headerLen..<seg.count, with: payload)
        }
        let ck = l4Checksum(src: src, dst: dst, proto: 6, seg: seg)
        seg[16] = UInt8((ck >> 8) & 0xFF); seg[17] = UInt8(ck & 0xFF)
        return seg
    }

    static func buildUDP(src: [UInt8], sport: UInt16, dst: [UInt8], dport: UInt16, payload: [UInt8]) -> [UInt8] {
        var seg = [UInt8](repeating: 0, count: 8 + payload.count)
        let len = UInt16(8 + payload.count)
        seg[0] = UInt8((sport >> 8) & 0xFF); seg[1] = UInt8(sport & 0xFF)
        seg[2] = UInt8((dport >> 8) & 0xFF); seg[3] = UInt8(dport & 0xFF)
        seg[4] = UInt8((len >> 8) & 0xFF); seg[5] = UInt8(len & 0xFF)
        seg[6] = 0; seg[7] = 0
        if !payload.isEmpty {
            seg.replaceSubrange(8..<seg.count, with: payload)
        }
        let ck = l4Checksum(src: src, dst: dst, proto: 17, seg: seg)
        seg[6] = UInt8((ck >> 8) & 0xFF); seg[7] = UInt8(ck & 0xFF)
        return seg
    }

    static func icmpEchoReply(_ pkt: [UInt8], ihl: Int) -> [UInt8] {
        var pkt = pkt
        let icmpStart = ihl
        guard pkt.count >= icmpStart + 8, pkt[icmpStart] == 8 else { return pkt }
        let src: [UInt8] = [pkt[12], pkt[13], pkt[14], pkt[15]]
        let dst: [UInt8] = [pkt[16], pkt[17], pkt[18], pkt[19]]
        pkt[icmpStart] = 0 // echo reply
        pkt[icmpStart + 2] = 0; pkt[icmpStart + 3] = 0
        let icmpLen = pkt.count - icmpStart
        let ck = checksum(pkt, start: icmpStart, length: icmpLen)
        pkt[icmpStart + 2] = UInt8((ck >> 8) & 0xFF)
        pkt[icmpStart + 3] = UInt8(ck & 0xFF)
        pkt[12] = dst[0]; pkt[13] = dst[1]; pkt[14] = dst[2]; pkt[15] = dst[3]
        pkt[16] = src[0]; pkt[17] = src[1]; pkt[18] = src[2]; pkt[19] = src[3]
        pkt[10] = 0; pkt[11] = 0
        let ick = checksum(pkt, start: 0, length: 20)
        pkt[10] = UInt8((ick >> 8) & 0xFF)
        pkt[11] = UInt8(ick & 0xFF)
        return pkt
    }
}
