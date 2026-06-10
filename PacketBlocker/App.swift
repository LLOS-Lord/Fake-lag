import SwiftUI

@main
struct PacketBlockerApp: App {
    @StateObject private var vpnManager = VPNManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vpnManager)
        }
    }
}