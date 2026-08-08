import NetworkExtension
import SwiftUI

class VPNManager: ObservableObject {
    static let shared = VPNManager()

    @Published var isVPNConnected = false
    @Published var isBlocking = false
    @Published var isProcessingCommand = false
    @Published var lastError: String?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    private var extBundleID: String {
        let mainID = Bundle.main.bundleIdentifier ?? ""
        // Extension bundle ID must be: mainID + ".extension"
        return mainID.isEmpty ? "com.ban.PacketBlocker.extension" : "\(mainID).extension"
    }

    private var configURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.ban.PacketBlocker"
        ) else {
            return nil
        }
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container.appendingPathComponent("fakelag_config.plist")
    }

    private func writeConfig(enabled: Bool) {
        guard let url = configURL else {
            lastError = "App group not available"
            return
        }
        let dict: [String: Any] = [
            "enabled": enabled,
            "timestamp": Date().timeIntervalSince1970
        ]
        let success = (dict as NSDictionary).write(to: url, atomically: true)
        NSLog("[FakeLagApp] writeConfig enabled=\(enabled) success=\(success) path=\(url.path)")
    }

    init() {
        loadVPNConfiguration()
        setupStatusObserver()
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupStatusObserver() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateStatus()
        }
    }

    private func updateStatus() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let status = self.manager?.connection.status ?? .invalid
            self.isVPNConnected = (status == .connected)
            NSLog("[FakeLagApp] VPN status: \(status.rawValue) -> isConnected=\(self.isVPNConnected)")
            if !self.isVPNConnected { self.isBlocking = false }
        }
    }

    func loadVPNConfiguration() {
        NSLog("[FakeLagApp] Loading VPN configurations...")
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }

            if let error = error {
                self.lastError = "Load loi: \(error.localizedDescription)"
                NSLog("[FakeLagApp] loadAllFromPreferences error: \(error)")
                return
            }

            let count = managers?.count ?? 0
            NSLog("[FakeLagApp] Found \(count) VPN configuration(s)")

            // Try to find existing config with matching bundle ID
            self.manager = managers?.first(where: {
                let proto = $0.protocolConfiguration as? NETunnelProviderProtocol
                let bid = proto?.providerBundleIdentifier ?? "nil"
                NSLog("[FakeLagApp] Checking config bundleID: \(bid)")
                return bid == self.extBundleID
            })

            if self.manager == nil, let first = managers?.first {
                NSLog("[FakeLagApp] No exact match, using first available config")
                self.manager = first
            }

            if self.manager == nil {
                NSLog("[FakeLagApp] No config found - will create new")
            } else {
                NSLog("[FakeLagApp] Loaded existing config")
            }

            self.updateStatus()
        }
    }

    func connectVPN() {
        NSLog("[FakeLagApp] connectVPN called")
        writeConfig(enabled: false)

        if let manager = manager {
            NSLog("[FakeLagApp] Using existing manager")
            manager.isEnabled = true

            if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
                proto.disconnectOnSleep = false
                // Ensure bundle ID is correct
                proto.providerBundleIdentifier = extBundleID
                NSLog("[FakeLagApp] Set providerBundleIdentifier to: \(extBundleID)")
            }

            manager.saveToPreferences { [weak self] error in
                DispatchQueue.main.async {
                    if let error = error {
                        self?.lastError = "Save loi: \(error.localizedDescription)"
                        NSLog("[FakeLagApp] saveToPreferences error: \(error)")
                        return
                    }
                    NSLog("[FakeLagApp] Preferences saved, starting tunnel...")
                    do {
                        try manager.connection.startVPNTunnel()
                        self?.lastError = nil
                        NSLog("[FakeLagApp] startVPNTunnel called successfully")
                    } catch {
                        self?.lastError = "Bat loi: \(error.localizedDescription)"
                        NSLog("[FakeLagApp] startVPNTunnel error: \(error)")
                    }
                }
            }
        } else {
            NSLog("[FakeLagApp] No manager, creating new VPN config...")
            createVPN()
        }
    }

    func disconnectVPN() {
        NSLog("[FakeLagApp] disconnectVPN called")
        manager?.connection.stopVPNTunnel()
        lastError = nil
        isBlocking = false
    }

    private func createVPN() {
        NSLog("[FakeLagApp] createVPN called")
        let mgr = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = extBundleID
        proto.serverAddress = "127.0.0.1"
        proto.disconnectOnSleep = false

        // Add providerConfiguration to avoid nil issues
        proto.providerConfiguration = [:]

        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "Fake Lag"
        mgr.isEnabled = true

        NSLog("[FakeLagApp] Saving new config with bundleID: \(extBundleID)")
        mgr.saveToPreferences { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.lastError = "Tao loi: \(error.localizedDescription)"
                    NSLog("[FakeLagApp] saveToPreferences (create) error: \(error)")
                    return
                }
                NSLog("[FakeLagApp] New config saved, reloading...")
                self?.loadVPNConfiguration()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.connectVPN()
                }
            }
        }
    }

    func toggleBlocking() {
        if isProcessingCommand { return }
        isProcessingCommand = true

        let target = !isBlocking
        NSLog("[FakeLagApp] toggleBlocking -> \(target)")

        writeConfig(enabled: target)

        isBlocking = target
        isProcessingCommand = false
        lastError = nil
    }
}
