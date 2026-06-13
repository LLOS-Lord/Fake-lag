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
        VStack(spacing: 25) {
            
            // MARK: - Tiêu đề
            VStack(spacing: 8) {
                Text("Fake Lag Controller")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Routing Switcher (Cơ chế 2 Làn Ảo)")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
            .padding(.top, 20)

            // MARK: - Nút Khởi động Hệ thống (VPN)
            Button(action: {
                if vpnManager.isVPNConnected {
                    vpnManager.disconnectVPN()
                } else {
                    vpnManager.connectVPN()
                }
            }) {
                HStack {
                    Image(systemName: vpnManager.isVPNConnected ? "shield.fill" : "shield.slash")
                    Text(vpnManager.isVPNConnected ? "TẮT HỆ THỐNG NỀN" : "BẬT HỆ THỐNG")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                // Nút chuyển đỏ khi đang chạy để cảnh báo, xanh khi chưa bật
                .background(vpnManager.isVPNConnected ? Color.red.opacity(0.8) : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
                .shadow(radius: 3)
            }
            .disabled(vpnManager.isProcessingCommand)
            .padding(.horizontal)

            // MARK: - Khu vực điều khiển Chuyển Làn (Chỉ hiện khi hệ thống nền đã bật)
            if vpnManager.isVPNConnected {
                VStack(spacing: 15) {
                    
                    // Công tắc Fake Lag
                    Toggle(isOn: blockingBinding) {
                        Text("Công tắc Fake Lag")
                            .font(.headline)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .orange))
                    .padding(.horizontal)

                    // Hiển thị trạng thái Làn đường trực quan
                    HStack {
                        Image(systemName: vpnManager.isBlocking ? "exclamationmark.triangle.fill" : "network")
                        Text(vpnManager.isBlocking ? "LÀN 2: Blackhole (Đang nuốt data)" : "LÀN 1: Mạng đi tự do")
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(vpnManager.isBlocking ? .orange : .green)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(vpnManager.isBlocking ? Color.orange.opacity(0.15) : Color.green.opacity(0.15))
                    )
                    .padding(.horizontal)
                }
                .padding(.top, 10)
            }

            // MARK: - Khu vực Loading & Báo lỗi
            VStack(spacing: 12) {
                // Đang xử lý chuyển làn IPC
                if vpnManager.isProcessingCommand {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.9)
                        Text("⏳ Đang chuyển làn ngầm...")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }
                }

                // Hiển thị lỗi nếu bị văng
                if let error = vpnManager.lastError {
                    HStack(alignment: .top) {
                        Image(systemName: "xmark.octagon.fill")
                        Text("Lỗi: \(error)")
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.leading)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .transition(.opacity)
                }
            }
            .padding(.top, 10)

            Spacer()
        }
        .onAppear {
            vpnManager.loadVPNConfiguration()
        }
    }
}
