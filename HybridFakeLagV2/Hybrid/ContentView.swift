import SwiftUI

struct ContentView: View {
    @StateObject private var vpn = VPNManager.shared
    @StateObject private var procMgr = ProcessManager()
    @StateObject private var hudMgr = FloatingHUDManager.shared
    @State private var showProcessSheet = false
    @State private var searchText = ""
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // Tab 1 Home
            NavigationView {
                VStack(spacing: 14) {
                    // Status Box
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: vpn.isVPNConnected ? "checkmark.shield.fill" : "shield.slash")
                                .font(.system(size: 34)).foregroundColor(vpn.isVPNConnected ? .green : .gray)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(vpn.isVPNConnected ? "VPN TUN Đang Bật" : "VPN Đã Tắt").font(.headline)
                                Text(vpn.isBlocking ? "🔴 FakeLag ON: \(vpn.mode.uppercased())" : "🟢 FakeLag OFF").font(.subheadline).foregroundColor(vpn.isBlocking ? .red : .secondary)
                                if let p = vpn.selectedProcess {
                                    Text("Target: \(p.displayName) PID:\(p.pid) TCP:\(p.tcpCount) UDP:\(p.udpCount)").font(.caption2).foregroundColor(.orange)
                                } else {
                                    Text("Target: GLOBAL (tất cả app)").font(.caption2).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding().background(Color(.systemGray6)).cornerRadius(12)
                        
                        // Floating Button Status
                        HStack {
                            Image(systemName: hudMgr.isRunning ? "circle.fill" : "circle")
                                .foregroundColor(hudMgr.isRunning ? .purple : .gray)
                            Text(hudMgr.isRunning ? "Floating Button Đang Chạy" : "Floating Button Tắt")
                                .font(.caption)
                            Spacer()
                            Button(hudMgr.isRunning ? "Remove" : "Create") {
                                hudMgr.setEnabled(!hudMgr.isRunning)
                                AppGroupStore.logAction(hudMgr.isRunning ? "HUD_REMOVE_UI" : "HUD_CREATE_UI", details: "")
                            }
                            .font(.caption).padding(6).background(Color.yellow.opacity(0.3)).cornerRadius(6)
                        }
                        .padding(8).background(Color(.systemGray5)).cornerRadius(8)
                    }.padding(.horizontal)
                    
                    // PID Selector
                    Button(action: { procMgr.scan(); showProcessSheet = true }) {
                        HStack { Image(systemName: "scope"); Text(vpn.selectedProcess == nil ? "Chọn PID Mục Tiêu" : "Đổi PID: \(vpn.selectedProcess!.displayName)"); Spacer(); Image(systemName: "chevron.right") }
                        .frame(maxWidth: .infinity).padding().background(Color(.systemGray5)).cornerRadius(10)
                    }.padding(.horizontal)
                    
                    // L4 Status Cards (like AetherNet)
                    HStack(spacing: 10) {
                        VStack { Text("TCP").font(.caption2).foregroundColor(.teal); Text("\(vpn.selectedProcess?.tcpCount ?? 0) sockets").font(.caption2) }.frame(maxWidth: .infinity).padding(8).background(Color.teal.opacity(0.15)).cornerRadius(8)
                        VStack { Text("UDP").font(.caption2).foregroundColor(.blue); Text("\(vpn.selectedProcess?.udpCount ?? 0) sockets").font(.caption2) }.frame(maxWidth: .infinity).padding(8).background(Color.blue.opacity(0.15)).cornerRadius(8)
                    }.padding(.horizontal)
                    
                    // VPN Buttons
                    Button(action: { vpn.isVPNConnected ? vpn.disconnectVPN() : vpn.connectVPN() }) {
                        HStack { Image(systemName: vpn.isVPNConnected ? "power" : "bolt.shield"); Text(vpn.isVPNConnected ? "Tắt VPN" : "Bật VPN (Fix Kill)") }
                        .font(.headline).foregroundColor(.white).frame(maxWidth: .infinity).padding().background(vpn.isVPNConnected ? Color.red : Color.blue).cornerRadius(12)
                    }.padding(.horizontal)
                    
                    Button(action: { vpn.toggleBlocking() }) {
                        HStack { Image(systemName: vpn.isBlocking ? "pause.fill" : "play.fill"); Text(vpn.isBlocking ? "Tắt FakeLag (Flush)" : "Bật FakeLag") }
                        .font(.headline).foregroundColor(.white).frame(maxWidth: .infinity).padding().background(vpn.isBlocking ? Color.orange : Color.purple).cornerRadius(12)
                    }.padding(.horizontal).disabled(!vpn.isVPNConnected)
                    
                    if let err = vpn.lastError { Text(err).font(.caption).foregroundColor(.red).padding(.horizontal) }
                    
                    Spacer()
                }
                .padding(.top)
                .navigationTitle("Home - Hybrid")
                .sheet(isPresented: $showProcessSheet) {
                    NavigationView {
                        VStack {
                            HStack {
                                TextField("Tìm PID/bundle", text: $searchText).textFieldStyle(RoundedBorderTextFieldStyle())
                                Button("Scan") { procMgr.scan(filter: searchText) }
                            }.padding()
                            List {
                                Button(action: { vpn.selectProcess(nil); showProcessSheet = false }) {
                                    HStack { Image(systemName: "globe"); Text("GLOBAL - Chặn tất cả"); Spacer(); if vpn.selectedProcess == nil { Image(systemName: "checkmark") } }
                                }
                                ForEach(procMgr.processes) { p in
                                    Button(action: { vpn.selectProcess(p); showProcessSheet = false }) {
                                        HStack {
                                            if let icon = p.icon { Image(uiImage: icon).resizable().frame(width: 24, height: 24).cornerRadius(4) }
                                            else { Image(systemName: p.isUserApp ? "app.fill" : "gear").foregroundColor(p.isUserApp ? .blue : .gray) }
                                            VStack(alignment: .leading) {
                                                Text(p.displayName).font(.subheadline)
                                                Text("\(p.bundleID) PID:\(p.pid) TCP:\(p.tcpCount) UDP:\(p.udpCount)").font(.caption2).foregroundColor(.secondary)
                                            }
                                            Spacer()
                                            if vpn.selectedProcess?.pid == p.pid { Image(systemName: "checkmark").foregroundColor(.blue) }
                                        }
                                    }
                                }
                            }
                        }
                        .navigationTitle("Chọn PID")
                        .navigationBarItems(trailing: Button("Đóng") { showProcessSheet = false })
                    }
                }
            }.tabItem { Label("Home", systemImage: "house") }.tag(0)
            
            // Tab 2 Settings
            NavigationView { SettingsView() }.tabItem { Label("Settings", systemImage: "gear") }.tag(1)
            
            // Tab 3 Logs
            NavigationView { LogsView() }.tabItem { Label("Logs", systemImage: "doc.text") }.tag(2)
        }
    }
}
