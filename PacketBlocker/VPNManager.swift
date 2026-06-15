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
    
    // ĐỊNH DANH CỰC KỲ QUAN TRỌNG: Hãy đảm bảo hậu tố là .extension
    private var extensionBundleID: String {
        let mainID = Bundle.main.bundleIdentifier ?? ""
        if mainID.isEmpty { return "com.ban.PacketBlocker.extension" }
        return "\(mainID).extension"
    }
    
    private init() {
        loadVPNConfiguration()
        setupStatusObserver()
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
            if !self.isVPNConnected { self.isBlocking = false }
        }
    }
    
    func loadVPNConfiguration() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self else { return }
            // Ưu tiên tìm manager khớp với Bundle ID hiện tại
            self.manager = managers?.first(where: { 
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.extensionBundleID 
            }) ?? managers?.first
            self.updateStatus()
        }
    }
    
    func connectVPN() {
        if let manager = manager {
            manager.isEnabled = true
            manager.saveToPreferences { [weak self] _ in
                do {
                    try manager.connection.startVPNTunnel()
                    self?.lastError = nil
                } catch {
                    self?.lastError = "Lỗi bật VPN: \(error.localizedDescription)"
                }
            }
        } else {
            createAndStartVPN()
        }
    }
    
    func disconnectVPN() {
        manager?.connection.stopVPNTunnel()
        lastError = nil
    }
    
    private func createAndStartVPN() {
        let mgr = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = extensionBundleID
        proto.serverAddress = "FakeLagSystem"
        
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "Fake Lag Controller"
        mgr.isEnabled = true
        
        mgr.saveToPreferences { [weak self] _ in
            self?.loadVPNConfiguration()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.connectVPN()
            }
        }
    }
    
    func toggleBlocking() {
        guard let session = manager?.connection as? NETunnelProviderSession, isVPNConnected else {
            self.lastError = "VPN chưa kết nối ổn định."
            return
        }
        
        if isProcessingCommand { return }
        isProcessingCommand = true
        
        let targetState = !isBlocking
        let command = targetState ? "enableBlocking" : "disableBlocking"
        
        // CƠ CHẾ GỬI LỆNH SIÊU TỐC: Không chờ Extension xử lý xong, chỉ chờ nó nhận được lệnh
        try? session.sendProviderMessage(Data(command.utf8)) { [weak self] response in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isProcessingCommand = false
                if response != nil {
                    self.isBlocking = targetState
                    self.lastError = nil
                } else {
                    self.lastError = "Extension không phản hồi. Hãy bật lại VPN."
                }
            }
        }
        
        // Timeout dự phòng: Nếu sau 2 giây không có phản hồi thì reset trạng thái
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.isProcessingCommand == true {
                self?.isProcessingCommand = false
                self?.lastError = "Extension phản hồi quá chậm."
            }
        }
    }
}
