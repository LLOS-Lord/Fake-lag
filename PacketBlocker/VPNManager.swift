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

    private var extensionBundleID: String {
        let mainID = Bundle.main.bundleIdentifier ?? ""
        if mainID.isEmpty { return "com.ban.PacketBlocker.extension" }
        return "\(mainID).extension"
    }

    private init() {
        loadConfiguration()
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

    func loadConfiguration() {
        NEAppProxyProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.lastError = "Load lỗi: \(error.localizedDescription)"
                return
            }
            self.manager = managers?.first(where: {
                ($0.providerProtocol as? NEAppProxyProviderProtocol)?.providerBundleIdentifier == self.extensionBundleID
            }) ?? managers?.first
            self.updateStatus()
        }
    }

    func connectVPN() {
        if let manager = manager {
            manager.isEnabled = true
            manager.saveToPreferences { [weak self] error in
                DispatchQueue.main.async {
                    if let error = error {
                        self?.lastError = "Save lỗi: \(error.localizedDescription)"
                        return
                    }
                    do {
                        try manager.connection.startVPNTunnel()
                        self?.lastError = nil
                    } catch {
                        self?.lastError = "Bật lỗi: \(error.localizedDescription)"
                    }
                }
            }
        } else {
            createAndStart()
        }
    }

    func disconnectVPN() {
        manager?.connection.stopVPNTunnel()
        lastError = nil
        isBlocking = false
    }

    private func createAndStart() {
        let mgr = NEAppProxyProviderManager()
        let proto = NEAppProxyProviderProtocol()
        proto.providerBundleIdentifier = extensionBundleID
        proto.serverAddress = "127.0.0.1"
        proto.disconnectOnSleep = false

        mgr.providerProtocol = proto
        mgr.localizedDescription = "Fake Lag Proxy"
        mgr.isEnabled = true

        mgr.saveToPreferences { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.lastError = "Tạo lỗi: \(error.localizedDescription)"
                    return
                }
                self?.loadConfiguration()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.connectVPN()
                }
            }
        }
    }

    func toggleBlocking() {
        if isProcessingCommand { return }
        isProcessingCommand = true

        let targetState = !isBlocking
        let command = targetState ? "enable" : "disable"

        guard isVPNConnected, let session = manager?.connection as? NETunnelProviderSession else {
            lastError = "Proxy chưa kết nối"
            isProcessingCommand = false
            return
        }

        do {
            try session.sendProviderMessage(Data(command.utf8)) { [weak self] response in
                DispatchQueue.main.async {
                    if response != nil {
                        self?.isBlocking = targetState
                        self?.lastError = nil
                    } else {
                        self?.lastError = "Proxy không phản hồi"
                    }
                    self?.isProcessingCommand = false
                }
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "Gửi lỗi: \(error.localizedDescription)"
                self?.isProcessingCommand = false
            }
        }
    }
}
