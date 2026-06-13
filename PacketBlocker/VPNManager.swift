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
    
    // ⚠️ QUAN TRỌNG: Đảm bảo Bundle ID này khớp chuẩn với Target Extension
    private let extensionBundleID = "com.ban.PacketBlocker.extension"
    
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
            
            if wasConnected && !self.isVPNConnected && !self.isProcessingCommand {
                // Nếu tự nhiên mất kết nối mà không phải do mình đang đổi cấu hình ngầm
                self.isBlocking = false
            }
            
            if let mgr = self.manager, mgr.connection.status == .invalid {
                self.lastError = "VPN configuration invalid. Hãy cài lại ứng dụng."
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
            
            // Đọc lại trạng thái isBlocking từ cấu hình hiện tại để đồng bộ UI
            if let proto = self.manager?.protocolConfiguration as? NETunnelProviderProtocol,
               let config = proto.providerConfiguration,
               let savedBlocking = config["isBlocking"] as? Bool {
                self.isBlocking = savedBlocking
            }
            
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
        proto.serverAddress = "FakeLagSystem"
        proto.disconnectOnSleep = false
        
        // Mặc định lúc mới tạo là Làn 1 (không chặn)
        proto.providerConfiguration = ["isBlocking": false]
        
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "Fake Lag Controller"
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
                    self.lastError = nil
                } catch {
                    self.lastError = "Start tunnel error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    // MARK: - Chuyển Làn Mạng (Ngắt -> Đổi Cấu Hình -> Bật Lại)
    func toggleBlocking() {
        guard let mgr = manager else { return }
        guard !isProcessingCommand else { return }
        
        // Thay đổi UI ngay lập tức để tạo cảm giác mượt mà
        isBlocking.toggle()
        isProcessingCommand = true
        self.lastError = nil
        
        // Bước 1: Tạm ngắt kết nối
        if isVPNConnected {
            mgr.connection.stopVPNTunnel()
        }
        
        // Bước 2: Chờ 0.5 giây cho iOS đóng đường hầm sạch sẽ, sau đó cập nhật và bật lại
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            
            // Ghi đè trạng thái chặn mới vào giấy phép
            if let proto = mgr.protocolConfiguration as? NETunnelProviderProtocol {
                var config = proto.providerConfiguration ?? [:]
                config["isBlocking"] = self.isBlocking
                proto.providerConfiguration = config
                mgr.protocolConfiguration = proto
            }
            
            // Lưu lại vào hệ thống iOS
            mgr.saveToPreferences { error in
                if let error = error {
                    self.lastError = "Lỗi lưu cấu hình mới: \(error.localizedDescription)"
                    self.revertState()
                    return
                }
                
                // Load lại giấy phép vừa lưu và khởi động
                mgr.loadFromPreferences { error in
                    if let error = error {
                        self.lastError = "Lỗi load cấu hình mới: \(error.localizedDescription)"
                        self.revertState()
                        return
                    }
                    
                    do {
                        try mgr.connection.startVPNTunnel()
                        self.lastError = nil
                        self.isProcessingCommand = false
                    } catch {
                        self.lastError = "Không thể khởi động lại Làn mới: \(error.localizedDescription)"
                        self.revertState()
                    }
                }
            }
        }
    }
    
    // Khôi phục UI nếu quá trình chuyển làn thất bại
    private func revertState() {
        DispatchQueue.main.async {
            self.isBlocking.toggle()
            self.isProcessingCommand = false
        }
    }
}
