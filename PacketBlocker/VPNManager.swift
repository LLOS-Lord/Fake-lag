import NetworkExtension
import SwiftUI

class VPNManager: ObservableObject {
    static let shared = VPNManager()

    @Published var isVPNConnected = false
    @Published var isBlocking = false
    @Published var isBlockNetworkSimulate = false
    @Published var isProcessingCommand = false
    @Published var lastError: String?
    
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    
    // ⚠️ QUAN TRỌNG: Đảm bảo Bundle ID này khớp chuẩn với Target Extension
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
               let config = proto.providerConfiguration {
                if let savedBlocking = config["isBlocking"] as? Bool {
                    self.isBlocking = savedBlocking
                }
                if let savedBlockSim = config["isBlockNetworkSimulate"] as? Bool {
                    self.isBlockNetworkSimulate = savedBlockSim
                }
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
        proto.providerConfiguration = [
            "isBlocking": false,
            "isBlockNetworkSimulate": false
        ]
        
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
    
    func toggleBlockNetworkSimulate() {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            lastError = "Không tìm thấy session VPN"
            return
        }
        guard isVPNConnected && !isProcessingCommand else { return }
        
        isBlockNetworkSimulate.toggle()
        isProcessingCommand = true
        self.lastError = nil
        
        let command = isBlockNetworkSimulate ? "enableBlockSim" : "disableBlockSim"
        
        do {
            try session.sendProviderMessage(Data(command.utf8)) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isProcessingCommand = false
                    
                    if let res = response, String(data: res, encoding: .utf8) == "ok" {
                        self.lastError = nil
                    } else {
                        self.isBlockNetworkSimulate.toggle()
                        self.lastError = "Extension did not respond properly"
                    }
                }
            }
        } catch {
            self.isBlockNetworkSimulate.toggle()
            self.isProcessingCommand = false
            self.lastError = "Lỗi gửi lệnh: \(error.localizedDescription)"
        }
    }

    // MARK: - Chuyển Làn Ngầm (Gửi lệnh IPC, Không ngắt kết nối VPN)
    func toggleBlocking() {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            lastError = "Không tìm thấy session VPN"
            return
        }
        guard isVPNConnected && !isProcessingCommand else { return }
        
        // Thay đổi UI ngay lập tức để tạo cảm giác mượt mà
        isBlocking.toggle()
        isProcessingCommand = true
        self.lastError = nil
        
        let command = isBlocking ? "enableBlocking" : "disableBlocking"
        
        do {
            try session.sendProviderMessage(Data(command.utf8)) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isProcessingCommand = false
                    
                    if let res = response, String(data: res, encoding: .utf8) == "ok" {
                        // Extension đã nhận lệnh và đổi làn thành công ngầm bên dưới
                        self.lastError = nil
                    } else {
                        // Extension không phản hồi (có thể bị crash do RAM hoặc lỗi khác), gạt lại công tắc
                        self.isBlocking.toggle()
                        self.lastError = "Extension did not respond properly"
                    }
                }
            }
        } catch {
            // Lỗi gửi lệnh
            self.isBlocking.toggle()
            self.isProcessingCommand = false
            self.lastError = "Lỗi gửi lệnh: \(error.localizedDescription)"
        }
    }
}
