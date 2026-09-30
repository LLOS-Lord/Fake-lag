import SwiftUI

struct SettingsView: View {
    @StateObject private var vpn = VPNManager.shared
    @State private var cfg = AppGroupStore.load()
    
    var body: some View {
        Form {
            Section(header: Text("Interception Rules - Tuỳ chỉnh chặn")) {
                Picker("Hướng chặn", selection: $vpn.direction) {
                    Text("Both").tag("both")
                    Text("Download RX only").tag("download")
                    Text("Upload TX only").tag("upload")
                }.onChange(of: vpn.direction) { _ in vpn.saveConfig() }
                
                Picker("Protocol", selection: $vpn.protoFilter) {
                    Text("TCP+UDP").tag("both")
                    Text("UDP only").tag("udp")
                    Text("TCP only").tag("tcp")
                }.onChange(of: vpn.protoFilter) { _ in vpn.saveConfig() }
                
                Picker("Mode", selection: $vpn.mode) {
                    Text("Hold (Freeze/Ghost)").tag("hold")
                    Text("Drop (Loss)").tag("drop")
                    Text("Delay + Jitter").tag("delay")
                }.onChange(of: vpn.mode) { _ in vpn.saveConfig() }
                
                VStack(alignment: .leading) {
                    Text("Capture Ratio: \(vpn.captureRatio)%")
                    Slider(value: Binding(get: { Double(vpn.captureRatio) }, set: { vpn.captureRatio = Int($0); vpn.saveConfig() }), in: 0...100, step: 5)
                }
            }
            
            Section(header: Text("Network Simulation")) {
                VStack(alignment: .leading) {
                    Text("Latency RTT: \(vpn.latencyMs) ms")
                    Slider(value: Binding(get: { Double(vpn.latencyMs) }, set: { vpn.latencyMs = Int($0); vpn.saveConfig() }), in: 0...1500, step: 50)
                }
                VStack(alignment: .leading) {
                    Text("Jitter: \(vpn.jitterMs) ms")
                    Slider(value: Binding(get: { Double(vpn.jitterMs) }, set: { vpn.jitterMs = Int($0); vpn.saveConfig() }), in: 0...500, step: 10)
                }
                VStack(alignment: .leading) {
                    Text("Bandwidth Cap: \(vpn.bandwidthKbps == 0 ? "Unlimited" : "\(vpn.bandwidthKbps) kbps")")
                    Slider(value: Binding(get: { Double(vpn.bandwidthKbps) }, set: { vpn.bandwidthKbps = Int($0); vpn.saveConfig() }), in: 0...20000, step: 500)
                }
                HStack {
                    Text("Preset")
                    Spacer()
                    Menu(cfg.preset) {
                        Button("Normal") { applyPreset(.normal) }
                        Button("Ghost Freeze (98% Upload Hold)") { applyPreset(.ghost) }
                        Button("Lag Spike 450ms") { applyPreset(.lagSpike) }
                        Button("Degraded 3G 280ms 128kbps") { applyPreset(.degraded3G) }
                        Button("TCP RST Aggressive") { applyPreset(.tcpRst) }
                    }
                }
            }
            
            Section(header: Text("Floating Button - Giống TrollNetInterceptor")) {
                VStack(alignment: .leading) {
                    Text("Diameter: \(Int(cfg.floatingSize)) pt (40-88)")
                    Slider(value: Binding(get: { Double(cfg.floatingSize) }, set: { cfg.floatingSize = Float($0); saveFloating() }), in: 40...88, step: 2)
                }
                VStack(alignment: .leading) {
                    Text("Opacity: \(Int(cfg.floatingOpacity*100))%")
                    Slider(value: Binding(get: { Double(cfg.floatingOpacity) }, set: { cfg.floatingOpacity = Float($0); saveFloating() }), in: 0.35...1.0, step: 0.05)
                }
                Toggle("Edge Snap (hút mép)", isOn: Binding(get: { cfg.floatingEdgeSnap }, set: { cfg.floatingEdgeSnap = $0; saveFloating() }))
                Toggle("Lock Position", isOn: Binding(get: { cfg.floatingLockPosition }, set: { cfg.floatingLockPosition = $0; saveFloating() }))
                Toggle("Haptics", isOn: Binding(get: { cfg.floatingHaptic }, set: { cfg.floatingHaptic = $0; saveFloating() }))
            }

            Section(header: Text("Hold Safety")) {
                VStack(alignment: .leading) {
                    Text("Auto Flush Hold: \(cfg.autoFlushSeconds == 0 ? "Tắt (giữ tới khi nhả tay)" : "\(cfg.autoFlushSeconds)s")")
                    Slider(value: Binding(get: { Double(cfg.autoFlushSeconds) }, set: { cfg.autoFlushSeconds = Int($0); saveAutoFlush() }), in: 0...30, step: 1)
                }
            }
            
            Section(header: Text("Logs & Debug")) {
                Button("Clear Logs") { AppGroupStore.clearLogs() }
                Button("Export Logs to Documents") { exportLogs() }
            }
        }
        .navigationTitle("Settings - Tuỳ chỉnh")
        .onAppear { cfg = AppGroupStore.load() }
    }
    
    enum Preset { case normal, ghost, lagSpike, degraded3G, tcpRst }
    
    func applyPreset(_ p: Preset) {
        var c = AppGroupStore.load()
        switch p {
        case .normal:
            c.mode = "hold"; c.captureRatio = 0; c.downloadRatio = 0; c.uploadRatio = 0; c.latencyMs = 0; c.jitterMs = 0; c.autoFlushSeconds = 12; c.preset = "normal"
        case .ghost:
            c.mode = "hold"; c.captureRatio = 98; c.downloadRatio = 100; c.uploadRatio = 98; c.direction = "both"; c.protoFilter = "both"; c.autoFlushSeconds = 0; c.preset = "ghost"
        case .lagSpike:
            c.mode = "delay"; c.latencyMs = 450; c.jitterMs = 120; c.captureRatio = 85; c.downloadRatio = 100; c.uploadRatio = 100; c.preset = "lagspike"
        case .degraded3G:
            c.mode = "delay"; c.latencyMs = 280; c.jitterMs = 60; c.bandwidthKbps = 128; c.captureRatio = 100; c.downloadRatio = 100; c.uploadRatio = 100; c.preset = "3g"
        case .tcpRst:
            c.mode = "drop"; c.captureRatio = 100; c.downloadRatio = 100; c.uploadRatio = 100; c.protoFilter = "tcp"; c.preset = "tcp_rst"
        }
        AppGroupStore.save(c)
        vpn.mode = c.mode
        vpn.latencyMs = c.latencyMs
        vpn.jitterMs = c.jitterMs
        vpn.bandwidthKbps = c.bandwidthKbps
        vpn.captureRatio = c.captureRatio
        AppGroupStore.logAction("PRESET_APPLY", details: "preset=\(c.preset) mode=\(c.mode) ratio=\(c.captureRatio)% dl=\(c.downloadRatio)% ul=\(c.uploadRatio)% latency=\(c.latencyMs)ms jitter=\(c.jitterMs)ms autoFlush=\(c.autoFlushSeconds)s")
    }
    
    func saveFloating() {
        var c = AppGroupStore.load()
        c.floatingSize = cfg.floatingSize
        c.floatingOpacity = cfg.floatingOpacity
        c.floatingEdgeSnap = cfg.floatingEdgeSnap
        c.floatingLockPosition = cfg.floatingLockPosition
        c.floatingHaptic = cfg.floatingHaptic
        AppGroupStore.save(c)
        // Push straight into the HUD daemon's shared memory — the daemon does
        // not read the JSON config, it only sees the shm fields.
        HybridHUDSyncFloatingConfig(c.floatingSize, c.floatingOpacity,
                                    c.floatingEdgeSnap, c.floatingLockPosition,
                                    c.floatingHaptic, c.floatingPosX, c.floatingPosY)
        AppGroupStore.logAction("FLOATING_CONFIG", details: "size=\(c.floatingSize) opacity=\(c.floatingOpacity) snap=\(c.floatingEdgeSnap) lock=\(c.floatingLockPosition) haptic=\(c.floatingHaptic) → shm synced")
    }
    
    func saveAutoFlush() {
        var c = AppGroupStore.load()
        c.autoFlushSeconds = cfg.autoFlushSeconds
        AppGroupStore.save(c)
        AppGroupStore.logAction("AUTO_FLUSH_CONFIG", details: "autoFlushSeconds=\(c.autoFlushSeconds)")
    }

    func exportLogs() {
        let logs = AppGroupStore.readLogs()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("hybrid_logs_export.txt")
        try? logs.write(to: url, atomically: true, encoding: .utf8)
        AppGroupStore.logAction("EXPORT_LOGS", details: url.path)
    }
}
