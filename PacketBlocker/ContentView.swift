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

            // Nút bật/tắt VPN
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
            .disabled(vpnManager.isProcessingCommand)

            // Chỉ hiển thị toggle khi VPN đã kết nối
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

            // Debug: hiển thị nếu đang xử lý lệnh
            if vpnManager.isProcessingCommand {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("⏳ Đang gửi lệnh đến Extension...")
                        .font(.caption)
                        .foregroundColor(.yellow)
                }
            }

            // Debug: hiển thị lỗi nếu có
            if let error = vpnManager.lastError {
                Text("Lỗi: \(error)")
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .transition(.opacity)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            vpnManager.loadVPNConfiguration()
        }
    }
}