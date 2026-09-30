import NetworkExtension
import Foundation

// Hybrid Fixed PacketTunnelProvider - same as v1 but with logging
class PacketTunnelProvider: NEPacketTunnelProvider {
    private var isRunning = false
    private var config = HybridConfig()
    private var lastConfigTS: TimeInterval = 0
    private let readQueue = DispatchQueue(label: "com.hybrid.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "com.hybrid.write", qos: .userInitiated)
    private let configQueue = DispatchQueue(label: "com.hybrid.config", qos: .utility)
    private var configTimer: DispatchSourceTimer?
    private var heldQueue: [(Data, Int32)] = []
    private let heldLock = NSLock()
    private let maxHeld = 512
    private var delayedQueue: [(Data, Int32, UInt64)] = []
    private let delayedLock = NSLock()
    private var delayTimer: DispatchSourceTimer?
    private var dropped: UInt64 = 0
    private var passed: UInt64 = 0
    
    private var groupURL: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.hybrid.fakelag") }
    private var configURL: URL? { groupURL?.appendingPathComponent("hybrid_config.json") }
    private var legacyURL: URL? { groupURL?.appendingPathComponent("fakelag_config.plist") }
    private var logURL: URL? { groupURL?.appendingPathComponent("hybrid_actions.log") }
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[Hybrid] startTunnel FIXED V2 with floating button support")
        isRunning = true
        loadConfig()
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        settings.mtu = NSNumber(value: 1280)
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        let ipv6 = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6
        let dns = NEDNSSettings(servers: ["8.8.8.8","1.1.1.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        setTunnelNetworkSettings(settings) { [weak self] err in
            guard let self = self else { completionHandler(nil); return }
            if let err = err { NSLog("[Hybrid] setTunnel FAILED \(err)"); completionHandler(err); return }
            self.startConfigWatcher()
            self.startDelayFlusher()
            self.readQueue.async { self.readLoop() }
            self.log("TUN_START", "mtu 1280 includeAllNetworks")
            completionHandler(nil)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[Hybrid] stop reason %d passed %llu dropped %llu held %d", reason.rawValue, passed, dropped, heldQueue.count)
        isRunning = false
        configTimer?.cancel(); configTimer=nil
        delayTimer?.cancel(); delayTimer=nil
        flushHeld()
        log("TUN_STOP", "reason \(reason.rawValue)")
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let msg = String(data: messageData, encoding: .utf8) {
            NSLog("[Hybrid] appMessage %@", msg)
            if msg == "enable" { var c = loadSync(); c.enabled=true; log("MSG_ENABLE","") }
            else if msg == "disable" { flushHeld(); var c = loadSync(); c.enabled=false; log("MSG_DISABLE","") }
        }
        loadConfig()
        completionHandler?(Data("ok".utf8))
    }
    
    private func startConfigWatcher() {
        let t = DispatchSource.makeTimerSource(queue: configQueue)
        t.schedule(deadline: .now()+0.5, repeating: 0.8)
        t.setEventHandler { [weak self] in self?.loadConfig() }
        t.resume(); configTimer=t
    }
    
    private func loadConfig() {
        let cfg = loadSync()
        if cfg.timestamp > lastConfigTS {
            lastConfigTS = cfg.timestamp
            config = cfg
            NSLog("[Hybrid] cfg enabled=%d mode=%@ target=%@ sockets=%d", cfg.enabled ? 1:0, cfg.mode, cfg.targetBundleID, cfg.targetSockets.count)
            if !cfg.enabled { flushHeld() }
        }
    }
    
    private func loadSync() -> HybridConfig {
        guard let url = configURL, let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(HybridConfig.self, from: data) else {
            if let lurl = legacyURL, let dict = NSDictionary(contentsOf: lurl) as? [String: Any] {
                var c = HybridConfig(); c.enabled = dict["enabled"] as? Bool ?? false; c.timestamp = dict["timestamp"] as? TimeInterval ?? 0; return c
            }
            return HybridConfig()
        }
        return cfg
    }
    
    private func readLoop() {
        guard isRunning else { return }
        packetFlow.readPackets { [weak self] packets, protos in
            guard let self=self, self.isRunning else { return }
            for i in 0..<packets.count { self.handlePacket(packets[i], proto: protos[i].int32Value) }
            self.readQueue.async { self.readLoop() }
        }
    }
    
    private func handlePacket(_ packet: Data, proto: Int32) {
        guard isRunning else { return }
        if proto != AF_INET {
            if config.enabled && config.targetBundleID.isEmpty { handleMode(packet, proto: proto) } else { writePacket(packet, proto: proto) }
            return
        }
        guard packet.count>=20, (packet[0]>>4)==4 else { writePacket(packet, proto: proto); return }
        if !config.enabled { writePacket(packet, proto: proto); return }
        if !matchTarget(packet) { writePacket(packet, proto: proto); return }
        if !passDirProto(packet) { writePacket(packet, proto: proto); return }
        handleMode(packet, proto: proto)
    }
    
    private func matchTarget(_ packet: Data) -> Bool {
        if config.targetBundleID.isEmpty && config.targetPID==0 { return true }
        if config.targetSockets.isEmpty { return true }
        let ipLen = Int((packet[0] & 0x0F)*4)
        guard packet.count >= ipLen+4 else { return false }
        let proto = packet[9]
        guard proto==6||proto==17 else { return false }
        let srcPort = UInt16(packet[ipLen])<<8 | UInt16(packet[ipLen+1])
        let dstPort = UInt16(packet[ipLen+2])<<8 | UInt16(packet[ipLen+3])
        let srcIP = "\(packet[12]).\(packet[13]).\(packet[14]).\(packet[15])"
        let dstIP = "\(packet[16]).\(packet[17]).\(packet[18]).\(packet[19])"
        for s in config.targetSockets {
            if s.remoteIP==dstIP || s.remoteIP==srcIP {
                if s.remotePort==dstPort || s.remotePort==srcPort || s.localPort==srcPort || s.localPort==dstPort {
                    if (s.proto=="tcp" && proto==6) || (s.proto=="udp" && proto==17) { return true }
                }
            }
            if s.remotePort==dstPort || s.remotePort==srcPort { if (s.proto=="tcp" && proto==6) || (s.proto=="udp" && proto==17) { return true } }
        }
        return false
    }
    
    private func passDirProto(_ packet: Data) -> Bool {
        let ipLen = Int((packet[0] & 0x0F)*4)
        guard packet.count>=ipLen else { return true }
        let proto = packet[9]
        let isTCP = proto==6, isUDP = proto==17
        if config.protoFilter=="tcp" && !isTCP { return false }
        if config.protoFilter=="udp" && !isUDP { return false }
        let srcIP = "\(packet[12]).\(packet[13]).\(packet[14]).\(packet[15])"
        let isUpload = srcIP=="10.8.0.2" || srcIP.hasPrefix("10.8.")
        if config.direction=="upload" && !isUpload { return false }
        if config.direction=="download" && isUpload { return false }
        let ratio = isUpload ? config.uploadRatio : config.downloadRatio
        let eff = (config.captureRatio * ratio)/100
        if eff>=100 { return true }
        if eff<=0 { return false }
        return Int.random(in: 0..<100) < eff
    }
    
    private func handleMode(_ packet: Data, proto: Int32) {
        switch config.mode {
        case "hold":
            heldLock.lock()
            if heldQueue.count < maxHeld { heldQueue.append((packet,proto)) }
            else { heldQueue.removeFirst(); heldQueue.append((packet,proto)); dropped+=1 }
            heldLock.unlock()
        case "drop":
            if isCriticalTCP(packet) { writePacket(packet, proto: proto) } else { dropped+=1 }
        case "delay":
            delayedLock.lock()
            if delayedQueue.count < maxHeld { delayedQueue.append((packet,proto,nowMs())) }
            delayedLock.unlock()
        default:
            writePacket(packet, proto: proto)
        }
    }
    
    private func isCriticalTCP(_ packet: Data) -> Bool {
        let ipLen = Int((packet[0] & 0x0F)*4)
        guard packet.count >= ipLen+14, packet[9]==6 else { return false }
        let flags = packet[ipLen+13]
        return (flags & 0x02) != 0 || (flags & 0x01) != 0 || (flags & 0x04) != 0
    }
    
    private func writePacket(_ packet: Data, proto: Int32) {
        guard isRunning else { return }
        passed+=1
        writeQueue.async { [weak self] in guard let self=self, self.isRunning else { return }; _ = self.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: proto)]) }
    }
    
    private func flushHeld() {
        heldLock.lock(); let toFlush = heldQueue; heldQueue.removeAll(); heldLock.unlock()
        if toFlush.isEmpty { return }
        log("FLUSH", "flushing \(toFlush.count) held packets")
        writeQueue.async { [weak self] in guard let self=self else { return }; for (pkt,pr) in toFlush { _ = self.packetFlow.writePackets([pkt], withProtocols: [NSNumber(value: pr)]) } }
    }
    
    private func startDelayFlusher() {
        let t = DispatchSource.makeTimerSource(queue: writeQueue)
        t.schedule(deadline: .now()+0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.flushDelayed() }
        t.resume(); delayTimer=t
    }
    
    private func flushDelayed() {
        guard isRunning, config.enabled, config.mode=="delay" else { return }
        let now = nowMs()
        let delay = UInt64(config.latencyMs + Int.random(in: 0...max(0, config.jitterMs)))
        delayedLock.lock()
        var ready: [(Data,Int32)]=[]; var remain: [(Data,Int32,UInt64)]=[]
        for item in delayedQueue { if now >= item.2+delay { ready.append((item.0,item.1)) } else { remain.append(item) } }
        delayedQueue=remain; delayedLock.unlock()
        for (pkt,pr) in ready { _ = packetFlow.writePackets([pkt], withProtocols: [NSNumber(value: pr)]); passed+=1 }
    }
    
    private func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970*1000) }
    
    private func log(_ action: String, _ details: String) {
        guard let url = logURL else { return }
        let line = "[\(Date())] [ext] \(action) \(details) passed=\(passed) dropped=\(dropped) held=\(heldQueue.count)\n"
        if FileManager.default.fileExists(atPath: url.path) {
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        } else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}

struct HybridConfig: Codable {
    var enabled: Bool=false; var mode:String="hold"; var direction:String="both"; var protoFilter:String="both"
    var captureRatio:Int=100; var downloadRatio:Int=100; var uploadRatio:Int=100
    var latencyMs:Int=350; var jitterMs:Int=80; var bandwidthKbps:Int=0; var duplicatePercent:Int=0; var autoFlushSeconds:Int=12
    var dropUDPPercent:Int=15; var dropTCPPercent:Int=5
    var targetBundleID:String=""; var targetPID:Int32=0; var targetProcessName:String=""; var targetSockets:[SocketEntry]=[]
    var floatingSize:Float=58; var floatingOpacity:Float=0.94; var floatingEdgeSnap:Bool=true; var floatingLockPosition:Bool=false; var floatingHaptic:Bool=true; var floatingPosX:Float=310; var floatingPosY:Float=220
    var timestamp:TimeInterval=0; var preset:String="custom"
}
struct SocketEntry: Codable { var localPort:UInt16; var remotePort:UInt16; var remoteIP:String; var proto:String }
