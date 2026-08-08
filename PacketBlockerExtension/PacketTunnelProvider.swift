import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var isLagEnabled = false
    private var lastConfigTimestamp: TimeInterval = 0
    private let queue = DispatchQueue(label: "com.fakelag", qos: .userInitiated)
    private var isRunning = false
    private var watchTimer: Timer?

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
        NSLog("[FakeLag] startTunnel called")

        isLagEnabled = false
        lastConfigTimestamp = 0

        // Apply settings first, then call completionHandler
        applySettings(lagEnabled: false) { [weak self] error in
            if let error = error {
                NSLog("[FakeLag] startTunnel FAILED: \(error)")
                completionHandler(error)
                return
            }

            self?.isRunning = true
            NSLog("[FakeLag] Tunnel UP. Lag=OFF")

            // Start config watcher
            self?.startConfigWatcher()

            // MUST call completionHandler AFTER setTunnelNetworkSettings succeeds
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[FakeLag] stopTunnel called. Reason: \(reason.rawValue)")
        isRunning = false
        isLagEnabled = false
        watchTimer?.invalidate()
        watchTimer = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        NSLog("[FakeLag] handleAppMessage called")
        completionHandler?(Data("ok".utf8))
    }

    // MARK: - Config Watcher

    private func startConfigWatcher() {
        guard isRunning else {
            NSLog("[FakeLag] Not starting watcher - not running")
            return
        }

        // Immediate first check
        queue.async { [weak self] in
            self?.checkConfig()
        }

        // Repeating timer on main thread
        DispatchQueue.main.async { [weak self] in
            self?.watchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                self?.queue.async {
                    self?.checkConfig()
                }
            }
        }
    }

    private func checkConfig() {
        guard let url = configURL else { return }

        guard FileManager.default.fileExists(atPath: url.path) else {
            // File doesn't exist yet - normal on first launch
            return
        }

        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            NSLog("[FakeLag] Failed to read config file")
            return
        }

        let enabled = dict["enabled"] as? Bool ?? false
        let timestamp = dict["timestamp"] as? TimeInterval ?? 0

        guard timestamp > lastConfigTimestamp else { return }
        lastConfigTimestamp = timestamp

        if enabled != isLagEnabled {
            isLagEnabled = enabled
            NSLog("[FakeLag] Config changed: lag=\(isLagEnabled) (ts=\(timestamp))")
            applySettings(lagEnabled: isLagEnabled) { error in
                if let error = error {
                    NSLog("[FakeLag] applySettings error: \(error)")
                }
            }
        }
    }

    // MARK: - Settings

    private func applySettings(lagEnabled: Bool, completion: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1500

        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        if lagEnabled {
            ipv4.includedRoutes = [NEIPv4Route.default()]
            NSLog("[FakeLag] Routes: ALL traffic via tunnel")
        } else {
            ipv4.includedRoutes = []
            NSLog("[FakeLag] Routes: NO traffic via tunnel (passthrough)")
        }
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
        if lagEnabled {
            ipv6.includedRoutes = [NEIPv6Route.default()]
        } else {
            ipv6.includedRoutes = []
        }
        settings.ipv6Settings = ipv6

        // Do NOT set DNS settings - let system use default DNS
        // This prevents DNS from getting stuck in the tunnel

        NSLog("[FakeLag] Calling setTunnelNetworkSettings...")
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                NSLog("[FakeLag] setTunnelNetworkSettings FAILED: \(error)")
                completion(error)
                return
            }

            NSLog("[FakeLag] setTunnelNetworkSettings OK")
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
        guard isRunning, isLagEnabled else {
            NSLog("[FakeLag] readLoop exiting: running=\(isRunning), lag=\(isLagEnabled)")
            return
        }

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

            if Int.random(in: 0..<100) < dropRate {
                continue
            }

            queue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                guard let self = self, self.isRunning, self.isLagEnabled else { return }
                let _ = self.packetFlow.writePackets([p], withProtocols: [proto])
            }
        }
    }
}
