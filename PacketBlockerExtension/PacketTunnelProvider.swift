import NetworkExtension
import Network
import Darwin

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var isTrafficBlocked: Bool = false
    private var lock = os_unfair_lock()   // var, không phải let
    
    private var upstreamConnection: NWConnection?
    private let downloadQueue = DispatchQueue(label: "download.queue")
    
    override func startTunnel(options: [String : NSObject]? = nil,
                              completionHandler: @escaping (Error?) -> Void) {
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
            self.setupUpstreamConnection()
            self.readPacketsAndForward()
            self.startDownloadHandler()
            completionHandler(nil)
        }
    }
    
    private func setupUpstreamConnection() {
        let endpoint = NWEndpoint.hostPort(host: "example.com", port: 443) // thay bằng server thật
        upstreamConnection = NWConnection(to: endpoint, using: .tcp)
        upstreamConnection?.start(queue: .global())
    }
    
    private func readPacketsAndForward() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            os_unfair_lock_lock(&self.lock)
            let blocked = self.isTrafficBlocked
            os_unfair_lock_unlock(&self.lock)
            
            if !blocked {
                for packet in packets {
                    self.upstreamConnection?.send(content: packet, completion: .contentProcessed { _ in })
                }
            }
            self.readPacketsAndForward()
        }
    }
    
    private func startDownloadHandler() {
        downloadQueue.async { [weak self] in
            while true {
                guard let self = self else { break }
                let semaphore = DispatchSemaphore(value: 0)
                var receivedData: Data?
                self.upstreamConnection?.receive(minimumIncompleteLength: 1,
                                                 maximumLength: 65535) { data, _, _, _ in
                    receivedData = data
                    semaphore.signal()
                }
                semaphore.wait()
                guard let data = receivedData, !data.isEmpty else { continue }
                
                os_unfair_lock_lock(&self.lock)
                let blocked = self.isTrafficBlocked
                os_unfair_lock_unlock(&self.lock)
                
                if !blocked {
                    self.packetFlow.writePackets([data], withProtocols: [AF_INET as NSNumber])
                }
            }
        }
    }
    
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
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        upstreamConnection?.cancel()
        completionHandler()
    }
}