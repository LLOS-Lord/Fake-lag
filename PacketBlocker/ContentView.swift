import SwiftUI
struct ContentView: View {
    @StateObject private var vpn = VPNManager.shared
    @StateObject private var hud = FloatingHUDManager.shared
    @StateObject private var procMgr = ProcessManager()
    @StateObject private var payload = PayloadManager.shared
    @State private var showSheet = false
    @State private var search = ""
    @State private var statsTimer: Timer?
    var body: some View {
        TabView {
            NavigationView {
                VStack(spacing:12){
                    HStack{
                        Image(systemName: vpn.isVPNConnected ? "checkmark.shield.fill" : "shield.slash").font(.system(size:30)).foregroundColor(vpn.isVPNConnected ? .green : .gray)
                        VStack(alignment:.leading){
                            Text(vpn.isVPNConnected ? "VPN ON (Fixed)" : "VPN OFF").font(.headline)
                            Text(vpn.isBlocking ? "FakeLag ON \(vpn.mode)" : "FakeLag OFF").font(.subheadline)
                        }
                        Spacer()
                    }.padding().background(Color(.systemGray6)).cornerRadius(12)
                    Button(action:{ procMgr.scan(); showSheet=true }){
                        HStack{Image(systemName:"scope"); Text(vpn.selectedProcess == nil ? "Chọn PID (GLOBAL)" : "PID: \(vpn.selectedProcess!.displayName)"); Spacer(); Image(systemName:"chevron.right")}
                    }.padding(.horizontal)
                    Button(action:{ payload.attach(to: vpn.selectedProcess, config: vpn) }){
                        HStack{Image(systemName:"cross.case.fill"); Text(payload.isAttached ? "Re-attach payload" : "Inject payload vào PID")}
                        .frame(maxWidth:.infinity).padding().background(payload.isAttached ? Color.green.opacity(0.35) : Color.blue.opacity(0.35)).cornerRadius(12)
                    }.padding(.horizontal).disabled(vpn.selectedProcess == nil)
                    if !payload.status.isEmpty {
                        VStack(alignment:.leading, spacing:2){
                            Text(payload.status).font(.caption).foregroundColor(payload.status.hasPrefix("LỖI") ? .red : .secondary)
                            Text(payload.summary).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                            if !payload.detail.isEmpty {
                                Text(payload.detail).font(.system(size:9, design: .monospaced)).foregroundColor(.secondary).lineLimit(3)
                            }
                        }.frame(maxWidth:.infinity, alignment:.leading).padding(.horizontal)
                    }
                    Picker("Mode", selection: $vpn.mode){ Text("Hold").tag("hold"); Text("Drop").tag("drop"); Text("Delay").tag("delay") }.pickerStyle(SegmentedPickerStyle()).onChange(of: vpn.mode){_ in vpn.saveConfig()}.padding(.horizontal)
                    Button(action:{ vpn.isVPNConnected ? vpn.disconnectVPN() : vpn.connectVPN()}){
                        HStack{Image(systemName: vpn.isVPNConnected ? "power" : "bolt.shield"); Text(vpn.isVPNConnected ? "Tắt VPN" : "Bật VPN Fix Kill")}
                        .frame(maxWidth:.infinity).padding().background(vpn.isVPNConnected ? Color.red : Color.blue).cornerRadius(12).foregroundColor(.white)
                    }.padding(.horizontal)
                    Button(action:{ vpn.toggleBlocking()}){
                        HStack{Image(systemName: vpn.isBlocking ? "pause.fill" : "play.fill"); Text(vpn.isBlocking ? "Tắt FakeLag" : "Bật FakeLag")}
                        .frame(maxWidth:.infinity).padding().background(vpn.isBlocking ? Color.orange : Color.purple).cornerRadius(12).foregroundColor(.white)
                    }.padding(.horizontal).disabled(!vpn.isVPNConnected)
                    if !vpn.lastStats.isEmpty {
                        Text(vpn.lastStats).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary).padding(.horizontal)
                    }
                    Button(action:{ hud.setEnabled(!hud.isRunning)}){
                        HStack{Image(systemName: hud.isRunning ? "xmark.circle" : "plus.circle"); Text(hud.isRunning ? "Remove Floating Button" : "Create Floating Button (TrollNet style)")}
                        .frame(maxWidth:.infinity).padding().background(Color.yellow.opacity(0.3)).cornerRadius(12)
                    }.padding(.horizontal)
                    Spacer()
                }.navigationTitle("Hybrid V2").sheet(isPresented:$showSheet){
                    NavigationView{
                        VStack{
                            HStack{ TextField("Tìm PID", text:$search).textFieldStyle(RoundedBorderTextFieldStyle()); Button("Scan"){ procMgr.scan(filter:search)} }.padding()
                            List{
                                Button(action:{ vpn.selectProcess(nil); showSheet=false}){ HStack{Image(systemName:"globe"); Text("GLOBAL"); Spacer(); if vpn.selectedProcess==nil{Image(systemName:"checkmark")}} }
                                ForEach(procMgr.processes){ p in
                                    Button(action:{ vpn.selectProcess(p); showSheet=false}){
                                        HStack{VStack(alignment:.leading){Text(p.displayName).font(.subheadline); Text("PID:\(p.pid) TCP:\(p.tcpCount) UDP:\(p.udpCount)").font(.caption2)}; Spacer(); if vpn.selectedProcess?.pid==p.pid{Image(systemName:"checkmark")}}
                                    }
                                }
                            }
                        }.navigationTitle("Chọn PID")
                    }
                }
                .onAppear {
                    // Poll tunnel stats while Home is visible (VPN connected only).
                    statsTimer?.invalidate()
                    statsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                        if vpn.isVPNConnected { vpn.refreshStats() }
                    }
                    if payload.isAttached { payload.push(config: vpn) }
                }
                .onChange(of: vpn.isBlocking)   { _ in payload.push(config: vpn) }
                .onChange(of: vpn.mode)         { _ in payload.push(config: vpn) }
                .onChange(of: vpn.direction)    { _ in payload.push(config: vpn) }
                .onChange(of: vpn.protoFilter)  { _ in payload.push(config: vpn) }
                .onChange(of: vpn.selectedProcess?.pid) { _ in
                    if payload.isAttached { payload.detach() }
                }
                .onDisappear { statsTimer?.invalidate(); statsTimer = nil }
            }.tabItem{Label("Home", systemImage:"house")}
            NavigationView{ SettingsView() }.tabItem{Label("Settings", systemImage:"gear")}
            NavigationView{ LogsView() }.tabItem{Label("Logs", systemImage:"doc.text")}
        }
    }
}
