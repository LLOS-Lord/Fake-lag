import SwiftUI
import NetworkExtension

class VPNManager: NSObject, ObservableObject {
    static let shared = VPNManager()
    
    @Published var isConnected = false
    @Published var isLoading = false
    
    private let vpnManager = NEVPNManager.shared()
    private var statusObserver: NSObjectProtocol?
    
    private override init() {
        super.init()
        startObserving()
    }
    
    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    func loadVPNConfiguration() {
        vpnManager.loadFromPreferences { [weak self] error in
            if let error = error {
                print("Load preferences error: \(error)")
                return
            }
            if self?.vpnManager.connection.status == .invalid {
                self?.createVPNConfiguration()
            } else {
                self?.updateConnectionStatus()
            }
        }
    }
    
    private func createVPNConfiguration() {
        let protocolConfig = NETunnelProviderProtocol()
        protocolConfig.providerBundleIdentifier = "com.tenban.PacketBlocker.extension"  // 👈 SỬA ĐÚNG BUNDLE ID CỦA BẠN
        protocolConfig.serverAddress = "FakeLag VPN"
        
        vpnManager.protocolConfiguration = protocolConfig
        vpnManager.isEnabled = true
        vpnManager.localizedDescription = "FakeLag Traffic Blocker"
        
        vpnManager.saveToPreferences { error in
            if let error = error {
                print("Save VPN config error: \(error)")
            }
        }
    }
    
    func startVPN() {
        isLoading = true
        vpnManager.loadFromPreferences { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                print("Load error: \(error)")
                self.isLoading = false
                return
            }
            do {
                try self.vpnManager.connection.startVPNTunnel()
                self.isLoading = false
            } catch {
                print("Start VPN error: \(error)")
                self.isLoading = false
            }
        }
    }
    
    func stopVPN() {
        vpnManager.connection.stopVPNTunnel()
    }
    
    func setTrafficBlocked(_ blocked: Bool) {
        guard let session = vpnManager.connection as? NETunnelProviderSession else {
            print("Cannot get NETunnelProviderSession")
            return
        }
        let message = "toggleBlock:\(blocked)".data(using: .utf8)!
        do {
            try session.sendProviderMessage(message) { response in
                if let response = response, let str = String(data: response, encoding: .utf8) {
                    print("Provider response: \(str)")
                }
            }
        } catch {
            print("Send message error: \(error)")
        }
    }
    
    private func startObserving() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateConnectionStatus()
        }
    }
    
    private func updateConnectionStatus() {
        switch vpnManager.connection.status {
        case .connected:
            isConnected = true
        case .disconnected, .invalid, .disconnecting:
            isConnected = false
        default:
            break
        }
    }
}