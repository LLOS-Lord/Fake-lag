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

    private var extensionBundleID: String {
        let mainID = Bundle.main.bundleIdentifier ?? ""
        if mainID.isEmpty { return "com.ban.PacketBlocker.extension" }
        return "\(mainID).extension"
    }

    private init() {
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
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.lastError = "Load config lỗi: \(error.localizedDescription)"
                return
            }
            self.manager = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.extensionBundleID
            }) ?? managers?.first
            self.updateStatus()
        }
    }

    func connectVPN() {
        if let manager = manager {
            manager.isEnabled = true
            if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
                proto.disconnectOnSleep = false
            }
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
                        self?.lastError = "Bật VPN lỗi: \(error.localizedDescription)"
                    }
                }
            }
        } else {
            createAndStartVPN()
        }
    }

    func disconnectVPN() {
        manager?.connection.stopVPNTunnel()
        lastError = nil
        isBlocking = false
    }

    private func createAndStartVPN() {
        let mgr = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = extensionBundleID
        proto.serverAddress = "127.0.0.1"
        proto.disconnectOnSleep = false

        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "Fake Lag Controller"
        mgr.isEnabled = true

        mgr.saveToPreferences { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.lastError = "Tạo profile lỗi: \(error.localizedDescription)"
                    return
                }
                self?.loadVPNConfiguration()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.connectVPN()
                }
            }
        }
    }

    // MARK: - Toggle Blocking (Ghi file + Ping nhẹ)

    func toggleBlocking() {
        if isProcessingCommand { return }
        isProcessingCommand = true

        let targetState = !isBlocking

        // 1. Ghi config vào file shared
        let config = SharedConfig.Config(
            enabled: targetState,
            delayMs: 100,
            dropEnabled: targetState,
            dropPercent: 30,
            timestamp: Date().timeIntervalSince1970
        )
        SharedConfig.shared.write(config: config)

        // 2. Nếu VPN đang connect, gửi ping nhẹ báo extension đọc file
        if isVPNConnected, let session = manager?.connection as? NETunnelProviderSession {
            do {
                try session.sendProviderMessage(Data("reload".utf8)) { _ in
                    // Không quan trọng response, file đã ghi xong
                }
            } catch {
                // Ping lỗi cũng không sao, extension sẽ đọc file ở lần tới
            }
        }

        // 3. Cập nhật UI ngay (không đợi extension phản hồi)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isBlocking = targetState
            self?.isProcessingCommand = false
            self?.lastError = nil
        }
    }
}
