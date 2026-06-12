import SwiftUI
import NetworkExtension

struct ContentView: View {
    @StateObject private var vpnManager = VPNManager.shared
    @State private var isBlocking = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Fake Lag & Traffic Blocker")
                .font(.largeTitle)
                .padding()
            
            // Nút bật/tắt VPN
            Button(action: {
                if vpnManager.isConnected {
                    vpnManager.stopVPN()
                } else {
                    vpnManager.startVPN()
                }
            }) {
                Text(vpnManager.isConnected ? "Đang kết nối VPN - TẮT" : "BẬT VPN")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(vpnManager.isConnected ? Color.green : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .disabled(vpnManager.isLoading)
            
            // Toggle chặn traffic (chỉ hiện khi VPN đã kết nối)
            if vpnManager.isConnected {
                Toggle(isOn: $isBlocking) {
                    Text("Chặn toàn bộ traffic (upload + download)")
                        .font(.headline)
                }
                .padding()
                .onChange(of: isBlocking) { newValue in
                    vpnManager.setTrafficBlocked(newValue)
                }
                .toggleStyle(SwitchToggleStyle(tint: .red))
                
                Text(isBlocking ? "🚫 Đang chặn traffic" : "✅ Traffic tự do")
                    .font(.subheadline)
                    .foregroundColor(isBlocking ? .red : .green)
            }
            
            Spacer()
        }
        .padding()
        .onAppear {
            vpnManager.loadVPNConfiguration()
        }
    }
}

// MARK: - VPN Manager (quản lý cấu hình và kết nối)
class VPNManager: NSObject, ObservableObject {
    static let shared = VPNManager()
    
    @Published var isConnected = false
    @Published var isLoading = false
    
    private let vpnManager = NEVPNManager.shared()
    private var statusObserver: NSObjectProtocol?
    
    override private init() {
        super.init()
        startObserving()
    }
    
    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Cấu hình VPN (chỉ chạy 1 lần)
    func loadVPNConfiguration() {
        vpnManager.loadFromPreferences { [weak self] error in
            if let error = error {
                print("Load preferences error: \(error)")
                return
            }
            // Nếu chưa có cấu hình, tạo mới
            if self?.vpnManager.connection.status == .invalid {
                self?.createVPNConfiguration()
            } else {
                self?.updateConnectionStatus()
            }
        }
    }
    
    private func createVPNConfiguration() {
        let manager = NEVPNManager.shared()
        let protocolConfig = NETunnelProviderProtocol()
        protocolConfig.providerBundleIdentifier = "com.yourapp.PacketTunnelProvider" // Thay bằng bundle ID của extension
        protocolConfig.serverAddress = "FakeLag VPN"
        protocolConfig.username = nil
        
        manager.protocolConfiguration = protocolConfig
        manager.isEnabled = true
        manager.localizedDescription = "FakeLag Traffic Blocker"
        
        manager.saveToPreferences { error in
            if let error = error {
                print("Save VPN config error: \(error)")
            } else {
                print("VPN config saved successfully")
            }
        }
    }
    
    // MARK: - Điều khiển VPN
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
    
    // MARK: - Gửi lệnh chặn traffic tới PacketTunnelProvider
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
    
    // MARK: - Theo dõi trạng thái VPN
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
