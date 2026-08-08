import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var isLagEnabled = false
    private var lastConfigTimestamp: TimeInterval = 0
    private let queue = DispatchQueue(label: "com.fakelag", qos: .userInitiated)
    private var isRunning = false
    private var watchTimer: Timer?

    private var configURL: URL {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.ban.PacketBlocker")!
            .appendingPathComponent("fakelag_config.plist")
    }

    // MARK: - Lifecycle

    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        isLagEnabled = false
        lastConfigTimestamp = 0

        applySettings(lagEnabled: false) { [weak self] error in
            if let error = error {
                NSLog("[FakeLag] startTunnel FAILED: \(error)")
                completionHandler(error)
                return
            }
            self?.isRunning = true
            NSLog("[FakeLag] Tunnel UP. Lag=OFF")
            self?.startConfigWatcher()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        isRunning = false
        isLagEnabled = false
        watchTimer?.invalidate()
        watchTimer = nil
        NSLog("[FakeLag] Tunnel DOWN")
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(Data("ok".utf8))
    }

    // MARK: - Config Watcher

    private func startConfigWatcher() {
        guard isRunning else { return }
        queue.async { [weak self] in
            self?.checkConfig()
        }
        DispatchQueue.main.async { [weak self] in
            self?.watchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                self?.queue.async {
                    self?.checkConfig()
                }
            }
        }
    }

    private func checkConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return
        }
        let enabled = dict["enabled"] as? Bool ?? false
        let timestamp = dict["timestamp"] as? TimeInterval ?? 0

        guard timestamp > lastConfigTimestamp else { return }
        lastConfigTimestamp = timestamp

        if enabled != isLagEnabled {
            isLagEnabled = enabled
            NSLog("[FakeLag] Config: lag=\(isLagEnabled) (ts=\(timestamp))")
            applySettings(lagEnabled: isLagEnabled) { _ in }
        }
    }

    // MARK: - Settings

    private func applySettings(lagEnabled: Bool, completion: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1500

        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        if lagEnabled {
            ipv4.includedRoutes = [NEIPv4Route.default()]
        } else {
            ipv4.includedRoutes = []
        }
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
        if lagEnabled {
            ipv6.includedRoutes = [NEIPv6Route.default()]
        } else {
            ipv6.includedRoutes = []
        }
        settings.ipv6Settings = ipv6

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                NSLog("[FakeLag] Settings error: \(error)")
                completion(error)
                return
            }
            if lagEnabled {
                self?.queue.async {
                    self?.readLoop()
                }
            }
            completion(nil)
        }
    }

    // MARK: - Read Loop

    private func readLoop() {
        guard isRunning, isLagEnabled else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning, self.isLagEnabled else { return }
            if packets.isEmpty {
                self.readLoop()
                return
            }
            self.applyLag(packets: packets, protocols: protocols)
            self.readLoop()
        }
    }

    private func applyLag(packets: [Data], protocols: [NSNumber]) {
        let delayMs = 300
        let dropRate = 15
        for i in 0..<packets.count {
            let p = packets[i]
            let proto = protocols[i]
            if Int.random(in: 0..<100) < dropRate { continue }
            queue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                guard let self = self, self.isRunning, self.isLagEnabled else { return }
                let _ = self.packetFlow.writePackets([p], withProtocols: [proto])
            }
        }
    }
}
