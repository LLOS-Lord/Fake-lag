import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var isPulseActive = false
    private var isCurrentlyDropping = false
    private var pulseWorkItem: DispatchWorkItem?
    private let processingQueue = DispatchQueue(label: "com.fakelag.packet", qos: .userInitiated)
    private var isRunning = false

    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        // Đảm bảo completionHandler LUÔN được gọi
        var completionCalled = false
        let safeComplete: (Error?) -> Void = { error in
            guard !completionCalled else { return }
            completionCalled = true
            completionHandler(error)
        }

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
                safeComplete(error)
                return
            }

            self?.isRunning = true

            // Bắt đầu packet loop trên background queue
            self?.processingQueue.async {
                self?.startPacketLoop()
            }

            safeComplete(nil)
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
        // LUÔN gọi completionHandler ngay, kể cả khi lỗi
        defer {
            completionHandler?(Data("ok".utf8))
        }

        guard let command = String(data: messageData, encoding: .utf8) else {
            return
        }

        switch command {
        case "heartbeat":
            break
        case "enableBlocking":
            isPulseActive = true
            isCurrentlyDropping = true
            startPulseLoop()
        case "disableBlocking":
            isPulseActive = false
            isCurrentlyDropping = false
            pulseWorkItem?.cancel()
            pulseWorkItem = nil
        default:
            break
        }
    }

    // MARK: - Pulse Loop (Cơ chế Fake Lag)

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
            // Nếu dropping -> silently discard

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
