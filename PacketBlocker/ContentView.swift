import SwiftUI

struct ContentView: View {
    @StateObject private var vpnManager = VPNManager.shared
    @State private var isBlocking = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Fake Lag & Traffic Blocker")
                .font(.largeTitle)
                .padding()
            
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

// ⚠️ KHÔNG được định nghĩa lại class VPNManager ở đây
// Hãy xóa toàn bộ phần code class VPNManager trong file này