import SwiftUI

struct ContentView: View {
    @StateObject private var vpnManager = VPNManager.shared

    private var blockingBinding: Binding<Bool> {
        Binding(
            get: { vpnManager.isBlocking },
            set: { _ in vpnManager.toggleBlocking() }
        )
    }

    private var blockSimBinding: Binding<Bool> {
        Binding(
            get: { vpnManager.isBlockNetworkSimulate },
            set: { _ in vpnManager.toggleBlockNetworkSimulate() }
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

            // MARK: - Nút Khởi động Hệ thống
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
                .background(vpnManager.isVPNConnected ? Color.red.opacity(0.8) : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
                .shadow(radius: 3)
            }
            .disabled(vpnManager.isProcessingCommand)
            .padding(.horizontal)

            // MARK: - Khu vực điều khiển Chuyển Làn
            if vpnManager.isVPNConnected || vpnManager.isProcessingCommand {
                VStack(spacing: 15) {
                    
                    Toggle(isOn: blockingBinding) {
                        Text("Công tắc Fake Lag")
                            .font(.headline)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .orange))
                    .disabled(vpnManager.isProcessingCommand)
                    .padding(.horizontal)

                    HStack {
                        Image(systemName: vpnManager.isBlocking ? "exclamationmark.triangle.fill" : "network")
                        Text(vpnManager.isBlocking ? "LÀN 2: Blackhole (Đang lag)" : "LÀN 1: Mạng đi tự do")
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

                    Divider().padding(.horizontal)

                    Toggle(isOn: blockSimBinding) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Chặn Network Simulate")
                                .font(.headline)
                            Text("/var/mobile/Library/Preferences/com.apple.network.prefPaneSimulate")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .red))
                    .disabled(vpnManager.isProcessingCommand)
                    .padding(.horizontal)
                }
                .padding(.top, 10)
            }

            // MARK: - Khu vực Loading & Báo lỗi
            VStack(spacing: 12) {
                if vpnManager.isProcessingCommand {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.9)
                        Text("⏳ Đang thiết lập làn mạng mới...")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }
                }

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
