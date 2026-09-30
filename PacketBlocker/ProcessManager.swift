import Foundation
import UIKit

struct ProcessInfoModel: Identifiable {
    var id: Int32 { pid }
    var pid: Int32
    var ppid: Int32
    var name: String
    var displayName: String
    var bundleID: String
    var execPath: String
    var isUserApp: Bool
    var tcpCount: Int
    var udpCount: Int
    var icon: UIImage?
}

class ProcessManager: ObservableObject {
    @Published var processes: [ProcessInfoModel] = []
    @Published var isScanning = false
    @Published var lastScanSummary = ""

    func scan(filter: String = "", onlyUserApps: Bool = false) {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let list = self.enumerate(filter: filter, onlyUserApps: onlyUserApps)
            DispatchQueue.main.async {
                self.processes = list
                self.isScanning = false
                self.lastScanSummary = "\(list.count) processes"
                AppGroupStore.logAction("PROC_SCAN", details: "\(list.count) processes (filter='\(filter)' userOnly=\(onlyUserApps))")
            }
        }
    }

    /// Imported C fixed char arrays (char[N]) appear in Swift as tuples — they
    /// must be read through raw memory, not String(cString:) directly.
    private func cstr<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { raw in
            guard let p = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: p)
        }
    }

    /// REAL enumeration via the C helper (sysctl KERN_PROC_ALL + proc_pidpath +
    /// proc_pidfdinfo) — ported from TrollNetInterceptor ProcessManager.mm.
    /// Mock data is only used on the Simulator / when the syscall path fails.
    private func enumerate(filter: String, onlyUserApps: Bool) -> [ProcessInfoModel] {
        var result: [ProcessInfoModel] = []

        #if !targetEnvironment(simulator)
        let maxProcs = 512
        var infos = [HybridProcInfo](repeating: HybridProcInfo(), count: maxProcs)
        let count = infos.withUnsafeMutableBufferPointer { buf -> Int in
            Int(HybridProcEnumerate(buf.baseAddress, Int32(maxProcs)))
        }
        if count > 0 {
            for i in 0..<count {
                let info = infos[i]
                let name = cstr(info.name)
                let displayName = cstr(info.displayName)
                let bundleID = cstr(info.bundleID)
                let execPath = cstr(info.execPath)

                if onlyUserApps && info.isUserApp == 0 { continue }
                if !filter.isEmpty {
                    let q = filter.lowercased()
                    let pidText = "\(info.pid)"
                    if !displayName.lowercased().contains(q),
                       !name.lowercased().contains(q),
                       !bundleID.lowercased().contains(q),
                       !pidText.contains(q) { continue }
                }

                result.append(ProcessInfoModel(
                    pid: info.pid,
                    ppid: info.ppid,
                    name: name,
                    displayName: displayName.isEmpty ? name : displayName,
                    bundleID: bundleID,
                    execPath: execPath,
                    isUserApp: info.isUserApp != 0,
                    tcpCount: Int(info.tcpCount),
                    udpCount: Int(info.udpCount),
                    icon: nil))
            }
        }
        #endif

        // Fallback (Simulator / CI runners): keep a mock list so the UI stays
        // usable, clearly labelled as mock.
        if result.isEmpty {
            #if targetEnvironment(simulator)
            result.append(ProcessInfoModel(pid: 1234, ppid: 1, name: "FreeFire", displayName: "Free Fire (Mock)", bundleID: "com.dts.freefireth", execPath: "/mock/FreeFire", isUserApp: true, tcpCount: 5, udpCount: 12, icon: nil))
            #endif
        }

        result.sort {
            if $0.isUserApp != $1.isUserApp { return $0.isUserApp && !$1.isUserApp }
            return ($0.tcpCount + $0.udpCount) > ($1.tcpCount + $1.udpCount)
        }
        return result
    }

    /// REAL per-PID socket dump (proc_pidfdinfo) used for VPN per-PID matching.
    /// The extension matches packets against these live remote endpoints.
    func dumpSocketsForPID(_ pid: Int32) -> [SocketEntry] {
        #if !targetEnvironment(simulator)
        let maxSocks = 64
        var entries = [HybridSocketEntryC](repeating: HybridSocketEntryC(), count: maxSocks)
        let count = entries.withUnsafeMutableBufferPointer { buf -> Int in
            Int(HybridProcSocketDump(pid, buf.baseAddress, Int32(maxSocks)))
        }
        guard count > 0 else { return [] }
        var out: [SocketEntry] = []
        for i in 0..<count {
            let e = entries[i]
            let ip = cstr(e.remoteIP)
            let proto = cstr(e.proto)
            guard ip.contains("."), ip != "0.0.0.0" else { continue } // IPv4 only (tunnel is IPv4)
            out.append(SocketEntry(localPort: e.localPort,
                                   remotePort: e.remotePort,
                                   remoteIP: ip,
                                   proto: proto))
        }
        AppGroupStore.logAction("SOCKET_DUMP", details: "pid=\(pid) → \(out.count) live remote sockets")
        if out.count > 0 {
            let sample = out.prefix(6).map { "\($0.remoteIP):\($0.remotePort)/\($0.proto)" }.joined(separator: ", ")
            AppGroupStore.logAction("SOCKET_SAMPLE", details: sample)
        }
        return out
        #else
        return []
        #endif
    }
}
