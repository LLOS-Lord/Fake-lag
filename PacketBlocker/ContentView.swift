import SwiftUI

struct ContentView: View {
    @StateObject private var vpnManager = VPNManager.shared

    // Binding để Toggle gọi toggleBlocking() thay vì gán trực tiếp
    private var blockingBinding: Binding<Bool> {
        Binding(
            get: { vpnManager.isBlocking },
            set: { _ in vpnManager.toggleBlocking() }
        )
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Fake Lag & Traffic Blocker")
                .font(.largeTitle)
                .padding()

            Button(action: {
                if vpnManager.isVPNConnected {
                    vpnManager.disconnectVPN()
                } else {
                    vpnManager.connectVPN()
                }
            }) {
                Text(vpnManager.isVPNConnected ? "Đang kết nối VPN - TẮT" : "BẬT VPN")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(vpnManager.isVPNConnected ? Color.green : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .disabled(vpnManager.isProcessingCommand)   // thay thế isLoading

            if vpnManager.isVPNConnected {
                Toggle(isOn: blockingBinding) {
                    Text("Chặn toàn bộ traffic (upload + download)")
                        .font(.headline)
                }
                .padding()
                .toggleStyle(SwitchToggleStyle(tint: .red))

                Text(vpnManager.isBlocking ? "🚫 Đang chặn traffic" : "✅ Traffic tự do")
                    .font(.subheadline)
                    .foregroundColor(vpnManager.isBlocking ? .red : .green)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            vpnManager.loadVPNConfiguration()
        }
    }
}