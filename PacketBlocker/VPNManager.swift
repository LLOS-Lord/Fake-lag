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
    
    // ⚠️ QUAN TRỌNG: Đảm bảo Bundle ID này khớp với Target Extension trong Xcode
    private let extensionBundleID = "com.tenban.PacketBlocker.extension"
    
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
            let wasConnected = self.isVPNConnected
            self.isVPNConnected = self.manager?.connection.status == .connected
            
            if wasConnected && !self.isVPNConnected {
                self.isBlocking = false
                self.isProcessingCommand = false
            }
            
            if let mgr = self.manager, mgr.connection.status == .invalid {
                self.lastError = "VPN configuration invalid. Try reinstalling app."
            }
        }
    }
    
    func loadVPNConfiguration() {
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
    
    func connectVPN() {
        if let manager = manager {
            startExistingVPN(manager: manager)
        } else {
            createAndStartVPN()
        }
    }
    
    func disconnectVPN() {
        manager?.connection.stopVPNTunnel()
        lastError = nil
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
        proto.serverAddress = "FakeLagServer"
        proto.disconnectOnSleep = false
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "Fake Lag Blocker"
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
                    self.lastError = "Load after save error: \(error.localizedDescription)"
                    return
                }
                self.manager = mgr
                do {
                    try mgr.connection.startVPNTunnel()
                    self.lastError = nil
                } catch {
                    self.lastError = "Start tunnel error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    // MARK: - Bật/tắt Fake Lag (Gửi lệnh Chuyển Làn)
    func toggleBlocking() {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            lastError = "Không tìm thấy session VPN"
            return
        }
        guard isVPNConnected else {
            lastError = "VPN chưa kết nối"
            return
        }
        guard !isProcessingCommand else { return }
        
        // Cập nhật giao diện UI ngay lập tức cho mượt
        isBlocking.toggle()
        isProcessingCommand = true
        
        let command = isBlocking ? "enableBlocking" : "disableBlocking"
        
        do {
            try session.sendProviderMessage(Data(command.utf8)) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isProcessingCommand = false
                    
                    if let response = response,
                       let responseString = String(data: response, encoding: .utf8),
                       responseString == "ok" {
                        // Extension đã nhận lệnh và đang chuyển làn ngầm
                        self.lastError = nil
                    } else {
                        // Extension không phản hồi, gạt lại công tắc
                        self.isBlocking.toggle()
                        self.lastError = "Extension did not respond properly"
                    }
                }
            }
        } catch {
            // Lỗi gửi tin nhắn
            isBlocking.toggle()
            isProcessingCommand = false
            lastError = "Lỗi gửi lệnh IPC: \(error.localizedDescription)"
        }
    }
}
