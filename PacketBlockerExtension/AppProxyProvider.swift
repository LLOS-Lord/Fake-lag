import NetworkExtension
import Network
import Foundation

class FakeLagAppProxyProvider: NEAppProxyProvider {

    // MARK: - Config
    private var isLagEnabled = false
    private var lastTimestamp: TimeInterval = 0
    private let configQueue = DispatchQueue(label: "com.fakelag.config")
    private let forwardQueue = DispatchQueue(label: "com.fakelag.forward", qos: .userInitiated, attributes: .concurrent)

    private var configURL: URL {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.ban.PacketBlocker")!
            .appendingPathComponent("fakelag_config.plist")
    }

    // MARK: - Lifecycle

    override func startProxy(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[FakeLag] Proxy STARTED")
        // Reset lag state
        isLagEnabled = false
        lastTimestamp = 0
        // Start config watcher
        startConfigWatcher()
        completionHandler(nil)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[FakeLag] Proxy STOPPED. Reason: \(reason.rawValue)")
        isLagEnabled = false
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Luon tra loi ngay de tranh timeout
        completionHandler?(Data("ok".utf8))
    }

    // MARK: - Config Watcher

    private func startConfigWatcher() {
        configQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkConfig()
        }
    }

    private func checkConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            startConfigWatcher()
            return
        }

        let enabled = dict["enabled"] as? Bool ?? false
        let timestamp = dict["timestamp"] as? TimeInterval ?? 0

        if timestamp > lastTimestamp {
            lastTimestamp = timestamp
            if enabled != isLagEnabled {
                isLagEnabled = enabled
                NSLog("[FakeLag] Config updated: lag=\(isLagEnabled)")
            }
        }

        startConfigWatcher()
    }

    // MARK: - Flow Handling

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            return handleTCPFlow(tcpFlow)
        } else if let udpFlow = flow as? NEAppProxyUDPFlow {
            return handleUDPFlow(udpFlow)
        }
        return false
    }

    // MARK: - TCP Forwarding

    private func handleTCPFlow(_ flow: NEAppProxyTCPFlow) -> Bool {
        guard let remoteEndpoint = flow.remoteEndpoint as? NWHostEndpoint else {
            NSLog("[FakeLag] Invalid TCP endpoint")
            return false
        }

        let host = NWEndpoint.Host(remoteEndpoint.host)
        guard let port = NWEndpoint.Port("\(remoteEndpoint.port)") else {
            return false
        }

        let connection = NWConnection(host: host, port: port, using: .tcp)
        let flowID = "\(remoteEndpoint.host):\(remoteEndpoint.port)"

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                flow.open(withLocalEndpoint: nil) { error in
                    guard error == nil else {
                        NSLog("[FakeLag] TCP open error: \(error!)")
                        connection.cancel()
                        return
                    }
                    self?.startTCPForwarding(flow: flow, connection: connection, flowID: flowID)
                }
            case .failed(let error):
                NSLog("[FakeLag] TCP connection failed: \(error)")
                fallthrough
            case .cancelled:
                flow.closeReadWithError(nil)
                flow.closeWriteWithError(nil)
            default:
                break
            }
        }

        connection.start(queue: forwardQueue)
        return true
    }

    private func startTCPForwarding(flow: NEAppProxyTCPFlow, connection: NWConnection, flowID: String) {

        // MARK: Inbound (Server -> App)
        func readRemote() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }

                if let error = error {
                    flow.closeReadWithError(error)
                    return
                }

                if let data = data, !data.isEmpty {
                    self.applyLag(data: data) { laggedData in
                        guard let laggedData = laggedData else {
                            readRemote()
                            return
                        }
                        flow.write(laggedData) { writeError in
                            if writeError != nil { return }
                            readRemote()
                        }
                    }
                } else if isComplete {
                    flow.closeWriteWithError(nil)
                } else {
                    readRemote()
                }
            }
        }

        // MARK: Outbound (App -> Server)
        func readFlow() {
            flow.readData { [weak self] data, error in
                guard let self = self else { return }

                if let error = error {
                    connection.cancel()
                    return
                }

                guard let data = data, !data.isEmpty else {
                    connection.send(content: nil, contentContext: .defaultStream, isComplete: true, completion: .contentProcessed { _ in })
                    return
                }

                self.applyLag(data: data) { laggedData in
                    guard let laggedData = laggedData else {
                        readFlow()
                        return
                    }
                    connection.send(content: laggedData, completion: .contentProcessed { _ in
                        readFlow()
                    })
                }
            }
        }

        readRemote()
        readFlow()
    }

    // MARK: - UDP Forwarding

    private func handleUDPFlow(_ flow: NEAppProxyUDPFlow) -> Bool {
        guard let remoteEndpoint = flow.remoteEndpoint as? NWHostEndpoint else {
            return false
        }

        let host = NWEndpoint.Host(remoteEndpoint.host)
        guard let port = NWEndpoint.Port("\(remoteEndpoint.port)") else {
            return false
        }

        let connection = NWConnection(host: host, port: port, using: .udp)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                flow.open(withLocalEndpoint: nil) { error in
                    guard error == nil else {
                        connection.cancel()
                        return
                    }
                    self.startUDPForwarding(flow: flow, connection: connection)
                }
            case .failed, .cancelled:
                flow.closeReadWithError(nil)
                flow.closeWriteWithError(nil)
            default:
                break
            }
        }

        connection.start(queue: forwardQueue)
        return true
    }

    private func startUDPForwarding(flow: NEAppProxyUDPFlow, connection: NWConnection) {

        // Inbound
        func readRemote() {
            connection.receiveMessage { [weak self] data, context, isComplete, error in
                guard let self = self else { return }

                if let error = error {
                    flow.closeReadWithError(error)
                    return
                }

                if let data = data, !data.isEmpty {
                    self.applyLag(data: data) { laggedData in
                        guard let laggedData = laggedData else {
                            readRemote()
                            return
                        }
                        flow.writeDatagrams([laggedData]) { writeError in
                            if writeError != nil { return }
                            readRemote()
                        }
                    }
                } else {
                    readRemote()
                }
            }
        }

        // Outbound
        func readFlow() {
            flow.readDatagrams { [weak self] datagrams, endpoints, error in
                guard let self = self else { return }

                if let error = error {
                    connection.cancel()
                    return
                }

                guard let datagrams = datagrams, !datagrams.isEmpty else {
                    readFlow()
                    return
                }

                var processed: [Data] = []
                let group = DispatchGroup()

                for datagram in datagrams {
                    group.enter()
                    self.applyLag(data: datagram) { lagged in
                        if let lagged = lagged {
                            processed.append(lagged)
                        }
                        group.leave()
                    }
                }

                group.notify(queue: self.forwardQueue) {
                    guard !processed.isEmpty else {
                        readFlow()
                        return
                    }
                    for datagram in processed {
                        connection.send(content: datagram, completion: .contentProcessed { _ in })
                    }
                    readFlow()
                }
            }
        }

        readRemote()
        readFlow()
    }

    // MARK: - Lag Engine

    private func applyLag(data: Data, completion: @escaping (Data?) -> Void) {
        if !isLagEnabled {
            completion(data)
            return
        }

        // Drop rate: 15%
        if Int.random(in: 0..<100) < 15 {
            completion(nil)
            return
        }

        // Delay: 300ms
        let delayMs = 300
        forwardQueue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
            completion(data)
        }
    }
}
