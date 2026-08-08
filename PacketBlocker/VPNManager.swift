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
    private var heartbeatTimer: Timer?
    private var pendingCommand: String?
    private var commandCompletion: ((Bool) -> Void)?

    private var extensionBundleID: String {
        let mainID = Bundle.main.bundleIdentifier ?? ""
        if mainID.isEmpty { return "com.ban.PacketBlocker.extension" }
        return "\(mainID).extension"
    }

    private init() {
        loadVPNConfiguration()
        setupStatusObserver()
        startHeartbeat()
    }

    deinit {
        stopHeartbeat()
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Heartbeat để giữ kết nối sống

    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.sendHeartbeat()
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func sendHeartbeat() {
        guard isVPNConnected, let session = manager?.connection as? NETunnelProviderSession else { return }

        let heartbeatData = Data("heartbeat".utf8)
        try? session.sendProviderMessage(heartbeatData) { _ in
            // Không cần xử lý response, chỉ cần giữ pipe sống
        }
    }

    private func setupStatusObserver() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.updateStatus()
        }
    }

    private func updateStatus() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let status = self.manager?.connection.status ?? .invalid
            let wasConnected = self.isVPNConnected
            self.isVPNConnected = (status == .connected)

            if !self.isVPNConnected {
                self.isBlocking = false
            }

            // Nếu vừa connect xong, thử gửi lại command đang pending
            if !wasConnected && self.isVPNConnected, let pending = self.pendingCommand {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.sendCommand(pending) { success in
                        self.pendingCommand = nil
                        self.commandCompletion?(success)
                        self.commandCompletion = nil
                    }
                }
            }
        }
    }

    func loadVPNConfiguration() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.lastError = "Lỗi load config: \(error.localizedDescription)"
                }
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
                        self?.lastError = "Lỗi save preferences: \(error.localizedDescription)"
                        return
                    }
                    do {
                        try manager.connection.startVPNTunnel()
                        self?.lastError = nil
                    } catch {
                        self?.lastError = "Lỗi bật VPN: \(error.localizedDescription)"
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

        // Thêm includeAllNetworks để đảm bảo bắt toàn bộ traffic
        proto.includeAllNetworks = true

        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "Fake Lag Controller"
        mgr.isEnabled = true

        mgr.saveToPreferences { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.lastError = "Lỗi tạo profile: \(error.localizedDescription)"
                    return
                }
                self?.loadVPNConfiguration()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.connectVPN()
                }
            }
        }
    }

    // MARK: - Toggle Blocking (KHÔNG disconnect/connect lại)

    func toggleBlocking() {
        guard isVPNConnected else {
            self.lastError = "VPN chưa kết nối. Đang khởi động..."
            pendingCommand = isBlocking ? "disableBlocking" : "enableBlocking"
            commandCompletion = { [weak self] success in
                DispatchQueue.main.async {
                    if success {
                        self?.isBlocking.toggle()
                        self?.lastError = nil
                    } else {
                        self?.lastError = "Không thể giao tiếp với Extension."
                    }
                    self?.isProcessingCommand = false
                }
            }
            connectVPN()
            return
        }

        if isProcessingCommand { return }
        isProcessingCommand = true

        let targetState = !isBlocking
        let command = targetState ? "enableBlocking" : "disableBlocking"

        sendCommand(command) { [weak self] success in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isProcessingCommand = false
                if success {
                    self.isBlocking = targetState
                    self.lastError = nil
                } else {
                    // KHÔNG disconnect/connect. Chỉ thử gửi lại 1 lần nữa sau 1s
                    self.lastError = "Đang thử lại..."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.sendCommand(command) { retrySuccess in
                            DispatchQueue.main.async {
                                self.isProcessingCommand = false
                                if retrySuccess {
                                    self.isBlocking = targetState
                                    self.lastError = nil
                                } else {
                                    self.lastError = "Extension không phản hồi. Hãy bật lại VPN từ Cài đặt."
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Gửi command ổn định (KHÔNG reconnect)

    private func sendCommand(_ command: String, completion: @escaping (Bool) -> Void) {
        guard let session = manager?.connection as? NETunnelProviderSession,
              manager?.connection.status == .connected else {
            completion(false)
            return
        }

        let data = Data(command.utf8)
        var didComplete = false

        do {
            try session.sendProviderMessage(data) { response in
                guard !didComplete else { return }
                didComplete = true
                let success = response != nil
                DispatchQueue.main.async {
                    completion(success)
                }
            }
        } catch {
            didComplete = true
            DispatchQueue.main.async {
                completion(false)
            }
            return
        }

        // Timeout 3 giây, KHÔNG tự động reconnect
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard !didComplete else { return }
            didComplete = true
            // Thử gửi heartbeat để "đánh thức" pipe
            self?.sendHeartbeat()
            completion(false)
        }
    }

    // MARK: - Refresh profile (chỉ khi thực sự cần)

    func refreshVPNProfile(completion: @escaping (Bool) -> Void) {
        // KHÔNG remove profile, chỉ reload và reconnect nếu cần
        loadVPNConfiguration()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }
            if self.isVPNConnected {
                completion(true)
            } else {
                self.connectVPN()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    completion(self.isVPNConnected)
                }
            }
        }
    }
}
