import NetworkExtension
import os

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var isBlocking = false
    private let logger = OSLog(subsystem: "com.tenban.PacketBlocker.extension", category: "PacketTunnelProvider")
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        os_log("🚀 startTunnel called", log: self.logger, type: .info)
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        
        // Configure IPv4 settings - start with no routes
        let ipv4Settings = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = []
        settings.ipv4Settings = ipv4Settings
        
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                os_log("❌ setTunnelNetworkSettings failed: %@", log: self?.logger ?? OSLog.default, type: .error, error.localizedDescription)
                completionHandler(error)
            } else {
                os_log("✅ Tunnel started successfully", log: self?.logger ?? OSLog.default, type: .info)
                completionHandler(nil)
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("🛑 stopTunnel called with reason: %d", log: self.logger, type: .info, reason.rawValue)
        isBlocking = false
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            os_log("❌ Failed to decode command from app", log: self.logger, type: .error)
            completionHandler?(nil)
            return
        }
        
        os_log("📩 Received command from app: %@", log: self.logger, type: .info, command)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            switch command {
            case "enableBlocking":
                self.enableBlocking { success in
                    let response = success ? "ok" : "error"
                    os_log("✅ enableBlocking completed: %@", log: self.logger, type: .info, response)
                    completionHandler?(response.data(using: .utf8))
                }
                
            case "disableBlocking":
                self.disableBlocking { success in
                    let response = success ? "ok" : "error"
                    os_log("✅ disableBlocking completed: %@", log: self.logger, type: .info, response)
                    completionHandler?(response.data(using: .utf8))
                }
                
            default:
                os_log("⚠️ Unknown command: %@", log: self.logger, type: .debug, command)
                completionHandler?(nil)
            }
        }
    }
    
    private func enableBlocking(completion: @escaping (Bool) -> Void) {
        guard !isBlocking else {
            os_log("⚠️ Already blocking", log: self.logger, type: .debug)
            completion(true)
            return
        }
        
        os_log("🔴 Enabling blocking...", log: self.logger, type: .info)
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                os_log("❌ Enable blocking failed: %@", log: self?.logger ?? OSLog.default, type: .error, error.localizedDescription)
                completion(false)
            } else {
                self?.isBlocking = true
                os_log("✅ Blocking enabled successfully", log: self?.logger ?? OSLog.default, type: .info)
                completion(true)
            }
        }
    }
    
    private func disableBlocking(completion: @escaping (Bool) -> Void) {
        guard isBlocking else {
            os_log("⚠️ Not blocking, skip disable", log: self.logger, type: .debug)
            completion(true)
            return
        }
        
        os_log("🟢 Disabling blocking...", log: self.logger, type: .info)
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
        
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = []
        
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                os_log("❌ Disable blocking failed: %@", log: self?.logger ?? OSLog.default, type: .error, error.localizedDescription)
                completion(false)
            } else {
                self?.isBlocking = false
                os_log("✅ Blocking disabled successfully", log: self?.logger ?? OSLog.default, type: .info)
                completion(true)
            }
        }
    }
}
