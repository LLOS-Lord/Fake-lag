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
    
    func scan(filter: String = "", onlyUserApps: Bool = false) {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let list = self.enumerate(filter: filter, onlyUserApps: onlyUserApps)
            DispatchQueue.main.async {
                self.processes = list
                self.isScanning = false
            }
        }
    }
    
    private func enumerate(filter: String, onlyUserApps: Bool) -> [ProcessInfoModel] {
        var result: [ProcessInfoModel] = []
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        let count = bufferSize / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: count)
        let actualBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        let actualCount = actualBytes / MemoryLayout<pid_t>.size
        let selfPID = getpid()
        for i in 0..<actualCount {
            let pid = pids[i]
            if pid <= 1 || pid == selfPID { continue }
            var pathBuf = [CChar](repeating: 0, count: 1024)
            let ret = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            if ret <= 0 { continue }
            let execPath = String(cString: pathBuf)
            let isUserApp = execPath.contains("/var/containers/Bundle/Application/")
            if onlyUserApps && !isUserApp { continue }
            let name = (execPath as NSString).lastPathComponent
            var tcp = 0, udp = 0
            self.countSockets(pid: pid, tcp: &tcp, udp: &udp)
            if !filter.isEmpty {
                let q = filter.lowercased()
                if !name.lowercased().contains(q) && !execPath.lowercased().contains(q) && !"\(pid)".contains(q) { continue }
            }
            var bundleID = "com.apple.system"
            var displayName = name
            if let appRange = execPath.range(of: ".app/") {
                let bundleDir = String(execPath[..<appRange.upperBound].dropLast(1))
                if let info = NSDictionary(contentsOfFile: bundleDir + "/Info.plist") {
                    if let bid = info["CFBundleIdentifier"] as? String { bundleID = bid }
                    if let dname = info["CFBundleDisplayName"] as? String { displayName = dname }
                    else if let cname = info["CFBundleName"] as? String { displayName = cname }
                }
                if isUserApp { bundleID = bundleID == "com.apple.system" ? "com.user.app" : bundleID }
            }
            var icon: UIImage? = nil
            if isUserApp, let img = UIImage._applicationIconImage(forBundleIdentifier: bundleID, format: 0, scale: UIScreen.main.scale) {
                icon = img
            }
            result.append(ProcessInfoModel(pid: pid, ppid: 0, name: name, displayName: displayName, bundleID: bundleID, execPath: execPath, isUserApp: isUserApp, tcpCount: tcp, udpCount: udp, icon: icon))
        }
        result.sort {
            if $0.isUserApp != $1.isUserApp { return $0.isUserApp && !$1.isUserApp }
            return ($0.tcpCount + $0.udpCount) > ($1.tcpCount + $1.udpCount)
        }
        return result
    }
    
    private func countSockets(pid: Int32, tcp: inout Int, udp: inout Int) {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if bufSize <= 0 { return }
        let fdCount = bufSize / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
        let actual = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufSize)
        let actualCount = actual / MemoryLayout<proc_fdinfo>.size
        for j in 0..<actualCount {
            if fds[j].proc_fdtype == PROX_FDTYPE_SOCKET {
                var sockInfo = socket_fdinfo()
                let rc = proc_pidfdinfo(pid, fds[j].proc_fd, PROC_PIDFDSOCKETINFO, &sockInfo, Int32(MemoryLayout<socket_fdinfo>.size))
                if rc == MemoryLayout<socket_fdinfo>.size {
                    let family = sockInfo.psi.soi_family
                    if family == AF_INET || family == AF_INET6 {
                        if sockInfo.psi.soi_type == SOCK_STREAM { tcp += 1 }
                        else if sockInfo.psi.soi_type == SOCK_DGRAM { udp += 1 }
                    }
                }
            }
        }
    }
}
