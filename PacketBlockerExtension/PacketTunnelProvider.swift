import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var isLagEnabled = false
    private let queue = DispatchQueue(label: "com.fakelag", qos: .userInitiated)
    private var isRunning = false
    private var lastConfigCheck: TimeInterval = 0

    private var configURL: URL {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.ban.PacketBlocker")!
            .appendingPathComponent("lag.plist")
    }

    private func readEnabled() -> Bool {
        guard let data = try? Data(contentsOf: configURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }
        return dict["enabled"] as? Bool ?? false
    }

    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        // Luôn bắt đầu với lag TẮT
        isLagEnabled = false

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1500

        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["8.8.8.8", "1.1.1.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                NSLog("[FakeLag] setTunnelNetworkSettings FAILED: \(error)")
                completionHandler(error)
                return
            }

            self?.isRunning = true
            NSLog("[FakeLag] Tunnel UP. Lag=OFF")

            // Bắt đầu đọc packet
            self?.queue.async {
                self?.readLoop()
            }

            // Theo dõi config
            self?.watchConfig()

            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        isRunning = false
        isLagEnabled = false
        NSLog("[FakeLag] Tunnel DOWN")
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(Data("ok".utf8))
        if let cmd = String(data: messageData, encoding: .utf8) {
            isLagEnabled = (cmd == "enable")
            NSLog("[FakeLag] IPC: lag=\(isLagEnabled)")
        }
    }

    private func watchConfig() {
        guard isRunning else { return }
        let now = Date().timeIntervalSince1970
        if now - lastConfigCheck >= 2.0 {
            lastConfigCheck = now
            let wasEnabled = isLagEnabled
            isLagEnabled = readEnabled()
            if isLagEnabled != wasEnabled {
                NSLog("[FakeLag] File: lag=\(isLagEnabled)")
            }
        }
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.watchConfig()
        }
    }

    // MARK: - Read Loop

    private func readLoop() {
        guard isRunning else { return }

        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { return }

            if packets.isEmpty {
                self.readLoop()
                return
            }

            if self.isLagEnabled {
                // DELAY + DROP
                self.applyLag(packets: packets, protocols: protocols)
            } else {
                // ECHO NGAY
                self.echo(packets: packets, protocols: protocols)
            }

            // Tiếp tục đọc
            self.readLoop()
        }
    }

    private func echo(packets: [Data], protocols: [NSNumber]) {
        let _ = packetFlow.writePackets(packets, withProtocols: protocols)
    }

    private func applyLag(packets: [Data], protocols: [NSNumber]) {
        let delayMs = 300
        let dropRate = 15

        for i in 0..<packets.count {
            let p = packets[i]
            let proto = protocols[i]

            // Drop ngẫu nhiên
            if Int.random(in: 0..<100) < dropRate {
                continue
            }

            // Delay rồi echo
            queue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                guard let self = self, self.isRunning else { return }
                let _ = self.packetFlow.writePackets([p], withProtocols: [proto])
            }
        }
    }
}
