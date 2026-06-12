import NetworkExtension
import SwiftUI

class VPNManager: ObservableObject {
    static let shared = VPNManager()            // Singleton – sửa lỗi "has no member 'shared'"

    @Published var isVPNConnected = false
    @Published var isBlocking = false
    @Published var lastError: String?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    private let extensionBundleID = "com.tenban.PacketBlocker.extension"  // Đảm bảo khớp với project

    init() {
        loadVPNConfiguration()
        setupStatusObserver()
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - VPN Status Observing

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
            self.isVPNConnected = self.manager?.connection.status == .connected
            if !self.isVPNConnected {
                self.isBlocking = false   // VPN đứt thì tắt trạng thái chặn
            }
        }
    }

    // MARK: - VPN Configuration Loading

    private func loadVPNConfiguration() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.lastError = "Load error: \(error.localizedDescription)"
                return
            }
            self.manager = managers?.first
            self.updateStatus()
        }
    }

    // MARK: - Public Actions

    func connectVPN() {
        if let manager = manager {
            startExistingVPN(manager: manager)
        } else {
            createAndStartVPN()
        }
    }

    func toggleBlocking() {
        guard isVPNConnected else {
            lastError = "Vui lòng Connect VPN trước"
            return
        }
        let newBlock = !isBlocking
        sendBlockCommand(block: newBlock)
    }

    func disconnectVPN() {
        manager?.connection.stopVPNTunnel()
        lastError = nil
    }

    // MARK: - Private Helpers

    private func sendBlockCommand(block: Bool) {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            lastError = "No active session"
            return
        }
        let message = block ? "block" : "unblock"
        do {
            try session.sendProviderMessage(message.data(using: .utf8)!) { [weak self] response in
                DispatchQueue.main.async {
                    self?.isBlocking = block    // cập nhật UI ngay khi gửi thành công
                }
            }
        } catch {
            lastError = "Send command error: \(error.localizedDescription)"
        }
    }

    private func startExistingVPN(manager: NETunnelProviderManager) {
        do {
            try manager.connection.startVPNTunnel()
            lastError = nil
        } catch {
            lastError = "Start error: \(error.localizedDescription)"
        }
    }

    private func createAndStartVPN() {
        let mgr = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()

        proto.providerBundleIdentifier = extensionBundleID
        proto.serverAddress = "PacketBlocker"
        proto.disconnectOnSleep = false

        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "Packet Blocker"
        mgr.isEnabled = true

        mgr.saveToPreferences { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.lastError = "Save error: \(error.localizedDescription)"
                return
            }

            mgr.loadFromPreferences { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.lastError = "Load error: \(error.localizedDescription)"
                    return
                }
                self.manager = mgr
                do {
                    try mgr.connection.startVPNTunnel()
                } catch {
                    self.lastError = "Start tunnel error: \(error.localizedDescription)"
                }
            }
        }
    }
}