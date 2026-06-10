import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vpnManager: VPNManager
    
    var body: some View {
        VStack(spacing: 30) {
            // Header
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
                    .animation(.default, value: statusText)
            }
            .padding(.top, 40)
            
            // Controls
            VStack(spacing: 16) {
                if !vpnManager.isVPNConnected {
                    // Connect VPN button
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
                    // Blocking toggle button
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
                    
                    // Disconnect VPN button
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
            
            // Status indicator
            if vpnManager.isProcessingCommand {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Processing...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)
            }
            
            Spacer()
            
            // Footer info
            VStack(spacing: 4) {
                Text("PacketBlocker v1.0")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("TrollStore Edition")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 20)
        }
        .padding()
        .background(Color(.systemBackground))
    }
    
    // MARK: - Computed properties for UI state
    
    private var iconName: String {
        if !vpnManager.isVPNConnected {
            return "lock.open"
        } else if vpnManager.isBlocking {
            return "lock.shield.fill"
        } else {
            return "lock.shield"
        }
    }
    
    private var iconColor: Color {
        if !vpnManager.isVPNConnected {
            return .gray
        } else if vpnManager.isBlocking {
            return .red
        } else {
            return .green
        }
    }
    
    private var statusText: String {
        if !vpnManager.isVPNConnected {
            return "VPN Disconnected"
        } else if vpnManager.isProcessingCommand {
            return "Applying..."
        } else if vpnManager.isBlocking {
            return "🚫 All Traffic Blocked"
        } else {
            return "✅ VPN Connected\nTraffic Allowed"
        }
    }
}