import SwiftUI

struct ContentView: View {
    @StateObject private var vpnManager = VPNManager()
    
    var body: some View {
        VStack(spacing: 40) {
            Image(systemName: "shield.lefthalf.fill")
                .font(.system(size: 100))
                .foregroundColor(vpnManager.isVPNConnected ? .green : .gray)
            
            Text(vpnManager.isVPNConnected ? "VPN Connected" : "VPN Disconnected")
                .font(.largeTitle)
                .bold()
            
            if vpnManager.isVPNConnected {
                Button {
                    vpnManager.toggleBlocking()
                } label: {
                    Text("Block All Traffic")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal)
            }
            
            Button {
                if vpnManager.isVPNConnected {
                    vpnManager.disconnectVPN()
                } else {
                    vpnManager.connectVPN()
                }
            } label: {
                Text(vpnManager.isVPNConnected ? "Disconnect VPN" : "Connect VPN")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(vpnManager.isVPNConnected ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal)
            
            if let error = vpnManager.lastError {
                Text(error)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}