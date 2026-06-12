import NetworkExtension
import Network

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    // MARK: - Cờ điều khiển chặn traffic (thread‑safe)
    private var isTrafficBlocked: Bool = false
    private let lock = os_unfair_lock()
    
    // MARK: - Kết nối upstream (ra internet)
    private var upstreamConnection: NWConnection?      // Ví dụ dùng TCP
    private var downloadQueue = DispatchQueue(label: "download.queue")
    
    // MARK: - Khởi động tunnel
    override func startTunnel(options: [String : NSObject]? = nil,
                              completionHandler: @escaping (Error?) -> Void) {
        // 1. Cấu hình địa chỉ VPN
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.0.0.1")
        settings.ipv4Settings = {
            let ipv4 = NEIPv4Settings(addresses: ["10.0.2.2"], subnetMasks: ["255.255.255.0"])
            ipv4.includedRoutes = [NEIPv4Route.default()]
            return ipv4
        }()
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "8.8.4.4"])
        
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                completionHandler(error)
                return
            }
            
            // 2. Thiết lập kết nối upstream (thay bằng logic thật của bạn)
            self.setupUpstreamConnection()
            
            // 3. Bắt đầu xử lý gói tin UPLOAD (inline, không dùng hàm riêng)
            self.readPacketsAndForward()
            
            // 4. Bắt đầu xử lý gói tin DOWNLOAD (chạy nền)
            self.startDownloadHandler()
            
            completionHandler(nil)
        }
    }
    
    // MARK: - Thiết lập kết nối upstream (giả lập, hãy thay bằng socket thật)
    private func setupUpstreamConnection() {
        // Ví dụ kết nối TCP tới một proxy server
        let endpoint = NWEndpoint.hostPort(host: "example.com", port: 443)
        upstreamConnection = NWConnection(to: endpoint, using: .tcp)
        upstreamConnection?.start(queue: .global())
    }
    
    // MARK: - Xử lý UPLOAD (đọc từ packetFlow → gửi lên mạng)
    // Không có hàm handlePackets – toàn bộ logic nằm trong closure
    private func readPacketsAndForward() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            
            // Kiểm tra trạng thái chặn một cách an toàn
            os_unfair_lock_lock(&self.lock)
            let blocked = self.isTrafficBlocked
            os_unfair_lock_unlock(&self.lock)
            
            if !blocked {
                // ✅ Không chặn: gửi từng gói lên upstream
                for packet in packets {
                    self.upstreamConnection?.send(content: packet, completion: .contentProcessed { _ in })
                }
            }
            // 🛑 Nếu blocked == true: không gửi gói đi → chặn UPLOAD
            
            // Đọc tiếp các gói tiếp theo (lặp vô tận)
            self.readPacketsAndForward()
        }
    }
    
    // MARK: - Xử lý DOWNLOAD (nhận từ mạng → ghi vào packetFlow)
    private func startDownloadHandler() {
        downloadQueue.async { [weak self] in
            while true {
                guard let self = self else { break }
                
                // Giả lập nhận gói từ upstream (thay bằng receive thật)
                let semaphore = DispatchSemaphore(value: 0)
                var receivedData: Data?
                self.upstreamConnection?.receive(minimumIncompleteLength: 1,
                                                 maximumLength: 65535) { data, _, _, _ in
                    receivedData = data
                    semaphore.signal()
                }
                semaphore.wait()
                
                guard let data = receivedData, !data.isEmpty else { continue }
                
                // Kiểm tra trạng thái chặn
                os_unfair_lock_lock(&self.lock)
                let blocked = self.isTrafficBlocked
                os_unfair_lock_unlock(&self.lock)
                
                if !blocked {
                    // ✅ Không chặn: ghi gói vào packetFlow (chuyển xuống thiết bị)
                    self.packetFlow.writePackets([data], withProtocols: [AF_INET as NSNumber])
                }
                // 🛑 Nếu blocked == true: không ghi gói → chặn DOWNLOAD
            }
        }
    }
    
    // MARK: - Hàm điều khiển từ ứng dụng chính (qua sendProviderMessage)
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let command = String(data: messageData, encoding: .utf8), command.hasPrefix("toggleBlock:") {
            let blocked = command.hasSuffix("true")
            os_unfair_lock_lock(&lock)
            isTrafficBlocked = blocked
            os_unfair_lock_unlock(&lock)
            completionHandler?("OK".data(using: .utf8))
        } else {
            completionHandler?(nil)
        }
    }
    
    // MARK: - Dừng tunnel
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        upstreamConnection?.cancel()
        completionHandler()
    }
}
