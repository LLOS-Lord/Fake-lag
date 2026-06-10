import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vpnManager: VPNManager
    
    var body: some View {
        VStack(spacing: 30) {
            // Icon và trạng thái
            VStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 80))
                    .foregroundColor(iconColor)
                    .animation(.easeInOut, value: vpnManager.isVPNConnected)
                    .animation(.easeInOut, value: vpnManager.isBlocking)
                
                Text(statusText)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)
            
            // Nút điều khiển
            VStack(spacing: 16) {
                if !vpnManager.isVPNConnected {
                    Button(action: {
                        vpnManager.connectVPN()
                    }) {
                        HStack {
                            Image(systemName: "power")
                            Text("Connect VPN")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .cornerRadius(12)
                    }
                } else {
                    // Nút bật/tắt chặn
                    Button(action: {
                        vpnManager.toggleBlocking()
                    }) {
                        HStack {
                            Image(systemName: vpnManager.isBlocking ? "play.fill" : "stop.fill")
                            Text(vpnManager.isBlocking ? "Allow Traffic" : "Block All Traffic")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(vpnManager.isBlocking ? Color.green : Color.red)
                        .cornerRadius(12)
                    }
                    .disabled(vpnManager.isProcessingCommand)
                    
                    Button(action: {
                        vpnManager.disconnectVPN()
                    }) {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text("Disconnect VPN")
                        }
                        .font(.subheadline)
                        .foregroundColor(.red)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 40)
            
            // Hiển thị lỗi (nếu có)
            if let error = vpnManager.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            if vpnManager.isProcessingCommand {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Processing...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Text("PacketBlocker v1.0 (TrollStore)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
        }
        .padding()
        .background(Color(.systemBackground))
    }
    
    private var iconName: String {
        if !vpnManager.isVPNConnected { return "lock.open" }
        return vpnManager.isBlocking ? "lock.shield.fill" : "lock.shield"
    }
    
    private var iconColor: Color {
        if !vpnManager.isVPNConnected { return .gray }
        return vpnManager.isBlocking ? .red : .green
    }
    
    private var statusText: String {
        if !vpnManager.isVPNConnected { return "VPN Disconnected" }
        if vpnManager.isProcessingCommand { return "Applying..." }
        return vpnManager.isBlocking ? "🚫 All Traffic Blocked" : "✅ VPN Connected\nTraffic Allowed"
    }
}