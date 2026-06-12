import SwiftUI
import NetworkExtension

struct ContentView: View {
    @State private var isVPNConnected = false
    @State private var isBlocking = false
    @State private var isLoading = false
    
    private let vpnManager = NEVPNManager.shared()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Fake Lag & Traffic Blocker")
                .font(.largeTitle)
                .padding()
            
            Button(action: {
                if isVPNConnected {
                    stopVPN()
                } else {
                    startVPN()
                }
            }) {
                Text(isVPNConnected ? "Đang kết nối VPN - TẮT" : "BẬT VPN")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isVPNConnected ? Color.green : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .disabled(isLoading)
            
            if isVPNConnected {
                Toggle(isOn: $isBlocking) {
                    Text("Chặn toàn bộ traffic (upload + download)")
                        .font(.headline)
                }
                .padding()
                .onChange(of: isBlocking) { newValue in
                    setTrafficBlocked(newValue)
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
            loadVPNConfig()
            startObserving()
        }
    }
    
    // MARK: - VPN Actions
    
    private func loadVPNConfig() {
        vpnManager.loadFromPreferences { _ in
            self.updateConnectionStatus()
        }
    }
    
    private func startVPN() {
        isLoading = true
        vpnManager.loadFromPreferences { error in
            if let error = error {
                print("Load error: \(error)")
                self.isLoading = false
                return
            }
            // Nếu chưa có cấu hình, tạo mới
            if self.vpnManager.connection.status == .invalid {
                self.createVPNConfiguration()
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
    
    private func stopVPN() {
        vpnManager.connection.stopVPNTunnel()
    }
    
    private func createVPNConfiguration() {
        let protocolConfig = NETunnelProviderProtocol()
        // 👉 THAY bundle ID NÀY BẰNG BUNDLE ID THẬT CỦA EXTENSION
        protocolConfig.providerBundleIdentifier = "com.tenban.PacketBlocker.extension"
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
    
    // MARK: - Gửi lệnh chặn traffic
    
    private func setTrafficBlocked(_ blocked: Bool) {
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
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { _ in
            self.updateConnectionStatus()
        }
    }
    
    private func updateConnectionStatus() {
        isVPNConnected = (vpnManager.connection.status == .connected)
    }
}
