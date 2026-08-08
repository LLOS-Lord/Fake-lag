import SwiftUI

struct ContentView: View {
    @StateObject private var vpn = VPNManager.shared

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Status Card
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: vpn.isVPNConnected ? "checkmark.shield.fill" : "shield.slash")
                            .font(.system(size: 40))
                            .foregroundColor(vpn.isVPNConnected ? .green : .gray)

                        VStack(alignment: .leading) {
                            Text(vpn.isVPNConnected ? "VPN Dang Bat" : "VPN Da Tat")
                                .font(.headline)
                            Text(vpn.isBlocking ? "Fake Lag: ON" : "Fake Lag: OFF")
                                .font(.subheadline)
                                .foregroundColor(vpn.isBlocking ? .red : .secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }
                .padding(.horizontal)

                // VPN Toggle
                Button(action: {
                    if vpn.isVPNConnected {
                        vpn.disconnectVPN()
                    } else {
                        vpn.connectVPN()
                    }
                }) {
                    HStack {
                        Image(systemName: vpn.isVPNConnected ? "power" : "power.circle")
                        Text(vpn.isVPNConnected ? "Tat VPN" : "Bat VPN")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(vpn.isVPNConnected ? Color.red : Color.blue)
                    .cornerRadius(12)
                }
                .padding(.horizontal)
                .disabled(vpn.isProcessingCommand)

                // Fake Lag Toggle
                Button(action: {
                    vpn.toggleBlocking()
                }) {
                    HStack {
                        Image(systemName: vpn.isBlocking ? "bolt.slash.fill" : "bolt.fill")
                        Text(vpn.isBlocking ? "Tat Fake Lag" : "Bat Fake Lag")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(vpn.isBlocking ? Color.orange : Color.purple)
                    .cornerRadius(12)
                }
                .padding(.horizontal)
                .disabled(!vpn.isVPNConnected || vpn.isProcessingCommand)

                // Error
                if let error = vpn.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Instructions
                VStack(alignment: .leading, spacing: 8) {
                    Text("Huong dan:").font(.headline)
                    Text("1. Bat VPN -> mang binh thuong")
                    Text("2. Vao Free Fire, vao tran")
                    Text("3. Bat Fake Lag -> delay + drop")
                    Text("4. Tat Fake Lag -> mang binh thuong")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Fake Lag")
        }
    }
}
