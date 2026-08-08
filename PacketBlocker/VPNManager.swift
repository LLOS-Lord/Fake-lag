import NetworkExtension
import SwiftUI

class VPNManager: ObservableObject {
    static let shared = VPNManager()

    @Published var isVPNConnected = false
    @Published var isBlocking = false
    @Published var isProcessingCommand = false
    @Published var lastError: String?

    private var manager: NEAppProxyProviderManager?
    private var observer: NSObjectProtocol?

    private var extBundleID: String {
        let mainID = Bundle.main.bundleIdentifier ?? ""
        return mainID.isEmpty ? "com.ban.PacketBlocker.extension" : "\(mainID).extension"
    }

    private var configURL: URL {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.ban.PacketBlocker")!
            .appendingPathComponent("fakelag_config.plist")
    }

    private func writeConfig(enabled: Bool) {
        let dict: [String: Any] = [
            "enabled": enabled,
            "timestamp": Date().timeIntervalSince1970
        ]
        (dict as NSDictionary).write(to: configURL, atomically: true)
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
            if !self.isVPNConnected { self.isBlocking = false }
        }
    }

    func loadVPNConfiguration() {
        NEAppProxyProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.lastError = "Load loi: \(error.localizedDescription)"
                return
            }
            self.manager = managers?.first(where: {
                ($0.protocolConfiguration as? NEAppProxyProviderProtocol)?.providerBundleIdentifier == self.extBundleID
            }) ?? managers?.first
            self.updateStatus()
        }
    }

    func connectVPN() {
        // Reset config truoc khi bat
        writeConfig(enabled: false)

        if let manager = manager {
            manager.isEnabled = true
            manager.saveToPreferences { [weak self] error in
                DispatchQueue.main.async {
                    if let error = error {
                        self?.lastError = "Save loi: \(error.localizedDescription)"
                        return
                    }
                    do {
                        try manager.connection.startVPNTunnel()
                        self?.lastError = nil
                    } catch {
                        self?.lastError = "Bat loi: \(error.localizedDescription)"
                    }
                }
            }
        } else {
            createVPN()
        }
    }

    func disconnectVPN() {
        manager?.connection.stopVPNTunnel()
        lastError = nil
        isBlocking = false
    }

    private func createVPN() {
        let mgr = NEAppProxyProviderManager()
        let proto = NEAppProxyProviderProtocol()
        proto.providerBundleIdentifier = extBundleID
        proto.serverAddress = "127.0.0.1"

        // Proxy app Free Fire (com.dts.freefireth)
        // Tren jailbreak, co the hoat dong ma khong can MDM
        let rule = NEAppRule(signingIdentifier: "com.dts.freefireth")
        mgr.appRules = [rule]

        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "Fake Lag"
        mgr.isEnabled = true

        mgr.saveToPreferences { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.lastError = "Tao loi: \(error.localizedDescription)"
                    return
                }
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

        // Ghi file + timestamp
        writeConfig(enabled: target)

        // GUI UI ngay, khong cho IPC response
        isBlocking = target
        isProcessingCommand = false
        lastError = nil
    }
}
