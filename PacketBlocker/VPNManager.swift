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
    
    // Tự động lấy Bundle ID của App chính và thêm hậu tố .extension
    private var extensionBundleID: String {
        let mainID = Bundle.main.bundleIdentifier ?? "com.ban.PacketBlocker"
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
            self.isVPNConnected = self.manager?.connection.status == .connected
            
            if !self.isVPNConnected {
                self.isBlocking = false
            }
            
            if let mgr = self.manager, mgr.connection.status == .invalid {
                self.lastError = "Cấu hình VPN không hợp lệ."
            }
        }
    }
    
    func loadVPNConfiguration() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.lastError = "Lỗi tải cấu hình: \(error.localizedDescription)"
                return
            }
            // Tìm đúng manager dựa trên Bundle ID của extension
            self.manager = managers?.first(where: { 
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.extensionBundleID 
            }) ?? managers?.first
            
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
        manager.isEnabled = true
        manager.saveToPreferences { [weak self] error in
            if let error = error {
                self?.lastError = "Lỗi lưu cấu hình: \(error.localizedDescription)"
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
    
    private func createAndStartVPN() {
        let mgr = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = extensionBundleID
        proto.serverAddress = "FakeLagSystem"
        proto.disconnectOnSleep = false
        
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "Fake Lag Controller"
        mgr.isEnabled = true
        
        mgr.saveToPreferences { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.lastError = "Lỗi tạo cấu hình: \(error.localizedDescription)"
                return
            }
            self.loadVPNConfiguration()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.connectVPN()
            }
        }
    }
    
    func toggleBlocking() {
        guard let session = manager?.connection as? NETunnelProviderSession, isVPNConnected else {
            self.lastError = "VPN chưa kết nối hoặc không tìm thấy session"
            return
        }
        
        if isProcessingCommand { return }
        
        isProcessingCommand = true
        let targetState = !isBlocking
        let command = targetState ? "enableBlocking" : "disableBlocking"
        
        do {
            try session.sendProviderMessage(Data(command.utf8)) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isProcessingCommand = false
                    
                    if let res = response, String(data: res, encoding: .utf8) == "ok" {
                        self.isBlocking = targetState
                        self.lastError = nil
                    } else {
                        self.lastError = "Extension không phản hồi. Hãy thử bật lại VPN."
                    }
                }
            }
        } catch {
            self.isProcessingCommand = false
            self.lastError = "Lỗi gửi lệnh: \(error.localizedDescription)"
        }
    }
}
