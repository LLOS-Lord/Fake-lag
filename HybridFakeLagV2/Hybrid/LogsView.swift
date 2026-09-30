import SwiftUI

struct LogsView: View {
    @State private var logs: String = ""
    @State private var timer: Timer?
    
    var body: some View {
        VStack {
            HStack {
                Text("All Actions Log").font(.headline)
                Spacer()
                Button("Refresh") { load() }
                Button("Clear") { AppGroupStore.clearLogs(); load() }
            }.padding()
            
            ScrollView {
                Text(logs)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    .padding(.horizontal)
            }
            
            HStack {
                Button("Export") {
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    let url = docs.appendingPathComponent("hybrid_export_\(Int(Date().timeIntervalSince1970)).log")
                    try? logs.write(to: url, atomically: true, encoding: .utf8)
                }
                Spacer()
                Text("\(logs.components(separatedBy: "\n").count) lines").font(.caption2).foregroundColor(.secondary)
            }.padding()
        }
        .navigationTitle("Logs")
        .onAppear {
            load()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in load() }
        }
        .onDisappear { timer?.invalidate() }
    }
    
    func load() {
        logs = AppGroupStore.readLogs()
        // Also merge AetherLog files
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let appLog = docs.appendingPathComponent("aethernet.log")
        if let appLogs = try? String(contentsOf: appLog) {
            logs += "\n--- AetherNet App Log ---\n" + appLogs.suffix(5000)
        }
        let hudLogPath = "/var/mobile/Library/aethernet-hud.log"
        if let hudLogs = try? String(contentsOfFile: hudLogPath) {
            logs += "\n--- HUD Daemon Log ---\n" + hudLogs.suffix(5000)
        }
    }
}
